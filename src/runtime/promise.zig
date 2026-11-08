// SPDX-License-Identifier: EPL-2.0
//! Promise — Tier A single-shot write-once cell (Phase B #4b).
//!
//! `(promise)` constructs an unfulfilled Promise. `(deliver p v)` sets the
//! value once (idempotent: re-delivery returns `nil`, matching JVM
//! `Promise.deliver` after a failed CAS) and wakes every blocked deref'er.
//! `(deref p)` BLOCKS on the cell's latch until the value is delivered
//! (possibly from another thread), then returns it — the standard
//! `(let [p (promise)] (future (deliver p v)) (deref p))` cross-thread pattern.
//! Deref of a never-delivered promise blocks forever, exactly as JVM Clojure
//! does (D-113 discharged: the prior single-thread `promise_undelivered_error`
//! raise is retired now that real threading can block).
//!
//! The result cell (its sync members have automatic layout, so it cannot live
//! in the `extern` Promise) is infra-allocated and freed by the Promise's
//! finaliser — the same shape as `future.zig`'s `FutureCell`.
//!
//! Per F-009 the implementation is namespace-neutral; surface `promise` /
//! `deliver` primitives live in `lang/primitive/stm.zig`.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const io_default = @import("concurrency/io_default.zig");
const Latch = @import("concurrency/latch.zig").Latch;
const clock = @import("clock.zig");
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

pub const PromiseState = enum(u8) {
    pending = 0,
    delivered = 1,
};

/// Blocking cell, held off the GC heap (see the module doc); infra-allocated at
/// construction, freed by the Promise's finaliser. Stable address — a parked
/// deref'er's wait target is valid for the cell's lifetime (the Promise stays
/// rooted while held).
///
/// `mutex` guards the payload (`state` / `value`); `delivered` carries the edge.
/// Delivery is monotonic, so it is a latch, and a latch can be waited on with a
/// deadline (`concurrency/latch.zig`). Publish under the mutex, then `signal`.
const PromiseCell = struct {
    mutex: std.Io.Mutex = .init,
    delivered: Latch = .{},
};

pub const Promise = extern struct {
    header: HeapHeader,
    /// Read/written ONLY under `cell.mutex`.
    state: PromiseState = .pending,
    _pad: [7]u8 = @splat(0),
    /// Delivered value; `.nil_val` while pending.
    value: Value = .nil_val,
    cell: *PromiseCell,

    comptime {
        std.debug.assert(@alignOf(Promise) >= 8);
        std.debug.assert(@offsetOf(Promise, "header") == 0);
    }
};

pub fn alloc(rt: *Runtime) !Value {
    const cell = try rt.gpa.create(PromiseCell);
    cell.* = .{};
    const p = rt.gc.alloc(Promise) catch |e| {
        rt.gpa.destroy(cell);
        return e;
    };
    p.* = .{ .header = HeapHeader.init(.promise), .cell = cell };
    return Value.encodeHeapPtr(.promise, p);
}

pub fn isPromise(v: Value) bool {
    return v.tag() == .promise;
}

/// `(deliver p v)` — set the value on first call (and wake blocked deref'ers),
/// no-op + return nil on subsequent calls. Returns the promise on success, nil
/// on a failed-CAS retry (the surface tests check against this).
pub fn deliver(v: Value, val: Value) Value {
    std.debug.assert(v.tag() == .promise);
    const p = v.decodePtr(*Promise);
    io_default.lockMutex(&p.cell.mutex);
    defer io_default.unlockMutex(&p.cell.mutex);
    if (p.state == .delivered) return .nil_val;
    p.value = val;
    p.state = .delivered;
    p.cell.delivered.signal();
    return v;
}

/// `(deref p)` — BLOCK until the value is delivered (matching JVM Clojure),
/// then return it. Bounded by `deadline_ns` when the caller has an eval budget
/// armed: without one a never-delivered promise blocks forever, which is the clj
/// behaviour, but a metered evaluation must not be able to park past its
/// deadline. Returns null iff the deadline passed undelivered.
pub fn deref(v: Value, deadline_ns: ?i64) ?Value {
    std.debug.assert(v.tag() == .promise);
    const p = v.decodePtr(*Promise);
    // Wait OUTSIDE the mutex: the latch is the edge, the mutex guards the value.
    if (!p.cell.delivered.wait(deadline_ns)) return null;
    io_default.lockMutex(&p.cell.mutex);
    defer io_default.unlockMutex(&p.cell.mutex);
    return p.value;
}

pub fn isRealised(v: Value) bool {
    if (v.tag() != .promise) return false;
    const p = v.decodePtr(*Promise);
    io_default.lockMutex(&p.cell.mutex);
    defer io_default.unlockMutex(&p.cell.mutex);
    return p.state == .delivered;
}

/// Wait up to `timeout_ms` for a delivery (the 3-arity `deref` support).
/// False on timeout.
pub fn waitDelivered(io: std.Io, v: Value, timeout_ms: i64) bool {
    std.debug.assert(v.tag() == .promise);
    const p = v.decodePtr(*Promise);
    // Saturating: `(deref p Long/MAX_VALUE v)` must wait "forever", not overflow.
    return p.cell.delivered.wait(clock.nanoTime(io) +| (@max(timeout_ms, 0) *| std.time.ns_per_ms));
}

pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const p: *Promise = @ptrCast(@alignCast(header));
    if (p.state == .delivered) {
        if (p.value.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Free the off-heap cell on sweep (no-alloc invariant: a `destroy`). Reachable
/// only when the Promise is unreachable — no deref'er is blocked on it then.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const p: *Promise = @ptrCast(@alignCast(header));
    gc.infra.destroy(p.cell);
}

/// D-573: the off-heap cell.
fn ownedBytes(header: *HeapHeader) usize {
    _ = header;
    return @sizeOf(PromiseCell);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.promise, &traceGc);
    tag_ops.registerFinaliser(.promise, &finaliseGc);
    tag_ops.registerOwnedBytes(.promise, &ownedBytes);
}

const testing = std.testing;

test "Promise alloc + deliver + deref (already-delivered, no block)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const p = try alloc(&rt);
    try testing.expect(isPromise(p));
    try testing.expect(!isRealised(p));
    _ = deliver(p, Value.initInteger(42));
    try testing.expect(isRealised(p));
    // Already delivered → deref returns immediately (no block).
    try testing.expectEqual(@as(i64, 42), deref(p, null).?.asInteger());
    // Retry-deliver returns nil and does NOT overwrite.
    const second = deliver(p, Value.initInteger(99));
    try testing.expect(second.isNil());
    try testing.expectEqual(@as(i64, 42), deref(p, null).?.asInteger());
}
