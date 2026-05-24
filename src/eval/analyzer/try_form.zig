// SPDX-License-Identifier: EPL-2.0
//! Analyzer sub-module per D-030 split — `try` / `catch` /
//! `finally` form analysers.
//!
//! Note: filename is `try_form.zig` rather than `try.zig` because
//! `try` is a Zig keyword and Zig's module identifier referencing
//! works smoother with a non-keyword filename. The clause head text
//! that the analyzer matches is still the bare `try` Clojure form.

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

pub fn analyzeTry(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const rest = items[1..];
    var split: usize = 0;
    while (split < rest.len) : (split += 1) {
        if (isClauseHead(rest[split])) break;
    }

    const body_forms = rest[0..split];
    const clause_forms = rest[split..];

    const body_node = if (body_forms.len == 0)
        try analyzer_mod.makeConstant(arena, .nil_val, form)
    else if (body_forms.len == 1)
        try analyzer_mod.analyze(arena, rt, env, scope, body_forms[0], macro_table)
    else blk: {
        var sub = try arena.alloc(Node, body_forms.len);
        for (body_forms, 0..) |f, i| {
            const n_b = try analyzer_mod.analyze(arena, rt, env, scope, f, macro_table);
            sub[i] = n_b.*;
        }
        const dn = try arena.create(Node);
        dn.* = .{ .do_node = .{ .forms = sub, .loc = form.location } };
        break :blk dn;
    };

    var clauses: std.ArrayList(node_mod.TryNode.CatchClause) = .empty;
    defer clauses.deinit(arena);
    var finally_node: ?*const Node = null;
    var seen_finally = false;

    for (clause_forms) |cf| {
        if (seen_finally)
            return error_catalog.raise(.try_clause_after_finally, cf.location, .{});
        const head = cf.data.list[0].data.symbol.name;
        if (std.mem.eql(u8, head, "catch")) {
            const cc = try analyzeCatchClause(arena, rt, env, scope, cf, macro_table);
            try clauses.append(arena, cc);
        } else if (std.mem.eql(u8, head, "finally")) {
            const fn_b = try analyzeFinallyClause(arena, rt, env, scope, cf, macro_table);
            finally_node = fn_b;
            seen_finally = true;
        } else return error_catalog.raiseInternal(cf.location, "try clause head escaped isClauseHead gate");
    }

    const n = try arena.create(Node);
    n.* = .{ .try_node = .{
        .body = body_node,
        .catch_clauses = try arena.dupe(node_mod.TryNode.CatchClause, clauses.items),
        .finally_body = finally_node,
        .loc = form.location,
    } };
    return n;
}

fn isClauseHead(f: Form) bool {
    if (f.data != .list) return false;
    const items = f.data.list;
    if (items.len == 0) return false;
    if (items[0].data != .symbol) return false;
    const head = items[0].data.symbol;
    if (head.ns != null) return false;
    return std.mem.eql(u8, head.name, "catch") or std.mem.eql(u8, head.name, "finally");
}

fn analyzeCatchClause(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    clause: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!node_mod.TryNode.CatchClause {
    const items = clause.data.list;
    if (items.len < 4)
        return error_catalog.raise(.catch_form_incomplete, clause.location, .{});
    if (items[1].data != .symbol)
        return error_catalog.raise(.catch_class_not_symbol, items[1].location, .{});
    if (items[2].data != .symbol)
        return error_catalog.raise(.catch_binding_not_symbol, items[2].location, .{});
    const class_sym = items[1].data.symbol;
    const bind_sym = items[2].data.symbol;
    if (bind_sym.ns != null)
        return error_catalog.raise(.catch_binding_namespace_qualified, items[2].location, .{});

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);
    const slot = try child_scope.declare(arena, bind_sym.name);

    const body_forms = items[3..];
    const body_node = if (body_forms.len == 1)
        try analyzer_mod.analyze(arena, rt, env, &child_scope, body_forms[0], macro_table)
    else blk: {
        var sub = try arena.alloc(Node, body_forms.len);
        for (body_forms, 0..) |f, i| {
            const n_b = try analyzer_mod.analyze(arena, rt, env, &child_scope, f, macro_table);
            sub[i] = n_b.*;
        }
        const dn = try arena.create(Node);
        dn.* = .{ .do_node = .{ .forms = sub, .loc = clause.location } };
        break :blk dn;
    };

    return .{
        .class_name = analyzer_mod.symFullName(class_sym),
        .binding_name = bind_sym.name,
        .binding_index = slot,
        .body = body_node,
        .loc = clause.location,
    };
}

fn analyzeFinallyClause(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    clause: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const items = clause.data.list;
    const body_forms = items[1..];
    if (body_forms.len == 0)
        return analyzer_mod.makeConstant(arena, .nil_val, clause);
    if (body_forms.len == 1)
        return analyzer_mod.analyze(arena, rt, env, scope, body_forms[0], macro_table);
    var sub = try arena.alloc(Node, body_forms.len);
    for (body_forms, 0..) |f, i| {
        const n_b = try analyzer_mod.analyze(arena, rt, env, scope, f, macro_table);
        sub[i] = n_b.*;
    }
    const dn = try arena.create(Node);
    dn.* = .{ .do_node = .{ .forms = sub, .loc = clause.location } };
    return dn;
}
