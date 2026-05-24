// SPDX-License-Identifier: EPL-2.0
//! Analyzer sub-module per D-030 split — `recur` form analyser.
//!
//! `recur` resolves against the nearest enclosing `loop*` or `fn*`
//! recur target on the lexical scope chain. Arity is validated
//! against the target's arity (a mismatch is a compile-time error,
//! not a runtime one — matches JVM Clojure's compile-time `recur`
//! arity check).

const std = @import("std");
const Form = @import("../form.zig").Form;
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_catalog = @import("../../runtime/error/catalog.zig");
const macro_dispatch = @import("../macro_dispatch.zig");
const analyzer_mod = @import("analyzer.zig");
const AnalyzeError = analyzer_mod.AnalyzeError;
const Scope = analyzer_mod.Scope;

pub fn analyzeRecur(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const target = if (scope) |s| s.recur_target else null;
    const tgt = target orelse return error_catalog.raise(.recur_outside_target, form.location, .{});

    const supplied_raw = items.len - 1;
    if (supplied_raw > std.math.maxInt(u16))
        return error_catalog.raise(.arity_too_large, form.location, .{
            .form = "recur",
            .got = supplied_raw,
        });
    const supplied: u16 = @intCast(supplied_raw);
    if (supplied != tgt.arity) {
        const kind_str = switch (tgt.kind) {
            .loop_kw => "loop*",
            .fn_kw => "fn*",
        };
        return error_catalog.raise(.recur_arity_mismatch, form.location, .{ .target = kind_str, .expected = tgt.arity, .got = supplied });
    }

    var args = try arena.alloc(Node, supplied);
    for (items[1..], 0..) |arg_form, i| {
        const sub = try analyzer_mod.analyze(arena, rt, env, scope, arg_form, macro_table);
        args[i] = sub.*;
    }

    const n = try arena.create(Node);
    n.* = .{ .recur_node = .{ .args = args, .loc = form.location } };
    return n;
}
