// SPDX-License-Identifier: EPL-2.0
//! cljw.eval/with-budget — run a thunk under an in-process execution budget
//! (ADR-0125's deferred host surface) and RECOVER from expiry as a value, not an
//! uncatchable kill. `(cljw.eval/with-budget opts thunk)`:
//!   opts  = {:max-steps N :deadline-ms M :max-heap-mb K} (any subset; nil = none)
//!   thunk = a 0-arg fn
//! Returns the thunk's value on success, or `{:cljw.eval/exhausted <axis>}` with
//! <axis> = :steps / :deadline / :heap when a budget tripped.
//!
//! The budget error is uncatchable from Clojure `(try … (catch …))` — untrusted
//! code cannot swallow its own timeout — but THIS host frame (the sanctioned
//! embedder boundary, like zwasm's host receiving the trap as a return value)
//! catches the raw Zig error and reports it. The prior budget + heap cap are
//! saved and restored over the dynamic extent, so a long-lived server resets per
//! call and nested with-budget calls compose (the D-355 in-process eval path).
//!
//! Backend: impl-only
//! Impl deps: eval_budget
//! Clojure peer: cljw.eval/with-budget
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_mod = @import("../../error/info.zig");
const error_catalog = @import("../../error/catalog.zig");
const eval_budget = @import("../../concurrency/eval_budget.zig");
const clock = @import("../../clock.zig");
const map_mod = @import("../../collection/map.zig");
const keyword_mod = @import("../../keyword.zig");

/// Read an optional positive integer opt; null when absent / non-integer / <= 0.
/// (A budget value beyond i48 is a bignum — `isInt` is false — and reads as
/// "unset" for that axis, i.e. effectively unmetered, which is the right cap for
/// an absurdly large bound.)
fn optInt(rt: *Runtime, opts: Value, key: []const u8) !?i64 {
    const v = map_mod.get(opts, try keyword_mod.intern(rt, null, key)) catch return null;
    if (!v.isInt()) return null;
    const n: i64 = @intCast(v.asInteger());
    return if (n > 0) n else null;
}

pub fn withBudgetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("cljw.eval/with-budget", args, 2, loc);
    const opts = args[0];
    const ot = opts.tag();
    if (ot != .array_map and ot != .hash_map and !opts.isNil())
        return error_catalog.raise(.eval_opts_invalid, loc, .{ .detail = "the options argument must be a map" });
    const thunk = args[1];

    const max_steps = try optInt(rt, opts, "max-steps");
    const deadline_ms = try optInt(rt, opts, "deadline-ms");
    const max_heap_mb = try optInt(rt, opts, "max-heap-mb");

    // Save the prior budget + heap cap; restore over the dynamic extent so the
    // process's ambient budget (CLI env arming) and any enclosing with-budget
    // are unaffected once this call returns.
    const saved_budget = rt.eval_budget;
    const saved_heap = rt.gc.heap_ceiling;
    const saved_hook = rt.gc.heap_exceeded_hook;
    defer {
        rt.eval_budget = saved_budget;
        rt.gc.heap_ceiling = saved_heap;
        rt.gc.heap_exceeded_hook = saved_hook;
    }

    rt.eval_budget = if (max_steps != null or deadline_ms != null) .{
        .step_ceiling = if (max_steps) |s| @intCast(s) else null,
        .deadline_ns = if (deadline_ms) |ms| clock.nanoTime(rt.io) + ms * std.time.ns_per_ms else null,
        .deadline_ms = deadline_ms orelse 0,
    } else null;
    if (max_heap_mb) |mb| {
        rt.gc.heap_ceiling = @as(usize, @intCast(mb)) * 1024 * 1024;
        rt.gc.heap_exceeded_hook = &eval_budget.heapExceededHook;
    } else {
        rt.gc.heap_ceiling = null;
    }

    const result = rt.vtable.?.callFn(rt, env, thunk, &.{}, loc) catch |err| switch (err) {
        // The host frame catches the (Clojure-uncatchable) budget breach. Heap
        // surfaces as OutOfMemory (alloc's Zig error); steps/deadline as
        // ResourceExhausted (the budget raise). Report the axis as a value.
        error.ResourceExhausted, error.OutOfMemory => {
            const axis: []const u8 = if (err == error.OutOfMemory)
                "heap"
            else if (rt.eval_budget) |b| (switch (b.tripped) {
                .deadline => "deadline",
                else => "steps",
            }) else "steps";
            // Restore the prior budget + heap cap BEFORE building the result map:
            // the breaching budget is still installed here, so a heap breach would
            // re-trip on the map's own allocations (and a step/deadline budget
            // would keep counting). The `defer` above also restores — redundant,
            // not harmful.
            rt.eval_budget = saved_budget;
            rt.gc.heap_ceiling = saved_heap;
            rt.gc.heap_exceeded_hook = saved_hook;
            error_mod.clearLastError();
            var m = map_mod.empty();
            m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, "cljw.eval", "exhausted"), try keyword_mod.intern(rt, null, axis));
            return m;
        },
        else => return err,
    };
    return result;
}

/// Register `cljw.eval/with-budget`. Called from `cljw/_host_api.zig::installAll`.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("cljw.eval");
    _ = try env.intern(ns, "with-budget", Value.initBuiltinFn(&withBudgetFn), null);
}
