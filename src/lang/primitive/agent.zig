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

fn requireAgent(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!agent_mod.isAgent(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "agent", .actual = @tagName(v.tag()) });
}

/// `(agent init)` — construct an agent seeded with `init`. Option kwargs
/// (`:meta` / `:validator` / `:error-handler` / `:error-mode`) are a later slice.
pub fn agentFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "agent", .got = args.len, .min = 1 });
    if (args.len > 1)
        return error_catalog.raise(.agent_options_unsupported, loc, .{});
    return agent_mod.alloc(rt, env, args[0]);
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

    try agent_mod.send(rt, args[0], action);
    return args[0];
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "agent", .f = &agentFn },
    .{ .name = "send", .f = &sendFn },
    .{ .name = "send-off", .f = &sendFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
