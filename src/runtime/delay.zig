// SPDX-License-Identifier: EPL-2.0
//! Delay — Tier A lazy single-shot memoised computation.
//!
//! `(delay expr)` constructs a Delay carrying a thunk (= zero-arity
//! fn closing over `expr`'s environment). `(deref d)` evaluates the
//! thunk on first call and caches the result; subsequent derefs
//! return the cached Value without re-running the thunk. JVM
//! `clojure.lang.Delay` is the model (single-shot lock-on-realise +
//! cached value).
//!
//! **Phase B #4b**: `force` holds an `Io.Mutex` for the realise window so
//! concurrent derefs run the thunk exactly ONCE — a second thread that
//! derefs while the first is mid-thunk blocks on the lock, then sees the
//! realised cache. The lock is an off-heap cell (a bare `Io.Mutex`, no
//! condition — waiters block on the lock itself), the same off-heap shape
//! as `future.zig`/`promise.zig` (their `Io.Condition` cannot live in an
//! `extern` struct), freed by the Delay's finaliser.
//!
//! Per F-009: implementation here is namespace-neutral. The Clojure-
//! ns surface `(delay ...)` macro lives in `lang/macro_transforms`,
//! expanding to `(__delay-create (fn [] expr))`. The neutral primitive
//! `__delay-create` is registered alongside `deref` extensions in
//! `lang/primitive/deref.zig` (Phase 14 split from stm.zig).

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const io_default = @import("concurrency/io_default.zig");
const safepoint = @import("concurrency/safepoint.zig");
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

/// Delay state machine.
///
/// - `pending`: thunk hasn't run yet; `cached` is undefined.
/// - `realised`: thunk ran successfully; `cached` holds the value.
///
/// JVM's Delay also caches a thrown exception for re-raise on subsequent
/// derefs. cw v1 leaves the Delay `.pending` on a thunk error (a retry of
/// `deref` re-runs the thunk) — a known divergence preserved here.
pub const DelayState = enum(u8) {
    pending = 0,
    realised = 1,
};

/// Off-heap realise lock (a bare mutex — no condition; concurrent derefs
/// block on the lock and read the cache after the holder realises).
/// Infra-allocated, freed by the Delay's finaliser.
const DelayCell = struct {
    mutex: std.Io.Mutex = .init,
};

pub const Delay = extern struct {
    header: HeapHeader,
    /// Read/written under `cell.mutex`.
    state: DelayState = .pending,
    _pad: [7]u8 = @splat(0),
    /// Zero-arity thunk wrapping the delayed expression; traced while pending.
    thunk: Value,
    /// Realised value. Undefined while `state == .pending`.
    cached: Value = .nil_val,
    cell: *DelayCell,

    comptime {
        std.debug.assert(@alignOf(Delay) >= 8);
        std.debug.assert(@offsetOf(Delay, "header") == 0);
    }
};

pub fn alloc(rt: *Runtime, thunk: Value) !Value {
    const cell = try rt.gpa.create(DelayCell);
    cell.* = .{};
    const d = rt.gc.alloc(Delay) catch |e| {
        rt.gpa.destroy(cell);
        return e;
    };
    d.* = .{
        .header = HeapHeader.init(.delay),
        .thunk = thunk,
        .cell = cell,
    };
    return Value.encodeHeapPtr(.delay, d);
}

pub fn isDelay(v: Value) bool {
    return v.tag() == .delay;
}

/// Force the Delay's thunk on first call; return cached value on
/// subsequent calls. `(deref d)` dispatches here when `d.tag() ==
/// .delay`. Caller threads `rt` + `env` so the thunk can invoke
/// through `rt.vtable.callFn`.
pub fn force(rt: *Runtime, env: anytype, v: Value, loc: anytype) !Value {
    std.debug.assert(v.tag() == .delay);
    const d = v.decodePtr(*Delay);
    // Hold the realise lock so concurrent derefs run the thunk exactly once:
    // a second thread blocks here, then takes the realised cache below. On a
    // thunk error the `defer` unlocks and the state stays `.pending` (retry
    // re-runs — the preserved single-thread divergence).
    // GC-ROOT: a WORKER blocking here is at a safepoint — the COLLECTING main
    // thread holds this same lock across the thunk's eval (the only eval-under-
    // lock site), so a plain block would stall the STW rendezvous (D-244 #4).
    safepoint.lockMutexAtSafepoint(&d.cell.mutex);
    defer io_default.unlockMutex(&d.cell.mutex);
    if (d.state == .realised) return d.cached;
    const vtable = rt.vtable orelse return error.InternalError;
    const result = try vtable.callFn(rt, env, d.thunk, &.{}, loc);
    d.cached = result;
    // Release: a lock-free `isRealised` that sees .realised also sees `cached`.
    @atomicStore(DelayState, &d.state, .realised, .release);
    return result;
}

/// `(realized? d)`. Lock-free: realisation is monotonic, so an acquire load of
/// the state answers without taking the once-lock `force` holds across the
/// thunk. Taking that lock stalled every collection while another thread
/// forced (the thunk can collect), and deadlocked a thunk that asked about its
/// own delay.
pub fn isRealised(v: Value) bool {
    if (v.tag() != .delay) return false;
    const d = v.decodePtr(*Delay);
    return @atomicLoad(DelayState, &d.state, .acquire) == .realised;
}

pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const d: *Delay = @ptrCast(@alignCast(header));
    if (d.thunk.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (d.state == .realised) {
        if (d.cached.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Free the off-heap realise lock on sweep (no-alloc invariant: a `destroy`).
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const d: *Delay = @ptrCast(@alignCast(header));
    gc.infra.destroy(d.cell);
}

/// D-573: the off-heap cell.
fn ownedBytes(header: *HeapHeader) usize {
    const d: *Delay = @ptrCast(@alignCast(header));
    return @sizeOf(@TypeOf(d.cell.*));
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.delay, &traceGc);
    tag_ops.registerFinaliser(.delay, &finaliseGc);
    tag_ops.registerOwnedBytes(.delay, &ownedBytes);
}

const testing = std.testing;

test "Delay alloc + isDelay round-trip" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const d = try alloc(&rt, .nil_val);
    try testing.expect(isDelay(d));
    try testing.expect(!isRealised(d));
    try testing.expect(!isDelay(Value.initInteger(7)));
}
