// SPDX-License-Identifier: EPL-2.0
//! EvalBudget — an in-process bound on a single eval's execution (ADR-0125):
//! a step ceiling (deterministic, dual-backend-testable) AND/OR a wall-clock
//! deadline (the real untrusted-code bound). Both axes are optional; an
//! unmetered budget (both null) is the default and costs one branch per poll.
//!
//! Polled at the back-edge safe points of BOTH backends (VM + TreeWalk) so a
//! non-allocating infinite loop is caught either way. On expiry it raises an
//! UNCATCHABLE `resource_exhausted` error (kindToHostClass→null): untrusted
//! code cannot swallow its own timeout via `(try … (catch Throwable …))`.
//! Once tripped it LATCHES — every subsequent poll re-raises — so a
//! straight-line burst after the (uncatchable) raise cannot make progress.
//!
//! F-006: the wall-clock read goes through the injected `io` (Runtime.io),
//! never a global clock.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none (armed via CLJW_EVAL_MAX_STEPS / CLJW_EVAL_DEADLINE_MS;
//!   a `cljw.eval/with-budget` scoped surface is D-355's call)
const std = @import("std");
const error_catalog = @import("../error/catalog.zig");
const clock = @import("../clock.zig");
const ClojureWasmError = error_catalog.ClojureWasmError;

pub const EvalBudget = struct {
    /// Max back-edge crossings; null = no step bound.
    step_ceiling: ?u64 = null,
    /// Monotonic-clock deadline in ns (clock.nanoTime); null = no time bound.
    deadline_ns: ?i64 = null,
    /// The configured wall-clock budget in ms, for the error message only.
    deadline_ms: i64 = 0,
    /// Running back-edge counter.
    steps: u64 = 0,
    /// Which axis tripped (latch): once non-`.none`, every tick re-raises it.
    tripped: Axis = .none,

    pub const Axis = enum { none, steps, deadline };

    /// Read the wall clock only every 1024th step — a clock syscall per
    /// back-edge would dominate the hot loop. Power-of-two so the throttle
    /// test is a mask, not a modulo.
    const clock_poll_mask: u64 = 1023;

    /// Charge one back-edge crossing. Raises (uncatchable) on expiry; the
    /// latch makes a re-entered poll re-raise the same axis.
    pub fn tick(self: *EvalBudget, io: std.Io) ClojureWasmError!void {
        switch (self.tripped) {
            .none => {},
            .steps => return self.raiseSteps(),
            .deadline => return self.raiseDeadline(),
        }
        self.steps += 1;
        if (self.step_ceiling) |ceiling| {
            if (self.steps > ceiling) {
                self.tripped = .steps;
                return self.raiseSteps();
            }
        }
        if (self.deadline_ns) |deadline| {
            if (self.steps & clock_poll_mask == 0 and clock.nanoTime(io) > deadline) {
                self.tripped = .deadline;
                return self.raiseDeadline();
            }
        }
    }

    fn raiseSteps(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_steps_exceeded, .{}, .{ .steps = self.step_ceiling orelse self.steps });
    }
    fn raiseDeadline(self: *const EvalBudget) ClojureWasmError {
        return error_catalog.raise(.eval_deadline_exceeded, .{}, .{ .ms = self.deadline_ms });
    }
};

// --- CLI env arming -------------------------------------------------------
// Parse-once config from `CLJW_EVAL_MAX_STEPS` / `CLJW_EVAL_DEADLINE_MS`, set at
// CLI startup and applied to the process's Runtime at eval start. Module-level
// like `gc_torture.pending_period` / `error_render.logFilePath` (parsed-once CLI
// config, not shared mutable runtime state — the budget COUNTER lives on the
// Runtime per F-006). A future `with-budget` / multi-tenant path sets the slot
// directly, bypassing this env convenience.

var pending_max_steps: ?u64 = null;
var pending_deadline_ms: ?i64 = null;

/// Record the parsed env budget at CLI startup (called from `cli.zig`).
pub fn configureFromEnv(max_steps: ?u64, deadline_ms: ?i64) void {
    pending_max_steps = max_steps;
    pending_deadline_ms = deadline_ms;
}

/// If either axis was armed via env, install the budget into `slot`
/// (`&rt.eval_budget`). The deadline is computed relative to NOW so bootstrap
/// time is not charged — call AFTER bootstrap, before the user eval loop.
pub fn installFromEnv(slot: *?EvalBudget, io: std.Io) void {
    if (pending_max_steps == null and pending_deadline_ms == null) return;
    slot.* = .{
        .step_ceiling = pending_max_steps,
        .deadline_ns = if (pending_deadline_ms) |ms| clock.nanoTime(io) + ms * std.time.ns_per_ms else null,
        .deadline_ms = pending_deadline_ms orelse 0,
    };
}

// --- tests ---

const testing = std.testing;

test "unmetered budget never trips" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var b: EvalBudget = .{};
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) try b.tick(th.io());
    try testing.expect(b.tripped == .none);
}

test "step ceiling trips after ceiling+1 ticks, then latches" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var b: EvalBudget = .{ .step_ceiling = 3 };
    try b.tick(th.io()); // steps=1
    try b.tick(th.io()); // steps=2
    try b.tick(th.io()); // steps=3
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io())); // steps=4 > 3
    try testing.expect(b.tripped == .steps);
    // Latched: a re-entered poll re-raises without advancing the program.
    try testing.expectError(ClojureWasmError.ResourceExhausted, b.tick(th.io()));
}

test "a deadline already in the past trips at the first throttle boundary" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    // Deadline 1s in the PAST → the first clock read (step 1024) is already over.
    var b: EvalBudget = .{ .deadline_ns = clock.nanoTime(th.io()) - std.time.ns_per_s, .deadline_ms = 1000 };
    var i: u32 = 0;
    var tripped = false;
    while (i < 2048) : (i += 1) {
        b.tick(th.io()) catch {
            tripped = true;
            break;
        };
    }
    try testing.expect(tripped);
    try testing.expect(b.tripped == .deadline);
}
