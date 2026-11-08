// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.Future` — the Java METHOD NAMES over
//! cljw's native `.future`, which already has every semantic they need.
//!
//! Backend: impl-only
//! Impl deps: future, ex_info, worker_error, eval_budget, clock, TimeUnit
//! Clojure peer: clojure.core/deref, future-done?, future-cancel, future-cancelled?
//!
//! Surface: `.get` (`[]` | `[timeout unit]`), `.isDone`, `.isCancelled`,
//! `.cancel` (`[]` | `[mayInterruptIfRunning]`).
//!
//! No `___HOST_EXTENSION` and NOT on `_host_api.zig`'s `java_surfaces` list:
//! there is no `Future/…` static surface and no separate instance type to
//! register. `(future …)` already answers `Future` to `class`, so this file
//! only populates that native descriptor's method table — the `_atomic.zig`
//! shape, and the same `installNativeMethods` path `Throwable.zig` uses to put
//! `.getMessage` on `.ex_info`.
//!
//! Every method here maps onto an existing primitive rather than reaching into
//! the Future cell: `.get` is `deref`'s future arm (so a cancelled future still
//! throws CancellationException and a failed one still re-raises the worker's
//! MARSHALLED error per ADR-0120, instead of this file inventing a second set
//! of answers), `.isDone` is `realized?`, `.cancel` is `future-cancel`.
//!
//! Divergence AD-065: `.cancel`'s `mayInterruptIfRunning` argument is ACCEPTED
//! and IGNORED. cljw's cancellation is cooperative (D-442 / ADR-0153) — a
//! blocking primitive polls `cancelRequested` and aborts; a thunk in a tight
//! CPU loop runs to completion either way. So `false` cannot mean "let it
//! finish but report cancelled" the way the JVM's flag does, and honouring only
//! one of the two values would be a worse lie than ignoring it.

const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const future_mod = @import("../../../future.zig");
const ex_info = @import("../../../collection/ex_info.zig");
const worker_error = @import("../../../concurrency/worker_error.zig");
const eval_budget = @import("../../../concurrency/eval_budget.zig");
const clock = @import("../../../clock.zig");
const TimeUnit = @import("TimeUnit.zig");

/// Shared terminal-state reading for a `deref` that came back null. Ordered as
/// `stm.zig`'s future arm orders it, so `.get` and `@` cannot disagree about
/// why the same future stopped: still-pending means the eval budget's wall
/// clock cut it, then cancellation, then the marshalled worker error.
fn raiseForNullDeref(rt: *Runtime, f: Value, loc: SourceLocation) anyerror {
    if (!future_mod.isRealised(f)) {
        eval_budget.checkDeadlineNow(rt.io) catch |e| return e;
    }
    if (future_mod.isCancelled(f)) {
        return error_catalog.raise(.future_cancelled, loc, .{});
    }
    if (future_mod.errorValue(f)) |ev| return worker_error.reraise(ev);
    return error_catalog.raise(.future_thunk_failed, loc, .{});
}

/// `(.get f)` — block until realised, then the value. Same answers as `@f`.
/// `(.get f timeout unit)` — block up to the timeout; on expiry throw a real
/// `java.util.concurrent.TimeoutException`, as the JVM does. This is the one
/// place the Java surface must NOT reuse cljw's 3-arity `deref`, which returns
/// a caller-supplied default instead of throwing — `hive-weave.guarded` catches
/// TimeoutException to decide whether to cancel the task, so a returned default
/// would silently read as success.
fn get(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len != 1 and args.len != 3)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = ".get", .expected = 1 });
    const f = args[0];

    if (args.len == 1) {
        if (future_mod.deref(f, eval_budget.deadlineOf())) |v| return v;
        return raiseForNullDeref(rt, f, loc);
    }

    const timeout = try error_catalog.expectInteger(args[1], ".get", loc);
    const timeout_ns = TimeUnit.nanosOf(args[2], @intCast(timeout)) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = ".get",
            .expected = "a java.util.concurrent.TimeUnit",
            .actual = @tagName(args[2].tag()),
        });

    // The eval budget still bounds the wait: whichever deadline lands first
    // wins, so a generous `.get` timeout under a metered eval cannot outlive
    // the budget (and `raiseForNullDeref` then reports the budget, not a
    // TimeoutException, because the future is still pending).
    var deadline = clock.nanoTime(rt.io) +| @max(timeout_ns, 0);
    if (eval_budget.deadlineOf()) |budget_deadline| deadline = @min(deadline, budget_deadline);

    if (future_mod.deref(f, deadline)) |v| return v;
    if (!future_mod.isRealised(f)) {
        // Budget first (it is the uncatchable one), then the honest timeout.
        try eval_budget.checkDeadlineNow(rt.io);
        const ex = try ex_info.allocException(rt, "future did not complete within the timeout", "TimeoutException");
        return worker_error.reraise(ex);
    }
    return raiseForNullDeref(rt, f, loc);
}

/// `(.isDone f)` — `realized?`. True for a future that completed with a value,
/// completed with an error, OR was cancelled, matching the JVM: `isDone` asks
/// whether the task is finished, not whether it succeeded.
fn isDone(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isDone", args, 1, loc);
    return Value.initBoolean(future_mod.isRealised(args[0]));
}

/// `(.isCancelled f)` — `future-cancelled?`.
fn isCancelled(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isCancelled", args, 1, loc);
    return Value.initBoolean(future_mod.isCancelled(args[0]));
}

/// `(.cancel f)` / `(.cancel f mayInterruptIfRunning)` — `future-cancel`. True
/// iff this call is the one that cancelled a still-pending future. The flag is
/// accepted and ignored (AD-065).
fn cancel(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArityRange(".cancel", args, 1, 2, loc);
    return Value.initBoolean(future_mod.cancel(args[0]));
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "get", .f = &get },
    .{ .name = "isDone", .f = &isDone },
    .{ .name = "isCancelled", .f = &isCancelled },
    .{ .name = "cancel", .f = &cancel },
};

/// Populate the per-Runtime `.future` native descriptor's method table.
/// Idempotent. Called at runtime init alongside the other native installers.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.future);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}
