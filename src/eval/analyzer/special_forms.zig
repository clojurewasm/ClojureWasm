// SPDX-License-Identifier: EPL-2.0
//! Analyzer sub-module per D-030 split — special-form analysers.
//!
//! Owns the form-shape validators that produce `DefNode` / `IfNode` /
//! `DoNode` / `QuoteNode` / `ThrowNode` / `DeftypeNode` /
//! `CtorCallNode` / `FieldAccessNode`. The orchestrating
//! `analyzeSpecial` dispatcher and the surrounding `analyzeList`
//! helper that detects `Name.` / `.field` symbol shapes stay in
//! `analyzer/analyzer.zig`; this file only contains the per-form
//! body each dispatcher arm delegates to.
//!
//! Cyclic-import contract: this file `@import("analyzer.zig")` to
//! pick up `AnalyzeError` and the recursive `analyze` entry point;
//! `analyzer.zig` imports this file via `const special_forms =
//! @import("special_forms.zig")` at the bottom of its top section.
//! Zig resolves the cycle at build time; no forward declarations
//! are needed.

const std = @import("std");
const Form = @import("../form.zig").Form;
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_catalog = @import("../../runtime/error/catalog.zig");
const macro_dispatch = @import("../macro_dispatch.zig");
const analyzer_mod = @import("analyzer.zig");
const AnalyzeError = analyzer_mod.AnalyzeError;
const Scope = analyzer_mod.Scope;

pub fn analyzeDeftype(arena: std.mem.Allocator, items: []const Form, form: Form) AnalyzeError!*const Node {
    if (items.len < 3) {
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = "deftype with no field list" });
    }
    if (items[1].data != .symbol) {
        return error_catalog.raise(.def_name_not_symbol, items[1].location, .{});
    }
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null) {
        return error_catalog.raise(.def_name_namespace_qualified, items[1].location, .{ .ns = name_sym.ns.?, .name = name_sym.name });
    }
    if (items[2].data != .vector) {
        return error_catalog.raise(.bindings_not_vector, items[2].location, .{ .form = "deftype" });
    }
    const field_forms = items[2].data.vector;
    const field_names = try arena.alloc([]const u8, field_forms.len);
    for (field_forms, 0..) |fld, i| {
        if (fld.data != .symbol) {
            return error_catalog.raise(.binding_name_not_symbol, fld.location, .{ .form = "deftype" });
        }
        if (fld.data.symbol.ns != null) {
            return error_catalog.raise(.binding_name_namespace_qualified, fld.location, .{ .form = "deftype" });
        }
        field_names[i] = fld.data.symbol.name;
    }
    const n = try arena.create(Node);
    n.* = .{ .deftype_node = .{
        .name = name_sym.name,
        .fields = field_names,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeCtorCall(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    type_name: []const u8,
    arg_forms: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const args = try arena.alloc(Node, arg_forms.len);
    for (arg_forms, 0..) |af, i| {
        const sub = try analyzer_mod.analyze(arena, rt, env, scope, af, macro_table);
        args[i] = sub.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .ctor_call_node = .{
        .type_name = type_name,
        .args = args,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeFieldAccess(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    field_name: []const u8,
    target_form: Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const target = try analyzer_mod.analyze(arena, rt, env, scope, target_form, macro_table);
    const n = try arena.create(Node);
    n.* = .{ .field_access_node = .{
        .field_name = field_name,
        .target = target,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeDef(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 2 or items.len > 3)
        return error_catalog.raise(.def_arity_invalid, form.location, .{ .got = items.len - 1 });
    if (items[1].data != .symbol)
        return error_catalog.raise(.def_name_not_symbol, items[1].location, .{});
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null)
        return error_catalog.raise(.def_name_namespace_qualified, items[1].location, .{ .ns = name_sym.ns.?, .name = name_sym.name });
    const value_node = if (items.len == 3)
        try analyzer_mod.analyze(arena, rt, env, scope, items[2], macro_table)
    else
        try analyzer_mod.makeConstant(arena, .nil_val, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .def_node = .{
        .name = name_sym.name,
        .value_expr = value_node,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeIf(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3 or items.len > 4)
        return error_catalog.raise(.if_arity_invalid, form.location, .{ .got = items.len - 1 });
    const cond = try analyzer_mod.analyze(arena, rt, env, scope, items[1], macro_table);
    const then_b = try analyzer_mod.analyze(arena, rt, env, scope, items[2], macro_table);
    const else_b: ?*const Node = if (items.len == 4)
        try analyzer_mod.analyze(arena, rt, env, scope, items[3], macro_table)
    else
        null;
    const n = try arena.create(Node);
    n.* = .{ .if_node = .{
        .cond = cond,
        .then_branch = then_b,
        .else_branch = else_b,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeDo(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    var forms = try arena.alloc(Node, items.len - 1);
    for (items[1..], 0..) |f, i| {
        const sub = try analyzer_mod.analyze(arena, rt, env, scope, f, macro_table);
        forms[i] = sub.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = forms, .loc = form.location } };
    return n;
}

pub fn analyzeQuote(
    arena: std.mem.Allocator,
    rt: *Runtime,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_catalog.raise(.quote_arity_invalid, form.location, .{ .got = items.len - 1 });
    const v = try analyzer_mod.formToValue(rt, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .quote_node = .{ .quoted = v, .loc = form.location } };
    return n;
}

pub fn analyzeThrow(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_catalog.raise(.throw_arity_invalid, form.location, .{ .got = items.len - 1 });
    const expr = try analyzer_mod.analyze(arena, rt, env, scope, items[1], macro_table);
    const n = try arena.create(Node);
    n.* = .{ .throw_node = .{ .expr = expr, .loc = form.location } };
    return n;
}
