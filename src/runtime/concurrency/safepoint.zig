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
const io_default = @import("io_default.zig");
const root_set = @import("../gc/root_set.zig");

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
/// at the `alloc` boundary or the VM back-edge poll. Signalling `all_parked` on
/// every entry (not only the last) is robust against the collector checking the
/// count before this thread parks. The resume guard tests the FLAG, not the
/// count, so a spurious `Condition` wakeup re-parks correctly.
pub fn park() void {
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
    gc_requested.store(true, .release);
    const registered = root_set.registeredThreadCount();
    const target: u32 = @intCast(if (self_registered and registered > 0) registered - 1 else registered);
    io_default.lockMutex(&sp_mutex);
    defer io_default.unlockMutex(&sp_mutex);
    while (parked_count < target) {
        io_default.condWait(&all_parked, &sp_mutex);
    }
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
                .macro_slot = &root_set.macro_root_slot,
                .eval_frame_slot = &root_set.eval_frame_head,
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
                .macro_slot = &root_set.macro_root_slot,
                .eval_frame_slot = &eval_head,
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
