// SPDX-License-Identifier: EPL-2.0
//! Future — Tier A single-shot off-thread computation (Phase B #4b).
//!
//! `(future expr)` → `(__future-call (fn* [] expr))` → `alloc`, which spawns a
//! REAL OS thread (`std.Thread`) that runs the thunk and caches the result.
//! `(deref f)` BLOCKS on an `Io.Mutex`+`Io.Condition` result cell until the
//! worker realises the Future, then returns the cached value. This matches JVM
//! Clojure's fire-and-wait timing (the thread is kicked at construction; deref
//! waits for it).
//!
//! GC safety (ADR-0090 Alt B / D-244): the worker runs on the VM (the bytecode
//! `callFn` path on the VM-default build, F-012 / Q2) and registers a
//! `ThreadGcContext` so its operand-stack + binding roots are published — a
//! concurrent collect parks it at a safe point and walks its roots. The Future
//! is `gc.pin`ned for the worker's lifetime so a fire-and-forget
//! `(future (side-effect))` is not swept while the worker still writes to it;
//! the worker unpins on completion. The thread is detached — the result cell's
//! condition (not a join) synchronises `deref` (shutdown-orphan of a still-
//! running worker is a known limitation, tracked as a Phase-B follow-up).
//!
//! Exceptions: a thunk that throws is caught on the worker; `deref` returns
//! `null` and the caller (stm.zig `derefFn`) raises `future_thunk_failed`
//! (precise error attribution across the thread boundary is the D-115
//! Value-carried exception channel, still PROVISIONAL).
//!
//! Per F-009 the implementation is namespace-neutral.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const env_mod = @import("env.zig");
const root_set = @import("gc/root_set.zig");
const io_default = @import("concurrency/io_default.zig");
const lock_tx = @import("concurrency/lock_tx.zig");
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;
const worker_error = @import("concurrency/worker_error.zig");

pub const FutureState = enum(u8) {
    pending = 0,
    realised_value = 1,
    realised_error = 2,
};

/// The blocking result cell, held off the GC heap (`std.Io.Condition` has
/// automatic layout, so it cannot live in the `extern` Future). Infra-allocated
/// (`rt.gpa`) at construction, freed by the Future's finaliser. `deref` waits on
/// `cond`; the worker broadcasts it. Stable address (infra alloc never moves),
/// so a parked deref'er's wait target is valid for the cell's lifetime.
const FutureCell = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
};

pub const Future = extern struct {
    header: HeapHeader,
    /// Realisation state; read/written ONLY under `cell.mutex`.
    state: FutureState = .pending,
    _pad: [7]u8 = @splat(0),
    /// Result value (when `state == .realised_value`); `.nil_val` otherwise.
    cached: Value = .nil_val,
    /// The 0-arg thunk the worker runs; traced while `pending`.
    thunk: Value = .nil_val,
    rt: *Runtime,
    env: *Env,
    cell: *FutureCell,

    comptime {
        std.debug.assert(@alignOf(Future) >= 8);
        std.debug.assert(@offsetOf(Future, "header") == 0);
    }
};

/// Spawn a worker thread to run `thunk`; return a pending Future. `loc` is
/// accepted for surface symmetry but unused — a thrown thunk is caught on the
/// worker and re-raised at deref time with a default location (D-115).
pub fn alloc(rt: *Runtime, env: *Env, thunk: Value, loc: SourceLocation) !Value {
    _ = loc;
    const cell = try rt.gpa.create(FutureCell);
    cell.* = .{};
    const f = rt.gc.alloc(Future) catch |e| {
        // No Future to own the cell yet → free it here. Past this point the
        // Future owns `cell`; the finaliser frees it on sweep, so no other path
        // frees it (a failed pin / spawn just leaves the Future as garbage,
        // swept later, finaliser-freeing the cell — no double free).
        rt.gpa.destroy(cell);
        return e;
    };
    f.* = .{
        .header = HeapHeader.init(.future),
        .thunk = thunk,
        .rt = rt,
        .env = env,
        .cell = cell,
    };
    const fut_val = Value.encodeHeapPtr(.future, f);
    // Pin so the worker's write target survives even when no deref'er holds it.
    try rt.gc.pin(fut_val);
    var t = std.Thread.spawn(.{}, worker, .{f}) catch |e| {
        _ = rt.gc.unpin(fut_val);
        return e;
    };
    t.detach();
    return fut_val;
}

/// Worker-thread body: publish roots, run the thunk on the VM, store the result
/// + wake deref'ers, unpin. Runs on a fresh thread with its own threadlocal GC
/// slots (no conveyed dynamic bindings yet — binding conveyance is a follow-up).
fn worker(f: *Future) void {
    const fut_val = Value.encodeHeapPtr(.future, f);
    var ctx: root_set.ThreadGcContext = .{
        .frame_slot = &env_mod.current_frame,
        .macro_slot = &root_set.macro_root_slot,
        .eval_frame_slot = &root_set.eval_frame_head,
        .self_guard_slot = &root_set.gc_self_guard,
        // Publish this worker's STM transaction so a `dosync` in the thunk is
        // GC-rooted during a collect (#4a' in-txn-map rooting).
        .tx_slot = @ptrCast(&lock_tx.current_tx),
    };
    const registered = if (root_set.registerThread(&ctx)) |_| true else |_| false;
    defer if (registered) root_set.unregisterThread(&ctx);

    var result_state: FutureState = .realised_error;
    var result_value: Value = .nil_val;
    if (f.rt.vtable) |vt| {
        if (vt.callFn(f.rt, f.env, f.thunk, &.{}, .{})) |result| {
            result_state = .realised_value;
            result_value = result;
        } else |_| {
            // ADR-0120: marshal the worker's error into a GC-heap exception
            // Value (survives this thread) so `deref` re-raises the REAL error
            // (kind/message/location), not a generic `future_thunk_failed`.
            result_state = .realised_error;
            result_value = worker_error.capture(f.rt);
        }
    }

    io_default.lockMutex(&f.cell.mutex);
    f.cached = result_value;
    f.state = result_state;
    io_default.condBroadcast(&f.cell.cond);
    io_default.unlockMutex(&f.cell.mutex);
    _ = f.rt.gc.unpin(fut_val);
}

pub fn isFuture(v: Value) bool {
    return v.tag() == .future;
}

/// `(deref f)` — BLOCK until the worker realises the Future, then return the
/// cached value (`.realised_value`) or `null` (`.realised_error`; the caller
/// raises `future_thunk_failed`). The block uses the result cell's condition
/// via the `io_default` singleton (set to the real threaded io in `main`).
pub fn deref(v: Value) ?Value {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    while (f.state == .pending) {
        io_default.condWait(&f.cell.cond, &f.cell.mutex);
    }
    return if (f.state == .realised_value) f.cached else null;
}

/// The marshalled exception Value of a failed future (ADR-0120), or `null` if
/// the future succeeded / is pending. The consumer (`deref`) re-raises this via
/// `worker_error.reraise` so the real error surfaces, not `future_thunk_failed`.
/// Assumes the worker has realised (call after `deref` returned null).
pub fn errorValue(v: Value) ?Value {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    return if (f.state == .realised_error) f.cached else null;
}

/// `(realized? f)` — non-blocking: true iff the worker has finished (value or
/// error). Reads the state under the mutex.
pub fn isRealised(v: Value) bool {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    return f.state != .pending;
}

pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const f: *Future = @ptrCast(@alignCast(header));
    // The worker is parked (or exited) during a collect per the safepoint, so
    // `cached`/`thunk` are not being concurrently written here.
    if (f.cached.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (f.thunk.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Free the off-heap result cell when the Future is swept (no-alloc invariant:
/// a `destroy`, never an alloc). Reachable only when the Future is unreachable,
/// so the worker has finished (it unpins before exit) and no deref holds it.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const f: *Future = @ptrCast(@alignCast(header));
    gc.infra.destroy(f.cell);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.future, &traceGc);
    tag_ops.registerFinaliser(.future, &finaliseGc);
}

const testing = std.testing;

test "Future isFuture predicate" {
    try testing.expect(!isFuture(Value.initInteger(7)));
    try testing.expect(!isFuture(.nil_val));
}
