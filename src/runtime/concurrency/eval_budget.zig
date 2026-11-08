// SPDX-License-Identifier: EPL-2.0
//! EvalBudget — an in-process bound on ONE EVALUATION's execution (ADR-0125):
//! a step ceiling (deterministic, dual-backend-testable) AND/OR a wall-clock
//! deadline (the real untrusted-code bound). Both axes are optional; an
//! unmetered evaluation (no current budget) is the default and costs one
//! threadlocal load + branch per poll.
//!
//! **The budget follows the work, not the thread** (D-571). It is a refcounted
//! heap object; the evaluating thread holds it in the threadlocal `current`,
//! and every spawner (`Thread.` / `future` / an agent send) captures a
//! reference at spawn time so the spawned work is metered by the SAME budget —
//! the same absolute deadline, the same shared step counter. A worker that
//! outlives the `with-budget` extent keeps its reference and trips on it; it
//! cannot escape by outliving the extent, and a submission cannot escape the
//! step bound by moving its loop onto a spawned thread. The predecessor was a
//! non-atomic `?EvalBudget` slot on the Runtime: workers raced the main
//! thread's counter while the extent was live and found null after it exited.
//!
//! Polled at the back-edge safe points of BOTH backends (VM + TreeWalk) so a
//! non-allocating infinite loop is caught either way. On expiry it raises an
//! UNCATCHABLE `resource_exhausted` error (kindToHostClass→null): untrusted
//! code cannot swallow its own timeout via `(try … (catch Throwable …))`.
//! Once tripped it LATCHES — every subsequent poll on ANY thread re-raises —
//! so a straight-line burst after the (uncatchable) raise cannot make progress.
//!
//! F-006: the wall-clock read goes through the injected `io` (Runtime.io),
//! never a global clock.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none (armed via CLJW_EVAL_MAX_STEPS / CLJW_EVAL_DEADLINE_MS
//!   or scoped via `cljw.eval/with-budget`)
const std = @import("std");
const atomics = @import("../atomics.zig");
const error_catalog = @import("../error/catalog.zig");
const clock = @import("../clock.zig");
const io_default = @import("io_default.zig");
const Latch = @import("latch.zig").Latch;
const safepoint = @import("safepoint.zig");
const ClojureWasmError = error_catalog.ClojureWasmError;

/// The budget metering THIS thread's evaluation, or null (unmetered).
///
/// Set by `with-budget` (and the env arming) on the evaluating thread, and by
/// a worker's entry from the reference its spawner captured. Every consumer —
/// the back-edge tick, `budgetedSleep`, `deadlineOf` — reads this, never a
/// Runtime field: the slot's owner is the thread, the object's owner is the
/// evaluation.
pub threadlocal var current: ?*EvalBudget = null;

pub const EvalBudget = struct {
    /// Max back-edge crossings across EVERY thread of the evaluation;
    /// null = no step bound. Immutable after create.
    step_ceiling: ?u64,
    /// Monotonic-clock deadline in ns (clock.nanoTime); null = no time bound.
    /// Immutable after create — an absolute instant, so every thread that
    /// inherits the budget shares the same wall-clock horizon.
    deadline_ns: ?i64,
    /// The configured wall-clock budget in ms, for the error message only.
    deadline_ms: i64,
    /// Running back-edge counter, shared by every thread. Atomic.
    steps: u64 = 0,
    /// Which axis tripped (latch): once non-`.none`, every tick on any thread
    /// re-raises it. Atomic; first tripper wins.
    tripped: Axis = .none,
    /// Reference count: 1 for the creating extent + 1 per in-flight spawned
    /// worker / queued agent action. Atomic. Freed at zero.
    refs: usize = 1,
    /// The allocator that created this object (frees it at refs==0).
    gpa: std.mem.Allocator,

    pub const Axis = enum(u8) { none, steps, deadline };

    /// Read the wall clock only every 1024th step — a clock syscall per
    /// back-edge would dominate the hot loop. Power-of-two so the throttle
    /// test is a mask, not a modulo.
    const clock_poll_mask: u64 = 1023;

    pub fn create(gpa: std.mem.Allocator, opts: struct {
        step_ceiling: ?u64 = null,
        deadline_ns: ?i64 = null,
        deadline_ms: i64 = 0,
    }) !*EvalBudget {
        const b = try gpa.create(EvalBudget);
        b.* = .{
            .step_ceiling = opts.step_ceiling,
            .deadline_ns = opts.deadline_ns,
            .deadline_ms = opts.deadline_ms,
            .gpa = gpa,
        };
        return b;
    }

    /// Take a reference (a spawner capturing the budget for its worker).
    pub fn ref(self: *EvalBudget) *EvalBudget {
        _ = atomics.rmw(usize, &self.refs, .Add, 1, .monotonic);
        return self;
    }

    /// Drop a reference; frees at zero. `.acq_rel` so the freeing thread
    /// observes every other holder's writes before destroy.
    pub fn unref(self: *EvalBudget) void {
        if (atomics.rmw(usize, &self.refs, .Sub, 1, .acq_rel) == 1) {
            self.gpa.destroy(self);
        }
    }

    pub fn trippedAxis(self: *const EvalBudget) Axis {
        return atomics.load(Axis, &self.tripped, .monotonic);
    }

    /// Latch `axis` as the trip reason; the first tripper wins so every
    /// thread reports the same axis.
    fn trip(self: *EvalBudget, axis: Axis) void {
        _ = atomics.cmpxchgStrong(Axis, &self.tripped, .none, axis, .monotonic, .monotonic);
    }

    /// Charge one back-edge crossing. Raises (uncatchable) on expiry; the
    /// latch makes a re-entered poll on any thread re-raise the same axis.
    pub fn tick(self: *EvalBudget, io: std.Io) ClojureWasmError!void {
        switch (self.trippedAxis()) {
            .none => {},
            .steps => return self.raiseSteps(),
            .deadline => return self.raiseDeadline(),
        }
        const n = atomics.rmw(u64, &self.steps, .Add, 1, .monotonic) + 1;
        if (self.step_ceiling) |ceiling| {
            if (n > ceiling) {
                self.trip(.steps);
                return self.raiseSteps();
            }
        }
        if (self.deadline_ns) |deadline| {
            if (n & clock_poll_mask == 0 and clock.nanoTime(io) > deadline) {
                self.trip(.deadline);
                return self.raiseDeadline();
            }
        }
    }

    /// Charge WALL CLOCK without charging a step — the entry point a BLOCKING
    /// primitive uses.
    ///
    /// `tick` only runs at a back-edge, and a blocking call makes none: it
    /// consumes time without consuming steps. So `(Thread/sleep 25000)` under a
    /// 3000 ms deadline ran the full 25 s and returned normally — the budget
    /// advertises a wall-clock bound and did not have one. Measured on the
    /// ClojureWasm playground, where one unauthenticated request could park the
    /// server for as long as it asked (D-571).
    ///
    /// Unthrottled, unlike `tick`'s every-1024th-step clock read: a blocking
    /// caller checks around a wait, so one clock read per check is nothing, and
    /// throttling it by a step counter that is not advancing would mean never
    /// reading at all.
    pub fn checkDeadline(self: *EvalBudget, io: std.Io) ClojureWasmError!void {
        return self.checkDeadlineAt(clock.nanoTime(io));
    }

    /// `checkDeadline` for a caller that has already read the clock — a
    /// blocking primitive needs `now` anyway, to work out how long it may
    /// wait, and a second syscall for the same instant is waste.
    pub fn checkDeadlineAt(self: *EvalBudget, now_ns: i64) ClojureWasmError!void {
        switch (self.trippedAxis()) {
            .none => {},
            .steps => return self.raiseSteps(),
            .deadline => return self.raiseDeadline(),
        }
        const deadline = self.deadline_ns orelse return;
        if (now_ns > deadline) {
            self.trip(.deadline);
            return self.raiseDeadline();
        }
    }

    fn raiseSteps(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_steps_exceeded, .{}, .{ .steps = self.step_ceiling orelse atomics.load(u64, &self.steps, .monotonic) });
    }
    fn raiseDeadline(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_deadline_exceeded, .{}, .{ .ms = self.deadline_ms });
    }
};

/// The budget the calling thread's NEXT spawned worker must adopt: the current
/// one, referenced. Called by a spawner on its own thread, before spawn.
pub fn inherit() ?*EvalBudget {
    return if (current) |b| b.ref() else null;
}

/// Worker-entry half of the handoff: install the inherited budget as this
/// thread's current. Pair with `release` on worker exit.
pub fn adopt(b: ?*EvalBudget) void {
    current = b;
}

/// Worker-exit half: drop the inherited reference and clear the slot.
pub fn release(b: ?*EvalBudget) void {
    current = null;
    if (b) |bud| bud.unref();
}

/// The current budget's wall-clock deadline as an absolute `clock.nanoTime`
/// instant, or null when none is armed. This is what a blocking primitive
/// passes to `Latch.wait` so the wait cannot outlast the budget.
pub fn deadlineOf() ?i64 {
    return if (current) |b| b.deadline_ns else null;
}

/// Charge the wall clock without charging a step — the check a blocking
/// primitive makes after it stops blocking, to convert "I waited out the
/// deadline" into the budget error.
pub fn checkDeadlineNow(io: std.Io) ClojureWasmError!void {
    if (current) |b| try b.checkDeadlineAt(clock.nanoTime(io));
}

/// Sleep `total_ns`, honouring the current budget's wall-clock deadline and
/// waking early if `cancel` is raised.
///
/// Both signals are latches on an instant, so neither is polled for. The wait
/// ends at `min(sleep end, budget deadline)`, or the moment `cancel` fires,
/// whichever comes first — one wait, no slices.
///
/// The slicing this replaces cost real time. `future-cancel` needs to notice a
/// cancel promptly, and with only a condition variable available the way to do
/// that was to wake every 20 ms and look. Each wakeup overshoots by a few ms, so
/// a 2000 ms sleep inside a future measured 2321-2358 ms — 17% long, on the most
/// idiomatic metered-blocking expression in Clojure, whether or not any budget
/// was armed. A latch is woken BY the cancel, so there is nothing to look for.
pub fn budgetedSleep(io: std.Io, total_ns: u64, cancel: ?*Latch) ClojureWasmError!void {
    const now = clock.nanoTime(io);
    if (current) |b| try b.checkDeadlineAt(now);

    // `Thread/sleep` accepts any `long`, so `total_ns` can be saturated to
    // maxInt(u64) — clamp before it reaches the i64 instant arithmetic.
    const span: i64 = @intCast(@min(total_ns, @as(u64, std.math.maxInt(i64) / 2)));
    var deadline = now +| span;
    if (deadlineOf()) |d| deadline = @min(deadline, d);

    // A registered worker counts as parked for either wait, so a sleeping
    // `future` does not stall a collection: `Latch.wait` brackets itself, the
    // plain sleep goes through `safepoint.blocking` here.
    if (cancel) |latch| {
        // Returns early iff the cancel fired; the caller re-checks and unwinds.
        _ = latch.wait(deadline);
    } else {
        const remaining = deadline - clock.nanoTime(io);
        if (remaining > 0) safepoint.blocking(io_default.sleep, .{@as(u64, @intCast(remaining))});
    }

    // A deadline that landed during the sleep still trips, so the caller unwinds
    // rather than returning as though it had waited out a budget it exceeded.
    try checkDeadlineNow(io);
}

// --- CLI env arming -------------------------------------------------------
// Parse-once config from `CLJW_EVAL_MAX_STEPS` / `CLJW_EVAL_DEADLINE_MS`, set at
// CLI startup and applied at eval start. Module-level like
// `gc_torture.pending_period` / `error_render.logFilePath` (parsed-once CLI
// config, not shared mutable runtime state).

var pending_max_steps: ?u64 = null;
var pending_deadline_ms: ?i64 = null;
var pending_heap_bytes: ?usize = null;

/// Record the parsed env budget at CLI startup (called from `cli.zig`).
pub fn configureFromEnv(max_steps: ?u64, deadline_ms: ?i64, heap_bytes: ?usize) void {
    pending_max_steps = max_steps;
    pending_deadline_ms = deadline_ms;
    pending_heap_bytes = heap_bytes;
}

/// The env-armed live-heap ceiling (bytes), or null. The heap cap lives on the
/// GcHeap (where byte accounting is), so `runner` reads this and sets
/// `rt.gc.heap_ceiling` + installs `heapExceededHook`.
pub fn pendingHeapCeiling() ?usize {
    return pending_heap_bytes;
}

/// GcHeap cap-breach hook (vtable, installed on `rt.gc.heap_exceeded_hook`):
/// SETS the uncatchable `eval_heap_exceeded` Info so the refused allocation
/// renders with a proper message + resource_exhausted Kind. `alloc` then returns
/// `error.OutOfMemory` (control flow); the Info drives rendering + uncatchability.
/// Lives here because gc_heap may not import the catalog (big_int cycle).
pub fn heapExceededHook(cap: usize) void {
    // We want raise's side effect (set the threadlocal Info), not its returned
    // error value — `alloc` returns error.OutOfMemory to propagate.
    _ = error_catalog.raise(.eval_heap_exceeded, .{}, .{ .bytes = cap }) catch {};
}

/// If either axis was armed via env, create the process budget and install it
/// as the calling (main) thread's `current`. The deadline is computed relative
/// to NOW so bootstrap time is not charged — call AFTER bootstrap, before the
/// user eval loop. Returns the budget so the caller can `unref` it at process
/// end (spawned workers hold their own references).
pub fn installFromEnv(gpa: std.mem.Allocator, io: std.Io) !?*EvalBudget {
    if (pending_max_steps == null and pending_deadline_ms == null) return null;
    const b = try EvalBudget.create(gpa, .{
        .step_ceiling = pending_max_steps,
        .deadline_ns = if (pending_deadline_ms) |ms| clock.nanoTime(io) + ms * std.time.ns_per_ms else null,
        .deadline_ms = pending_deadline_ms orelse 0,
    });
    current = b;
    return b;
}

// --- tests ---

const testing = std.testing;

test "step ceiling trips after ceiling+1 ticks, then latches" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const b = try EvalBudget.create(testing.allocator, .{ .step_ceiling = 3 });
    defer b.unref();
    try b.tick(th.io()); // steps=1
    try b.tick(th.io()); // steps=2
    try b.tick(th.io()); // steps=3
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io())); // steps=4 > 3
    try testing.expect(b.trippedAxis() == .steps);
    // Latched: a re-entered poll re-raises without advancing the program.
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io()));
}

test "a deadline already in the past trips at the first throttle boundary" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    // Deadline 1s in the PAST → the first clock read (step 1024) is already over.
    const b = try EvalBudget.create(testing.allocator, .{
        .deadline_ns = clock.nanoTime(th.io()) - std.time.ns_per_s,
        .deadline_ms = 1000,
    });
    defer b.unref();
    var i: u32 = 0;
    var tripped = false;
    while (i < 2048) : (i += 1) {
        b.tick(th.io()) catch {
            tripped = true;
            break;
        };
    }
    try testing.expect(tripped);
    try testing.expect(b.trippedAxis() == .deadline);
}

test "the step counter is shared: concurrent tickers trip one ceiling exactly" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const b = try EvalBudget.create(testing.allocator, .{ .step_ceiling = 100_000 });
    defer b.unref();

    const Worker = struct {
        fn run(bud: *EvalBudget, io: std.Io, tripped_count: *usize) void {
            // Each worker alone attempts MORE than the ceiling, so every one
            // of them must trip regardless of scheduling interleave.
            var i: u32 = 0;
            while (i < 110_000) : (i += 1) {
                bud.tick(io) catch {
                    _ = atomics.rmw(usize, tripped_count, .Add, 1, .monotonic);
                    return;
                };
            }
        }
    };
    var tripped_count: usize = 0;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ b, th.io(), &tripped_count });
    for (&threads) |*t| t.join();

    // Each worker attempts 110k against the 100k ceiling, so every worker must
    // have tripped (the latch re-raises), and the count is exact — the shared
    // counter is atomic, not the data race the Runtime-slot predecessor had.
    try testing.expectEqual(@as(usize, 4), tripped_count);
    try testing.expect(b.trippedAxis() == .steps);
}

test "inherit/adopt/release: the refcount survives a worker outliving the extent" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const b = try EvalBudget.create(testing.allocator, .{ .step_ceiling = 10 });
    current = b;
    // Spawner captures for the worker...
    const inherited = inherit();
    try testing.expect(inherited == b);
    // ...the extent exits and drops its own reference...
    current = null;
    b.unref();
    // ...the worker still holds a live budget: ticking past the ceiling trips.
    adopt(inherited);
    defer release(inherited);
    var tripped = false;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        (current.?).tick(th.io()) catch {
            tripped = true;
            break;
        };
    }
    try testing.expect(tripped);
}

test "budgetedSleep: a past deadline trips on the first poll" {
    const b = try EvalBudget.create(testing.allocator, .{
        .deadline_ns = clock.nanoTime(testing.io) - std.time.ns_per_s,
        .deadline_ms = 1,
    });
    current = b;
    defer release(b);
    try testing.expectError(error.ResourceExhausted, budgetedSleep(testing.io, 5 * std.time.ns_per_s, null));
    // Latched, so a second call re-raises the same axis rather than sleeping.
    try testing.expectEqual(EvalBudget.Axis.deadline, b.trippedAxis());
}

test "budgetedSleep: a metered sleep that does NOT expire keeps its duration" {
    // The regression this shape exists to prevent: slicing the sleep to poll for
    // a cancel made every metered sleep ~20% long. Waiting on an instant means
    // one uninterrupted wait whenever the deadline is beyond the sleep's end.
    const want_ns: u64 = 120 * std.time.ns_per_ms;
    const b = try EvalBudget.create(testing.allocator, .{
        .deadline_ns = clock.nanoTime(testing.io) + 60 * std.time.ns_per_s,
        .deadline_ms = 60_000,
    });
    current = b;
    defer release(b);
    const t0 = clock.nanoTime(testing.io);
    try budgetedSleep(testing.io, want_ns, null);
    const elapsed: u64 = @intCast(clock.nanoTime(testing.io) - t0);
    try testing.expect(elapsed >= want_ns);

    // NO upper bound is asserted, deliberately: a wall-clock RATIO bound in a
    // unit test cannot separate a systematic regression from a busy CI runner
    // (test_taxonomy.md § Wall-clock assertions). The duration property is
    // measured in ADR-0182's Consequences; the deterministic half is the lower
    // bound above — a metered sleep must not return EARLY.
}

test "budgetedSleep: no budget is one uninterrupted sleep" {
    current = null;
    const want_ns: u64 = 40 * std.time.ns_per_ms;
    const t0 = clock.nanoTime(testing.io);
    try budgetedSleep(testing.io, want_ns, null);
    const elapsed: u64 = @intCast(clock.nanoTime(testing.io) - t0);
    try testing.expect(elapsed >= want_ns);
}
