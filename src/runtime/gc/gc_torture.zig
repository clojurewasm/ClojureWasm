// SPDX-License-Identifier: EPL-2.0
//! GC torture mode (D-250): force a stop-the-world collect at every Nth VM
//! back-edge safe point so a missing root surfaces DETERMINISTICALLY (a UAF on
//! the very next collect) instead of as a rare, path-dependent crash.
//!
//! This is a TEST/VALIDATION mode, NOT production auto-collection. It is armed
//! only by the `CLJW_GC_TORTURE` env var (read once at CLI startup) and stays
//! fully inert otherwise — `period == 0` is a single global load + a predicted-
//! not-taken branch on the VM's hottest path. Production threshold-driven
//! auto-collect remains gated (D-244 #4); a test-mode forced collect at a clean
//! safe point is explicitly distinct from that flip.
//!
//! Two-stage arming so torture validates STEADY-STATE user code, not core
//! bootstrap: `configure(n)` (CLI startup) records the requested period but
//! leaves the mode inert; `arm()` (called once AFTER `setupCoreAot`) activates
//! it. Core bootstrap (AOT restore + lib loading) has its own
//! namespace-creation-window concern tracked separately as D-251 — collecting
//! mid-bootstrap is out of #4a' scope, so torture deliberately skips it.
//!
//! Validation scope: the back-edge poll fires BETWEEN bytecode steps, so the
//! safepoint torture (`tick`) catches gaps in the poll-boundary root set
//! (operand stack, locals, binding frames, ns vars, macro slot, permanent
//! roots). The SEPARATE alloc-driven torture (`allocTick`, D-386) fires INSIDE
//! `gc.alloc`, so it additionally exercises the MID-OP window: a VM op whose
//! operand watermark (`ar.op_top`) or in-flight fabrication (`gc_self_guard`) is
//! not published before an allocation surfaces here as a deterministic UAF. This
//! is the validation infra the op_top register-hoist (D-386 sub-step 2) needs —
//! and a stronger check for every existing alloc site. It is armed by a
//! SEPARATE env var (`CLJW_GC_TORTURE_ALLOC`), independent of `CLJW_GC_TORTURE`,
//! and uses `root_set.active_env` (the threadlocal the VM publishes) for the
//! collect's root context.

const std = @import("std");

/// Requested period from `CLJW_GC_TORTURE` (0 = unset). Held inert until
/// `arm()` copies it into `period` post-bootstrap.
var pending_period: u32 = 0;

/// Active collect cadence: collect every `period` back-edge polls. `0` =
/// disarmed (the default, and the state during bootstrap before `arm()`).
/// Process-wide single-writer (CLI startup + `arm()`, both before any user
/// eval), then read-only, so a plain global is sufficient (no atomics).
pub var period: u32 = 0;

/// Per-thread poll counter. Threadlocal so each worker's cadence is
/// independent and the count needs no synchronisation.
threadlocal var counter: u32 = 0;

/// Alloc-driven torture (D-386 sub-step 2 validation infra): collect every
/// `alloc_period`-th `gc.alloc` so a MID-OP rooting gap (unpublished operand
/// watermark / fabrication) surfaces deterministically. Independent of the
/// safepoint `period` (separate env var `CLJW_GC_TORTURE_ALLOC`), so the two
/// modes arm separately. Same two-stage arming + `0`-inert-guard discipline.
var pending_alloc_period: u32 = 0;
pub var alloc_period: u32 = 0;
threadlocal var alloc_counter: u32 = 0;

/// Teardown fault injection (ADR-0176 / D-548(a) red test):
/// `CLJW_TORTURE_TEARDOWN_DELAY_MS=N` makes `Runtime.deinit` sleep N ms AFTER
/// its live-worker guard and BEFORE freeing — so a guard regression turns the
/// teardown-vs-worker race back into a (near-)deterministic glibc abort under
/// a fire-and-forget allocating thunk. Inert (0) unless the env var is set;
/// read once at CLI startup, no arming stage (it fires at most once, at exit).
pub var teardown_delay_ns: u64 = 0;

/// Record the requested teardown delay (`CLJW_TORTURE_TEARDOWN_DELAY_MS`).
pub fn configureTeardownDelay(ms: u32) void {
    teardown_delay_ns = @as(u64, ms) * 1_000_000;
}

/// Record the requested torture period from the parsed `CLJW_GC_TORTURE`
/// value. Does NOT activate — `arm()` does, post-bootstrap. `n == 0` is a
/// no-op (mode stays off).
pub fn configure(n: u32) void {
    pending_period = n;
}

/// Record the requested ALLOC-driven torture period (`CLJW_GC_TORTURE_ALLOC`).
/// Like `configure`, does not activate until `arm()`. `n == 0` is a no-op.
pub fn configureAlloc(n: u32) void {
    pending_alloc_period = n;
}

/// Activate torture mode (called once after core bootstrap completes) by
/// promoting the requested period(s). Inert if `configure`/`configureAlloc` was
/// never called with a positive value.
pub fn arm() void {
    period = pending_period;
    alloc_period = pending_alloc_period;
}

/// Advance the per-thread poll counter; return true on every `period`-th call
/// (so the VM should run a torture collect). Always false when disarmed —
/// `period == 0` short-circuits so a direct call is safe even off the hot
/// path (the VM still guards with `if (period != 0)` to skip the increment).
pub fn tick() bool {
    if (period == 0) return false;
    counter += 1;
    if (counter >= period) {
        counter = 0;
        return true;
    }
    return false;
}

/// Advance the per-thread ALLOC counter; return true every `alloc_period`-th
/// call. `alloc_period == 0` short-circuits (inert default), so `gc.alloc` pays
/// one global load + a predicted-not-taken branch when the mode is off.
pub fn allocTick() bool {
    if (alloc_period == 0) return false;
    alloc_counter += 1;
    if (alloc_counter >= alloc_period) {
        alloc_counter = 0;
        return true;
    }
    return false;
}

const testing = std.testing;

fn reset() void {
    pending_period = 0;
    period = 0;
    counter = 0;
    pending_alloc_period = 0;
    alloc_period = 0;
    alloc_counter = 0;
}

test "tick is always false when disarmed (period == 0)" {
    reset();
    for (0..100) |_| try testing.expect(!tick());
}

test "configure alone does not activate; arm() promotes it" {
    reset();
    configure(2);
    try testing.expect(!tick()); // still inert before arm()
    try testing.expect(!tick());
    arm();
    try testing.expect(!tick()); // call 1 after arm
    try testing.expect(tick()); // call 2 -> fire
    reset();
}

test "tick fires every period-th call when armed" {
    reset();
    configure(3);
    arm();
    try testing.expect(!tick());
    try testing.expect(!tick());
    try testing.expect(tick());
    try testing.expect(!tick());
    try testing.expect(!tick());
    try testing.expect(tick());
    reset();
}

test "period == 1 fires on every call" {
    reset();
    configure(1);
    arm();
    for (0..10) |_| try testing.expect(tick());
    reset();
}

test "alloc torture is independent of safepoint torture" {
    reset();
    configureAlloc(2);
    // safepoint `tick` stays inert (only alloc mode armed)
    try testing.expect(!allocTick()); // before arm()
    arm();
    try testing.expect(!tick()); // safepoint mode never configured
    try testing.expect(!allocTick()); // call 1 after arm
    try testing.expect(allocTick()); // call 2 -> fire
    try testing.expect(!allocTick());
    try testing.expect(allocTick());
    reset();
    // and the reverse: safepoint armed, alloc inert
    configure(1);
    arm();
    try testing.expect(!allocTick());
    try testing.expect(tick());
    reset();
}
