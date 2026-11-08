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
const root_set = @import("gc/root_set.zig");
const spawn = @import("concurrency/spawn.zig");
const io_default = @import("concurrency/io_default.zig");
const Latch = @import("concurrency/latch.zig").Latch;
const eval_budget = @import("concurrency/eval_budget.zig");
const clock = @import("clock.zig");
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
    /// `(future-cancel f)` won the race while the worker was still `.pending`
    /// (D-442 / ADR-0153). Terminal: the worker's later store is discarded
    /// (guarded on `.pending`); `deref` raises a CancellationException.
    cancelled = 3,
};

/// The blocking result cell, held off the GC heap (its sync members have
/// automatic layout, so it cannot live in the `extern` Future). Infra-allocated
/// (`rt.gpa`) at construction, freed by the Future's finaliser. Stable address
/// (infra alloc never moves), so a parked deref'er's wait target is valid for
/// the cell's lifetime.
///
/// `mutex` guards the PAYLOAD (`state` / `cached`); `settled` carries the EDGE.
/// Realisation is monotonic — once settled, never unsettled — so it is a latch
/// rather than a condition, and a latch is what can be waited on with a
/// deadline (see `concurrency/latch.zig`). Publish under the mutex, then
/// `signal`: `set` releases the prior writes, so a waiter that sees the latch
/// sees the payload.
const FutureCell = struct {
    mutex: std.Io.Mutex = .init,
    /// Raised once the future reaches any terminal state (value, error, or
    /// cancelled) — every reason a deref'er has to stop waiting.
    settled: Latch = .{},
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
    /// The eval budget inherited from the spawner (D-571), or null. The worker
    /// adopts it for its whole run; the reference is dropped on worker exit.
    budget: ?*eval_budget.EvalBudget,

    comptime {
        std.debug.assert(@alignOf(Future) >= 8);
        std.debug.assert(@offsetOf(Future, "header") == 0);
    }
};

/// The Future the CURRENT thread's worker is running, or null on the main
/// thread and any non-worker thread. Set by `worker` (D-442 / ADR-0153 sub-step
/// 2a) so a blocking primitive (Thread/sleep, …) can poll whether THIS worker's
/// future was cancelled and abort cooperatively — releasing the thread + GC pin
/// promptly. Threadlocal: each worker sees only its own future.
pub threadlocal var current_future: ?*Future = null;

/// Thread-local execution state displaced while an executor runs a pending
/// Future.  CallerRunsPolicy can execute on a thread that is itself evaluating
/// (or even running another Future), so the prior slots must be restored rather
/// than blindly cleared as a dedicated worker does.
pub const PendingExecutionScope = struct {
    previous_future: ?*Future,
    previous_budget: ?*eval_budget.EvalBudget,

    pub fn leave(self: PendingExecutionScope) void {
        current_future = self.previous_future;
        eval_budget.current = self.previous_budget;
    }
};

/// The latch a blocking primitive on THIS worker waits on so a `future-cancel`
/// wakes it immediately, or null on the main thread / a non-worker thread.
///
/// It is the future's `settled` latch: cancellation is one of the terminal
/// states, so the edge a deref'er waits for and the edge a sleeping worker
/// waits for are the same edge. A worker waiting on its own future's settle
/// cannot deadlock — only `future-cancel` and the worker's own epilogue raise
/// it, and the epilogue runs after the thunk has returned.
pub fn currentCancelLatch() ?*Latch {
    const f = current_future orelse return null;
    return &f.cell.settled;
}

/// True iff the current worker's future was `future-cancel`led — a blocking
/// primitive polls this to abort promptly (ADR-0153 sub-step 2a). false on the
/// main thread (no `current_future`) or an un-cancelled worker. Reads the state
/// under the cell mutex (the same serialisation `cancel` writes under).
pub fn cancelRequested() bool {
    const f = current_future orelse return false;
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    return f.state == .cancelled;
}

fn allocCell(rt: *Runtime, env: *Env, thunk: Value) !Value {
    const cell = try rt.gpa.create(FutureCell);
    cell.* = .{};
    const f = rt.gc.alloc(Future) catch |e| {
        rt.gpa.destroy(cell);
        return e;
    };
    f.* = .{
        .header = HeapHeader.init(.future),
        .thunk = thunk,
        .rt = rt,
        .env = env,
        .cell = cell,
        .budget = eval_budget.inherit(),
    };
    const fut_val = Value.encodeHeapPtr(.future, f);
    rt.gc.pin(fut_val) catch |e| {
        if (f.budget) |b| b.unref();
        f.budget = null;
        return e;
    };
    return fut_val;
}

/// Allocate a Future whose producer is an executor rather than a newly spawned
/// thread.  The callable is retained in `thunk`, the spawner's eval budget is
/// retained in `budget`, and the Future remains pinned until exactly one of
/// `complete`, `completeError`, or `discardPending` releases producer ownership.
pub fn allocPending(rt: *Runtime, env: *Env, callable: Value) !Value {
    return allocCell(rt, env, callable);
}

/// Install a pending Future as the current unit of work.  This makes the same
/// cooperative cancellation and inherited-budget paths available to pool work
/// as to an ordinary `(future ...)`.  Pair with `scope.leave()` before settling.
pub fn enterPending(v: Value) PendingExecutionScope {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    const scope = PendingExecutionScope{
        .previous_future = current_future,
        .previous_budget = eval_budget.current,
    };
    current_future = f;
    eval_budget.current = f.budget;
    return scope;
}

fn settlePending(v: Value, state: FutureState, value: Value) void {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    if (f.state == .pending) {
        f.cached = value;
        f.state = state;
    }
    f.thunk = .nil_val;
    io_default.unlockMutex(&f.cell.mutex);
    f.cell.settled.signal();
    if (f.budget) |b| b.unref();
    f.budget = null;
    _ = f.rt.gc.unpin(v);
}

/// Publish a successful executor result.  Cancellation wins the state race;
/// producer ownership is still released.
pub fn complete(v: Value, value: Value) void {
    settlePending(v, .realised_value, value);
}

/// Publish an executor error value marshalled by `worker_error.capture`.
pub fn completeError(v: Value, err_value: Value) void {
    settlePending(v, .realised_error, err_value);
}

/// Release a queued Future that was cancelled before its callable started.
pub fn discardPending(v: Value) void {
    settlePending(v, .realised_error, .nil_val);
}

/// Spawn a worker thread to run `thunk`; return a pending Future. `loc` is
/// accepted for surface symmetry but unused — a thrown thunk is caught on the
/// worker and re-raised at deref time with a default location (D-115).
pub fn alloc(rt: *Runtime, env: *Env, thunk: Value, loc: SourceLocation) !Value {
    _ = loc;
    const fut_val = try allocCell(rt, env, thunk);
    const f = fut_val.decodePtr(*Future);
    // Teardown guard (ADR-0176): account the worker BEFORE spawn so the exit
    // boundary sees it even while the thread is still starting up.
    root_set.noteWorkerSpawned();
    var t = spawn.spawn(worker, .{f}) catch |e| {
        root_set.noteWorkerExited();
        if (f.budget) |b| b.unref();
        f.budget = null;
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
    // FIRST defer → runs LAST: the teardown guard may only see 0 once every
    // heap-touching cleanup below (result store, unpin, unregister) completed.
    defer root_set.noteWorkerExited();
    const fut_val = Value.encodeHeapPtr(.future, f);
    // The tx_slot publishes this worker's STM transaction so a `dosync` in the
    // thunk is GC-rooted during a collect (#4a' in-txn-map rooting).
    var ctx = root_set.workerContext(@ptrCast(&lock_tx.current_tx));
    const registered = if (root_set.registerThread(&ctx)) |_| true else |_| false;
    defer if (registered) root_set.unregisterThread(&ctx);

    // Publish this worker's future so its thunk's blocking primitives can poll
    // `cancelRequested` and abort cooperatively (ADR-0153 sub-step 2a).
    current_future = f;
    defer current_future = null;

    // Adopt the spawner's budget (D-571): the thunk's back-edges tick the
    // SHARED counter and its blocking calls are cut at the SHARED deadline, so
    // outliving the with-budget extent does not shed the meter. Read once —
    // `f` may be swept after the final unpin, but this frame's copy is ours.
    const inherited_budget = f.budget;
    eval_budget.adopt(inherited_budget);
    defer eval_budget.release(inherited_budget);

    var result_state: FutureState = .realised_error;
    var result_value: Value = .nil_val;
    // ADR-0175: NEVER run the thunk unregistered (registry cap hit) — an
    // unregistered mutator is invisible to the STW rendezvous + root walk,
    // the exact corruption the registration safepoint closes. The future
    // realises as an error WITHOUT allocating (this thread may not touch the
    // GC heap): `cached` stays nil, so `deref` raises `future_thunk_failed`
    // (errorValue's nil-guard routes it past the reraise).
    if (registered) {
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
    }

    io_default.lockMutex(&f.cell.mutex);
    // D-442 / ADR-0153: guard the store on `.pending` — a `future-cancel` that
    // won the mutex first set `.cancelled`; the worker must NOT clobber it
    // (mark-cancelled-wins). A cancelled future's computed result is discarded.
    if (f.state == .pending) {
        f.cached = result_value;
        f.state = result_state;
    }
    io_default.unlockMutex(&f.cell.mutex);
    f.cell.settled.signal();
    _ = f.rt.gc.unpin(fut_val);
}

/// `(future-cancel f)` — D-442 / ADR-0153 (state-machine half of the cooperative
/// model). If the worker has not yet stored a result (`.pending`), mark
/// `.cancelled` + wake any deref'er, returning `true` (matches clj `cancel(true)`
/// on a pending/running task). A future that already realised / was cancelled
/// returns `false`. The worker is not interrupted synchronously here; instead a
/// blocking primitive in the thunk (`Thread/sleep`) polls `cancelRequested` and
/// aborts cooperatively (ADR-0153 sub-step 2a), so a sleeping thunk's thread + GC
/// pin release promptly. A thunk in a tight CPU loop (no blocking primitive) runs
/// to completion, matching the JVM's best-effort `cancel(true)`; its result is
/// discarded by the `.pending`-guarded store either way.
pub fn cancel(v: Value) bool {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    if (f.state == .pending) {
        f.state = .cancelled;
        // Signalled under the mutex here (unlike the worker's epilogue, which
        // unlocks first) because `defer unlockMutex` owns the exit path; `set`
        // takes no lock, so there is nothing to deadlock against.
        f.cell.settled.signal();
        return true;
    }
    return false;
}

/// `(future-cancelled? f)` — true iff `future-cancel` won (terminal `.cancelled`).
pub fn isCancelled(v: Value) bool {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
    return f.state == .cancelled;
}

pub fn isFuture(v: Value) bool {
    return v.tag() == .future;
}

/// `(deref f)` — BLOCK until the worker realises the Future, then return the
/// cached value (`.realised_value`) or `null` (`.realised_error`; the caller
/// raises `future_thunk_failed`). The block uses the result cell's condition
/// via the `io_default` singleton (set to the real threaded io in `main`).
pub fn deref(v: Value, deadline_ns: ?i64) ?Value {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    // Wait OUTSIDE the mutex: the latch is the edge, the mutex only guards the
    // payload we read after it.
    if (!f.cell.settled.wait(deadline_ns)) return null;
    io_default.lockMutex(&f.cell.mutex);
    defer io_default.unlockMutex(&f.cell.mutex);
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
    // Nil-guard: a future that failed WITHOUT a marshalled exception (worker
    // registration refused at the registry cap — that path may not allocate
    // one) has `cached == nil`; report "no exception value" so the deref
    // consumer raises the generic `future_thunk_failed` instead of
    // re-raising nil (ADR-0175).
    return if (f.state == .realised_error and !f.cached.isNil()) f.cached else null;
}

/// Wait up to `timeout_ms` for the worker (the 3-arity `deref` support).
/// Returns false on timeout (caller returns its timeout-val); true means the
/// regular `deref` path now returns without blocking (a failed future still
/// re-raises properly there).
pub fn waitRealised(io: std.Io, v: Value, timeout_ms: i64) bool {
    std.debug.assert(v.tag() == .future);
    const f = v.decodePtr(*Future);
    // Saturating: `(deref f Long/MAX_VALUE v)` must wait "forever", not overflow.
    return f.cell.settled.wait(clock.nanoTime(io) +| (@max(timeout_ms, 0) *| std.time.ns_per_ms));
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

/// D-573: the off-heap result cell.
fn ownedBytes(header: *HeapHeader) usize {
    _ = header;
    return @sizeOf(FutureCell);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.future, &traceGc);
    tag_ops.registerFinaliser(.future, &finaliseGc);
    tag_ops.registerOwnedBytes(.future, &ownedBytes);
}

const testing = std.testing;

test "Future isFuture predicate" {
    try testing.expect(!isFuture(Value.initInteger(7)));
    try testing.expect(!isFuture(.nil_val));
}

test "cancelRequested: false with no current worker future (main-thread path)" {
    // No worker is running on the test thread, so the cooperative-abort poll is
    // a no-op (Thread/sleep stays a single uninterrupted sleep off a worker).
    current_future = null;
    try testing.expect(!cancelRequested());
}
