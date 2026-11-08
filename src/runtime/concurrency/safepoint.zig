// SPDX-License-Identifier: EPL-2.0
//! GC stop-the-world safepoint coordination (Phase B #3b-step2, ADR-0090 Alt B /
//! D-244). The pause-the-mutators half of ADR-0090 §2's "allocation lock +
//! root-publication handshake": the global `GcHeap.gc_mutex` already serializes
//! *allocation*, but a worker spinning in a non-allocating loop holds live cw
//! Values on its VM operand stack while taking no lock. This module lets a
//! collecting thread pause every OTHER registered worker at a safe point (its
//! `alloc` entry, or the VM back-edge liveness poll), so the union root walk
//! (`gc/root_set.zig`, #3a/#3b-step1) sees each worker's quiescent, published
//! roots, then resume them.
//!
//! Two layers, NOT a replacement for `gc_mutex`:
//!   - `gc_mutex` (gc_heap.zig) serializes alloc + the mark/sweep cycle.
//!   - this module's `sp_mutex` guards ONLY the park rendezvous (`parked_count`
//!     + the two conditions). It is SEPARATE from `gc_mutex` because a parked
//!     worker unlocks `sp_mutex` while waiting on `resume_cond`, so the collector
//!     can hold `gc_mutex` for the whole mark/sweep while workers wait here.
//!
//! Runtime-inert until Phase-B real worker threads (#4) set `gc_requested`: with
//! no thread ever arming the flag, the VM back-edge poll is a single never-taken
//! relaxed load and `alloc`'s prologue never parks — byte-behaviour identical to
//! today, the same inert cadence #3a / #3b-step1 landed under. Sync reaches
//! pinned Zig 0.16's `std.Io.Mutex` / `Io.Condition` via the `io_default`
//! singleton (pinned 0.16 removed `std.Thread.{Mutex,Condition}`; `Io.Condition`
//! has no `timedWait`, so the park uses plain `waitUncancelable` — time-to-
//! safepoint is bounded by the poll discipline, not a wait timeout).

const std = @import("std");
const atomics = @import("../atomics.zig");
const io_default = @import("io_default.zig");
const root_set = @import("../gc/root_set.zig");
const clock = @import("../clock.zig");

/// Diagnostic (ADR-0150 am1 / D-560): the longest single `stopWorld` rendezvous
/// wait observed this process, in ns. The am1 park-deferral makes the wait
/// unbounded in fold-chain length (a worker running back-to-back fabrication
/// brackets parks only at its next non-bracket safepoint), so the delay must be
/// OBSERVABLE — if this grows into real pause-time trouble, D-560 names the
/// publish-roots redesign that removes the cliff. Monotonic max; read on demand
/// (no print path wired — a probe reads it via a debugger / future stats dump).
pub var max_stopworld_wait_ns: atomics.Value(i64) = .init(0);

/// Armed by a collecting thread (`stopWorld`); read by the VM back-edge poll +
/// the `alloc`-boundary check. A worker that observes this set at a safe point
/// parks. Relaxed loads at the poll sites suffice for *liveness* (a worker must
/// eventually notice); *correctness* of the roots is fenced by the
/// acquire/release pairs on `sp_mutex` inside `park` / `stopWorld`.
pub var gc_requested: std.atomic.Value(bool) = .init(false);

/// Guards `parked_count` + the two conditions. Deliberately NOT `gc_mutex`
/// (see the module doc — a parked worker releases this while waiting).
var sp_mutex: std.Io.Mutex = .init;
/// Workers currently parked at the safe point.
var parked_count: u32 = 0;
/// The collector waits on this until every other worker has parked.
var all_parked: std.Io.Condition = .init;
/// Parked workers wait on this until the collector clears `gc_requested`.
var resume_cond: std.Io.Condition = .init;

/// Worker safe point: register as parked, wake the collector, then block until
/// the pending collection finishes. Called when `gc_requested` is observed set
/// at the `alloc` boundary, the VM back-edge poll, or the registration
/// safepoint at the tail of `root_set.registerThread` (ADR-0175 — a worker
/// born while a collect is arming/running parks before its first mutator
/// step). Signalling `all_parked` on
/// every entry (not only the last) is robust against the collector checking the
/// count before this thread parks. The resume guard tests the FLAG, not the
/// count, so a spurious `Condition` wakeup re-parks correctly.
pub fn park() void {
    // ADR-0150 am1 / D-559: a thread must NEVER park inside a fabrication
    // no-collect region — its in-progress builder nodes are unrooted Zig
    // locals the collector cannot see, so a park here hands the peer's
    // collect a stack it will corrupt. The alloc-prologue gate (gc_heap)
    // skips the park mid-bracket; this assert is the chokepoint guarding
    // every OTHER park site (back-edge poll, lazy_seq, lock_tx, monitor)
    // against a future bracket that reaches one of them.
    std.debug.assert(root_set.fabrication_depth == 0);
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    parked_count += 1;
    io_default.condSignal(&all_parked);
    while (gc_requested.load(.acquire)) {
        io_default.condWait(&resume_cond, &sp_mutex);
    }
    parked_count -= 1;
}

/// Stop the world: arm the safe point and block until every OTHER registered
/// worker has parked. `self_registered` excludes the calling (collecting)
/// thread from the wait target — true when the collector is itself a registered
/// worker (Phase-B `future`/`pmap` thread that crossed the alloc threshold),
/// false for the main / unregistered collector. After this returns the caller
/// walks roots / collects, then MUST call `resumeWorld`. The target is read
/// from the registry BEFORE arming so a worker arriving late still parks (the
/// flag is armed first); a parked-count overshoot only relaxes the `<` wait.
pub fn stopWorld(self_registered: bool) void {
    const t0 = clock.nanoTime(io_default.get());
    defer {
        const waited = clock.nanoTime(io_default.get()) - t0;
        if (waited > max_stopworld_wait_ns.load(.monotonic))
            max_stopworld_wait_ns.store(waited, .monotonic);
    }
    // Seq_cst, pairing with `registerThread`'s seq_cst count-add + flag-load
    // (ADR-0175): a worker mid-registration is either visible in the count read
    // below (we wait for its park) or sees this flag and parks at its
    // registration safepoint — never both-miss (the spawn-to-register window).
    gc_requested.store(true, .seq_cst);
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    // Recompute the target on every wake: a worker that finishes a tiny action
    // can UNREGISTER before it ever parks, so a target snapshotted once would
    // never be reached and the wait would hang (D-244 #4). The lock-free count
    // is read under `sp_mutex` so the `noteWorkerLeft` signal (also under
    // `sp_mutex`) can never slip between the read and the wait — no lost wakeup,
    // no `registry_mutex`-under-`sp_mutex` inversion. A late-arriving worker
    // raises the count and parks at its first poll; an overshoot relaxes `<`.
    while (true) {
        const registered = root_set.registeredCountLockFree();
        const target: u32 = if (self_registered and registered > 0) registered - 1 else registered;
        if (parked_count >= target) return;
        io_default.condWait(&all_parked, &sp_mutex);
    }
}

/// Wake a `stopWorld` collector so it recomputes its rendezvous target after a
/// worker left the registry (called by `root_set.unregisterThread`). Shares the
/// `all_parked` condition with `park`: both signal "a worker reached an
/// accounted state" (parked, or departed → target lowered).
pub fn noteWorkerLeft() void {
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    io_default.condBroadcast(&all_parked);
}

/// Count a registered worker as parked for the span of a BLOCKING lock/condition
/// acquisition, so a concurrent `stopWorld` collector treats it as quiescent and
/// proceeds. The worker's roots stay published (its EvalFrame chain), so the
/// collector walks them safely while it blocks. Pairs with `exitBlocked`. A
/// worker blocked on a lock is NOT at a back-edge poll, so without this the
/// rendezvous waits for a thread that will never park (D-244 #4 — the delay-once
/// torture deadlock: `force` runs the thunk under the once-lock, so the COLLECTING
/// main thread holds it across a collect while a worker blocks on it).
pub fn enterBlocked() void {
    // Brackets nest (a blocking call inside a blocked region): only the
    // outermost one counts, or the worker is counted parked twice and a
    // collection can start while another worker is still running.
    blocked_depth += 1;
    if (blocked_depth > 1) return;
    // ADR-0150 am1 / D-559: same invariant as `park` — counting a mid-bracket
    // thread as parked would let the collector proceed over its unrooted
    // builder intermediates (the side door the alloc-prologue gate does not
    // cover). Brackets are pure builders that take no locks, so this cannot
    // fire today; it guards the invariant against future bracket bodies.
    std.debug.assert(root_set.fabrication_depth == 0);
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    parked_count += 1;
    io_default.condSignal(&all_parked);
}

/// End an `enterBlocked` region. Decrement the parked count; if a collection
/// armed while we were blocked, park now (re-checking the flag) so the
/// post-acquire heap-touching code does not run before the collector resumes.
/// An inner bracket of a nested pair only unwinds the depth.
pub fn exitBlocked() void {
    std.debug.assert(blocked_depth > 0);
    blocked_depth -= 1;
    if (blocked_depth > 0) return;
    {
        io_default.lockMutex(&sp_mutex);
        defer io_default.unlockMutex(&sp_mutex);
        parked_count -= 1;
    }
    if (gc_requested.load(.acquire)) park();
}

/// How many `enterBlocked` brackets this thread is inside. Only the outermost
/// one changes `parked_count`.
threadlocal var blocked_depth: u32 = 0;

/// Call `f` with `args`, counting a registered worker as parked for the call so
/// a collection another thread requests does not wait for it to return. For
/// calls that block in the OS (a child process, a socket, DNS). `f` must not
/// allocate GC memory, create a Value or raise: it returns data or a Zig error,
/// and the caller builds or raises after this returns. On the main /
/// unregistered thread it is a plain call.
pub fn blocking(comptime f: anytype, args: anytype) @TypeOf(@call(.auto, f, args)) {
    if (!root_set.is_registered_worker) return @call(.auto, f, args);
    enterBlocked();
    defer exitBlocked();
    return @call(.auto, f, args);
}

/// Acquire `m` at a GC safepoint when running on a registered worker: a worker
/// that may block here while the COLLECTING thread holds `m` across a collect
/// must not stall the rendezvous. The main / unregistered thread (the collector
/// in the torture model, never the blocked party) takes the plain lock. Use ONLY
/// at a lock that can be held across a collect — today the `delay` once-lock,
/// the sole site that runs arbitrary eval (the thunk) under a lock.
pub fn lockMutexAtSafepoint(m: *std.Io.Mutex) void {
    if (!root_set.is_registered_worker) {
        io_default.lockMutex(m);
        return;
    }
    enterBlocked();
    io_default.lockMutex(m);
    exitBlocked();
}

/// The poll for a spin loop on a registered worker: park if a collection is
/// pending. A thread spinning on a lock whose holder can park (or collect)
/// never reaches another safepoint, so the spin itself must be one. Call it
/// only while holding nothing another thread needs to finish the collection.
pub fn poll() void {
    if (root_set.is_registered_worker and gc_requested.load(.acquire)) park();
}

/// Resume the world: clear the safe-point flag and wake every parked worker.
/// Call after the caller finishes collecting. Each woken worker re-checks the
/// (now-clear) flag and exits its park loop.
pub fn resumeWorld() void {
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    gc_requested.store(false, .release);
    io_default.condBroadcast(&resume_cond);
}

// --- tests ---

const testing = std.testing;
const env_mod = @import("../env.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const value_mod = @import("../value/value.zig");
const heap_header = @import("../value/heap_header.zig");

const GcHeap = gc_heap_mod.GcHeap;
const Value = value_mod.Value;
const HeapHeader = heap_header.HeapHeader;
const Cell = extern struct { header: HeapHeader = HeapHeader.init(.string), payload: u64 = 0 };

/// Set a threaded `io` on the singleton for the duration of a test (so the
/// `Io.Mutex` / `Io.Condition` block for real across `std.Thread`s), restored
/// LIFO. Mirrors the `root_set.zig` churn test harness. `start` must run
/// in-place: `std.Io.Threaded.io()` binds to `&self.threaded`, so the `.io()`
/// call has to happen AFTER the value is stored at its final address (a
/// by-value `init()` returning the struct would leave `io` dangling at the
/// returned-from local).
const ThreadedIo = struct {
    saved: std.Io = undefined,
    threaded: std.Io.Threaded = undefined,
    fn start(self: *ThreadedIo) void {
        self.saved = io_default.get();
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        io_default.set(self.threaded.io());
    }
    fn deinit(self: *ThreadedIo) void {
        io_default.set(self.saved);
        self.threaded.deinit();
    }
};

test "safepoint: stopWorld rendezvous parks all workers, resumeWorld releases them (D-244 #3b-step2)" {
    var tio: ThreadedIo = .{};
    tio.start();
    defer tio.deinit();

    const N = 4;
    const Shared = struct {
        var ready: std.atomic.Value(u32) = .init(0);
        var resumed: std.atomic.Value(u32) = .init(0);
        var done: std.atomic.Value(bool) = .init(false);

        fn worker() void {
            // Register a context pointing at this thread's own TLS (null slots
            // on a fresh worker — the rendezvous counts the registration, it
            // does not walk roots here).
            var ctx: root_set.ThreadGcContext = .{
                .frame_slot = &env_mod.current_frame,
                .analysis_frame_slot = &root_set.analysis_frame_head,
                .eval_frame_slot = &root_set.eval_frame_head,
                .self_guard_slot = &root_set.gc_self_guard,
            };
            root_set.registerThread(&ctx) catch return;
            defer root_set.unregisterThread(&ctx);
            _ = ready.fetchAdd(1, .monotonic);
            // Back-edge poll loop: park whenever a collection is pending.
            while (!done.load(.acquire)) {
                if (gc_requested.load(.monotonic)) park();
                std.atomic.spinLoopHint();
            }
            _ = resumed.fetchAdd(1, .monotonic);
        }
    };
    // Fresh static state in case a prior test left counters set.
    Shared.ready.store(0, .monotonic);
    Shared.resumed.store(0, .monotonic);
    Shared.done.store(false, .monotonic);

    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.worker, .{});

    // Wait until every worker has registered + entered its poll loop.
    while (Shared.ready.load(.acquire) < N) std.atomic.spinLoopHint();

    // STW: returns only once all N workers have parked.
    stopWorld(false);
    try testing.expectEqual(@as(u32, N), parkedCountForTest());

    // (the collector would walk roots here) — release.
    resumeWorld();
    Shared.done.store(true, .release);

    for (&threads) |t| t.join();
    try testing.expectEqual(@as(u32, N), Shared.resumed.load(.acquire));
    try testing.expectEqual(@as(u32, 0), parkedCountForTest());
    try testing.expect(!gc_requested.load(.acquire));
}

/// Snapshot `parked_count` under `sp_mutex` (test introspection only).
fn parkedCountForTest() u32 {
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    return parked_count;
}

test "safepoint: a parked worker's published EvalFrame survives a real collect during STW (D-244 #3b-step2)" {
    var tio: ThreadedIo = .{};
    tio.start();
    defer tio.deinit();

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const rooted = try gc.alloc(Cell);
    rooted.* = .{ .header = HeapHeader.init(.string) };
    const garbage = try gc.alloc(Cell);
    garbage.* = .{ .header = HeapHeader.init(.vector) };
    try testing.expectEqual(@as(usize, 2), gc.allocations.items.len);

    const Shared = struct {
        var rooted_val: Value = undefined;
        var ready: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);

        fn worker() void {
            // Hold `rooted_val` on a published operand-stack frame, then poll.
            var stack = [_]Value{rooted_val};
            var sp: u16 = 1;
            var locals = [_]Value{Value.nil_val};
            var frame: root_set.EvalFrame = .{ .stack = &stack, .sp = &sp, .locals = &locals, .parent = null };
            var eval_head: ?*root_set.EvalFrame = &frame;
            var ctx: root_set.ThreadGcContext = .{
                .frame_slot = &env_mod.current_frame,
                .analysis_frame_slot = &root_set.analysis_frame_head,
                .eval_frame_slot = &eval_head,
                .self_guard_slot = &root_set.gc_self_guard,
            };
            root_set.registerThread(&ctx) catch return;
            defer root_set.unregisterThread(&ctx);
            ready.store(true, .release);
            while (!done.load(.acquire)) {
                if (gc_requested.load(.monotonic)) park();
                std.atomic.spinLoopHint();
            }
        }
    };
    Shared.rooted_val = Value.encodeHeapPtr(.string, rooted);
    Shared.ready.store(false, .monotonic);
    Shared.done.store(false, .monotonic);

    var t = try std.Thread.spawn(.{}, Shared.worker, .{});
    while (!Shared.ready.load(.acquire)) std.atomic.spinLoopHint();

    // Stop the world (wait for the worker to park), then run a REAL collect.
    // The union walk (#3a/#3b-step1) reaches the parked worker's EvalFrame, so
    // `rooted` is marked; `garbage` (no root) is swept.
    stopWorld(false);
    mark_sweep.collect(&gc, .{ .envs = &.{}, .gc = &gc });
    resumeWorld();
    Shared.done.store(true, .release);
    t.join();

    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len); // garbage swept, rooted survived
    try testing.expectEqual(@as(*HeapHeader, @ptrCast(rooted)), gc.allocations.items[0].header);
}

test "collectStopTheWorld with no other registered worker is a fenced collect (D-244 #4)" {
    // Single-threaded: target = registeredThreadCount() = 0, so stopWorld returns
    // immediately and this is `collect` plus a no-op resume broadcast.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const garbage = try gc.alloc(Cell);
    garbage.* = .{ .header = HeapHeader.init(.vector) };
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);

    mark_sweep.collectStopTheWorld(&gc, .{ .envs = &.{}, .gc = &gc }, false);

    try testing.expectEqual(@as(usize, 0), gc.allocations.items.len); // garbage swept
    try testing.expectEqual(@as(u64, 1), gc.stats.collect_count);
    try testing.expect(!gc_requested.load(.acquire));
}

test "registerThread during an active STW collect parks the newborn until resumeWorld (spawn-to-register window)" {
    var tio: ThreadedIo = .{};
    tio.start();
    defer tio.deinit();

    const Shared = struct {
        /// True between stopWorld-return and resumeWorld on the main thread —
        /// the span where NO registered worker may run mutator code.
        var in_stw: std.atomic.Value(bool) = .init(false);
        var ran_during_collect: std.atomic.Value(bool) = .init(false);
        var registered_ret: std.atomic.Value(bool) = .init(false);

        fn worker() void {
            var ctx: root_set.ThreadGcContext = .{
                .frame_slot = &env_mod.current_frame,
                .analysis_frame_slot = &root_set.analysis_frame_head,
                .eval_frame_slot = &root_set.eval_frame_head,
                .self_guard_slot = &root_set.gc_self_guard,
            };
            root_set.registerThread(&ctx) catch return;
            // First mutator step after registration: if the collector is still
            // between stopWorld and resumeWorld here, the newborn raced the
            // collect (the spawn-to-register window).
            if (in_stw.load(.seq_cst)) ran_during_collect.store(true, .seq_cst);
            registered_ret.store(true, .release);
            root_set.unregisterThread(&ctx);
        }
    };
    Shared.in_stw.store(false, .monotonic);
    Shared.ran_during_collect.store(false, .monotonic);
    Shared.registered_ret.store(false, .monotonic);

    // Arm + complete the rendezvous with ZERO registered workers (target 0 →
    // returns at once) — the collector is now "collecting".
    stopWorld(false);
    Shared.in_stw.store(true, .seq_cst);

    // A worker born mid-collect must park inside registerThread until
    // resumeWorld, never run its first mutator step during the collect.
    var t = try std.Thread.spawn(.{}, Shared.worker, .{});
    while (parkedCountForTest() == 0 and !Shared.registered_ret.load(.acquire)) std.atomic.spinLoopHint();

    Shared.in_stw.store(false, .seq_cst);
    resumeWorld();
    t.join();

    try testing.expect(!Shared.ran_during_collect.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), parkedCountForTest());
}

test "collectStopTheWorld parks real workers allocating through gc.alloc, then resumes them (D-244 #4)" {
    var tio: ThreadedIo = .{};
    tio.start();
    defer tio.deinit();

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const N = 4;
    const Shared = struct {
        var gc_ptr: *GcHeap = undefined;
        var ready: std.atomic.Value(u32) = .init(0);
        var allocs: atomics.Value(u64) = .init(0);
        var done: std.atomic.Value(bool) = .init(false);

        fn worker() void {
            var ctx: root_set.ThreadGcContext = .{
                .frame_slot = &env_mod.current_frame,
                .analysis_frame_slot = &root_set.analysis_frame_head,
                .eval_frame_slot = &root_set.eval_frame_head,
                .self_guard_slot = &root_set.gc_self_guard,
            };
            root_set.registerThread(&ctx) catch return;
            defer root_set.unregisterThread(&ctx);
            _ = ready.fetchAdd(1, .monotonic);
            // Allocate (discarding) until told to stop. The alloc-prologue park
            // (gc_heap.zig) is the safe point: when the collector arms the flag,
            // the next alloc parks here BEFORE taking gc_mutex.
            while (!done.load(.acquire)) {
                const c = gc_ptr.alloc(Cell) catch return;
                c.* = .{ .header = HeapHeader.init(.vector) };
                _ = allocs.fetchAdd(1, .monotonic);
            }
        }
    };
    Shared.gc_ptr = &gc;
    Shared.ready.store(0, .monotonic);
    Shared.allocs.store(0, .monotonic);
    Shared.done.store(false, .monotonic);

    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.worker, .{});
    while (Shared.ready.load(.acquire) < N) std.atomic.spinLoopHint();

    // Collector (main, unregistered): pauses all N allocating workers at their
    // alloc-prologue park, collects, resumes. No deadlock: each worker releases
    // gc_mutex after its in-flight alloc, then parks at the next prologue (on
    // sp_mutex, not gc_mutex), so the collector's gc_mutex-taking collect runs
    // while they wait.
    mark_sweep.collectStopTheWorld(&gc, .{ .envs = &.{}, .gc = &gc }, false);
    try testing.expectEqual(@as(u64, 1), gc.stats.collect_count);
    try testing.expect(!gc_requested.load(.acquire));

    Shared.done.store(true, .release);
    for (&threads) |t| t.join();
    try testing.expect(Shared.allocs.load(.acquire) > 0); // workers really ran
    try testing.expectEqual(@as(u32, 0), parkedCountForTest()); // all resumed cleanly
}

test "blocking counts a registered worker as parked for the call and passes the result through" {
    const Probe = struct {
        fn seen(bump: u32) error{Refused}!u32 {
            if (bump == 0) return error.Refused;
            return parkedCountForTest() + bump;
        }
    };
    try testing.expectEqual(@as(u32, 1), try blocking(Probe.seen, .{1}));

    root_set.is_registered_worker = true;
    defer root_set.is_registered_worker = false;
    try testing.expectEqual(@as(u32, 2), try blocking(Probe.seen, .{1}));
    try testing.expectError(error.Refused, blocking(Probe.seen, .{0}));
    try testing.expectEqual(@as(u32, 0), parkedCountForTest());
}
