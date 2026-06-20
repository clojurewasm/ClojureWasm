// SPDX-License-Identifier: EPL-2.0
//! Agent primitives — Clojure-ns surface for `(agent init)` / `(send a f & args)`
//! / `(send-off a f & args)` (Phase B #6 first slice). `@agent` routes through
//! `deref` (stm.zig). `await` is core.clj over `send` + `promise`.
//!
//! The serial-execution engine + GC discipline live in `runtime/agent.zig`. This
//! surface builds the `[f & args]` action vector and hands it to `agent.send`.
//! send and send-off share one path in the first slice (the two-pool starvation
//! avoidance is a non-observable throughput property; ADR-0093 D1).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const agent_mod = @import("../../runtime/agent.zig");
const vector = @import("../../runtime/collection/vector.zig");
const promise_mod = @import("../../runtime/promise.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const higher_order = @import("higher_order.zig");
const ex_info = @import("../../runtime/collection/ex_info.zig");

fn requireAgent(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!agent_mod.isAgent(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "agent", .actual = @tagName(v.tag()) });
}

/// Run the agent's validator (if any) against `newval` BEFORE exposing it,
/// throwing IllegalStateException "Invalid reference state" on a falsey return
/// (clj `ARef.setValidator`). Used for the INITIAL value at construction; the
/// per-action validation runs on the drainer (`runtime/agent.zig` validateState).
fn validateOrThrow(rt: *Runtime, env: *Env, a: Value, newval: Value, loc: SourceLocation) !void {
    const v = agent_mod.validatorOf(a);
    if (v.isNil()) return;
    const ok = try higher_order.invokeCallable(rt, env, v, &[_]Value{newval}, loc);
    if (!ok.isTruthy()) {
        dispatch.last_thrown_exception = try ex_info.allocException(rt, "Invalid reference state", "IllegalStateException");
        return error.ThrownValue;
    }
}

/// `(agent init & {:keys [meta validator error-handler error-mode]})` — construct
/// an agent seeded with `init`, with optional `:meta` map + `:validator` fn ctor
/// kwargs (clj `setup-reference`, mirroring atom D-223). The validator validates
/// the INITIAL value, so `(agent -1 :validator pos?)` throws. Unknown keys are
/// ignored (clj's setup-reference acts only on :meta/:validator; :error-handler /
/// :error-mode set the handler/mode). An odd-length options tail is an error.
pub fn agentFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "agent", .got = args.len, .min = 1 });
    const a = try agent_mod.alloc(rt, env, args[0]);
    if (args.len == 1) return a;
    if ((args.len - 1) % 2 != 0)
        return error_catalog.raise(.ref_options_odd, loc, .{ .fn_name = "agent" });

    const kw_meta = try keyword_mod.intern(rt, null, "meta");
    const kw_validator = try keyword_mod.intern(rt, null, "validator");
    const kw_error_handler = try keyword_mod.intern(rt, null, "error-handler");
    const kw_error_mode = try keyword_mod.intern(rt, null, "error-mode");
    const kw_continue = try keyword_mod.intern(rt, null, "continue");
    var validator: Value = .nil_val;
    var has_handler = false;
    var explicit_mode: ?bool = null; // null = use clj default; true = :fail
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const val = args[i + 1];
        if (@intFromEnum(k) == @intFromEnum(kw_meta)) {
            agent_mod.setMeta(a, val);
        } else if (@intFromEnum(k) == @intFromEnum(kw_validator)) {
            agent_mod.setValidator(a, val);
            validator = val;
        } else if (@intFromEnum(k) == @intFromEnum(kw_error_handler)) {
            agent_mod.setErrorHandler(a, val);
            has_handler = !val.isNil();
        } else if (@intFromEnum(k) == @intFromEnum(kw_error_mode)) {
            explicit_mode = @intFromEnum(val) != @intFromEnum(kw_continue);
        }
    }
    // clj: error-mode defaults to :continue iff an error-handler was supplied,
    // else :fail; an explicit :error-mode wins. The Agent's own default is :fail.
    if (explicit_mode) |fail| {
        agent_mod.setFailMode(a, fail);
    } else if (has_handler) {
        agent_mod.setFailMode(a, false);
    }
    // clj's setValidator validates the current (initial) value — throw if rejected.
    if (!validator.isNil()) try validateOrThrow(rt, env, a, args[0], loc);
    return a;
}

/// `(send a f & args)` / `(send-off a f & args)` — dispatch an action; returns
/// the agent. Builds the `[f & args]` action vector (on the GC heap, before the
/// queue lock) and enqueues it. Both share one path in the first slice.
pub fn sendFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "send", .got = args.len, .min = 2 });
    try requireAgent("send", args[0], loc);

    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    try items.append(rt.gpa, args[1]); // f
    try items.appendSlice(rt.gpa, args[2..]); // & args
    const action = try vector.fromSlice(rt, items.items);

    agent_mod.send(rt, args[0], action) catch |e| switch (e) {
        error.AgentFailed => return error_catalog.raise(.agent_failed, loc, .{}),
        else => return e,
    };
    return args[0];
}

/// `(agent-error a)` — the error that failed the agent (`:fail` mode), or nil.
pub fn agentErrorFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("agent-error", args, 1, loc);
    try requireAgent("agent-error", args[0], loc);
    return agent_mod.agentError(args[0]);
}

/// `(restart-agent a new-state)` — clear the failure, set the state, resume
/// draining pending actions. Returns the new state. (clj's `:clear-actions`
/// option is a later slice; extra args are rejected rather than ignored.)
pub fn restartFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("restart-agent", args, 2, loc);
    try requireAgent("restart-agent", args[0], loc);
    try agent_mod.restart(rt, args[0], args[1], false);
    return args[1];
}

/// `(__agent-set-fail-mode a fail?)` — true = `:fail`, false = `:continue`.
pub fn setFailModeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("set-error-mode!", args, 2, loc);
    try requireAgent("set-error-mode!", args[0], loc);
    agent_mod.setFailMode(args[0], args[1].isTruthy());
    return args[0];
}

/// `(__agent-fail-mode? a)` — true iff the error mode is `:fail`.
pub fn failModeQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("error-mode", args, 1, loc);
    try requireAgent("error-mode", args[0], loc);
    return Value.initBoolean(agent_mod.failMode(args[0]));
}

/// `(set-error-handler! a handler-fn)` — install the error handler `(fn [a ex])`
/// called when an action throws (or nil to clear). Returns nil (clj parity).
pub fn setErrorHandlerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("set-error-handler!", args, 2, loc);
    try requireAgent("set-error-handler!", args[0], loc);
    agent_mod.setErrorHandler(args[0], args[1]);
    return Value.nil_val;
}

/// `(error-handler a)` — the installed error handler fn, or nil.
pub fn errorHandlerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("error-handler", args, 1, loc);
    try requireAgent("error-handler", args[0], loc);
    return agent_mod.errorHandlerOf(args[0]);
}

/// `(__agent-await a)` — `await`'s engine half: enqueue a barrier action and
/// return a promise the drainer delivers AFTER that action's `notifyWatches`.
/// `await` (core.clj) blocks on the promise, so it returns only once every
/// action sent so far (incl. the barrier's own no-op `[s s]` fire) has run —
/// the deliver-in-body race fix (D-368). One barrier per agent; `await` maps it
/// over its agents then `(dorun (map deref …))`.
pub fn awaitFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("await", args, 1, loc);
    try requireAgent("await", args[0], loc);
    const p = try promise_mod.alloc(rt);
    agent_mod.sendAwait(rt, args[0], p) catch |e| switch (e) {
        error.AgentFailed => return error_catalog.raise(.agent_failed, loc, .{}),
        else => return e,
    };
    return p;
}

/// `send-via` / `set-agent-send-executor!` / `set-agent-send-off-executor!`
/// (ADR-0155 / AD-045): cljw exposes no configurable executor — agents run on a
/// per-agent worker, not a user-supplied `ExecutorService`. Silently ignoring the
/// user's explicit executor would mask a dropped semantic (permanent-no-op
/// forbidden), so these raise explicitly rather than no-op or fake-accept.
pub fn executorUnsupportedFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = args;
    return error_catalog.raise(.agent_executor_unsupported, loc, .{});
}

/// `(release-pending-sends)` — dispatch the sends held during the current action
/// now; returns the count dispatched (0 outside an action). Subsequent in-action
/// sends stay held (clj `Agent.releasePendingSends`; ADR-0155 / D-442).
pub fn releasePendingSendsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("release-pending-sends", args, 0, loc);
    return Value.initInteger(@intCast(agent_mod.releasePending(rt)));
}

/// `(shutdown-agents)` — initiate agent-system shutdown: running actions finish,
/// no new actions are accepted (subsequent sends reject). Process-wide and
/// irreversible, matching clj `shutdown-agents`. Returns nil (ADR-0155 / D-442).
pub fn shutdownAgentsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("shutdown-agents", args, 0, loc);
    agent_mod.shutdownAgents();
    return Value.nil_val;
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "agent", .f = &agentFn },
    .{ .name = "send", .f = &sendFn },
    .{ .name = "send-off", .f = &sendFn },
    .{ .name = "agent-error", .f = &agentErrorFn },
    .{ .name = "restart-agent", .f = &restartFn },
    .{ .name = "__agent-set-fail-mode", .f = &setFailModeFn },
    .{ .name = "__agent-fail-mode?", .f = &failModeQFn },
    .{ .name = "set-error-handler!", .f = &setErrorHandlerFn },
    .{ .name = "error-handler", .f = &errorHandlerFn },
    .{ .name = "__agent-await", .f = &awaitFn },
    .{ .name = "release-pending-sends", .f = &releasePendingSendsFn },
    .{ .name = "shutdown-agents", .f = &shutdownAgentsFn },
    // ADR-0155 / AD-045 — no configurable executor in cljw; these raise.
    .{ .name = "send-via", .f = &executorUnsupportedFn },
    .{ .name = "set-agent-send-executor!", .f = &executorUnsupportedFn },
    .{ .name = "set-agent-send-off-executor!", .f = &executorUnsupportedFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
