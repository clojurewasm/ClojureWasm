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
const form_mod = @import("../form.zig");
const Form = form_mod.Form;
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
    // ADR-0038: pre-register the Var at analyze time so recursive
    // defns + forward references inside `(do ...)` resolve. Var lands
    // with placeholder nil; `evalDef` (tree_walk.zig:466) and the VM
    // op_def arm re-intern with the actual value at runtime. env.intern
    // is idempotent (env.zig:353-357 updates root in place).
    const ns = env.current_ns orelse
        return error_catalog.raiseInternal(form.location, "def: no current namespace");
    _ = try env.intern(ns, name_sym.name, .nil_val, null);
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

/// `(in-ns 'foo.bar)` or `(in-ns foo.bar)` — both shapes accepted.
/// Per ADR-0032 the analyzer extracts the symbol's full namespace
/// name (combining `ns/name` parts when present) and emits an
/// `InNsNode` for the tree-walk evaluator to act on. Quoted-symbol
/// form is unwrapped here because cw v1 has no symbol heap Value
/// yet (F-004 Group A slot 1 reserved).
/// `(require 'ns.name)` or `(require '[ns.name :as a :refer [x y]])`.
/// Phase 6.16.b-4 sub-cycle c.5 lifts vector libspecs with `:as` +
/// `:refer`. ADR-0035 D2. Quoted-symbol / quoted-vector wrapper is
/// unwrapped here because cw v1 has no symbol / vector heap Value
/// usable as a runtime arg yet (F-004 reserved slots). Returns a
/// `RequireNode` carrying ns_name + optional alias + refers slice.
pub fn analyzeRequire(
    arena: std.mem.Allocator,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = "require with multiple libspecs (Phase 6.16.b-4 c.6+)" });

    const arg = items[1];
    // Unwrap `'foo` -> `foo` (quoted form) when present.
    const inner_form: Form = switch (arg.data) {
        .list => |inner| blk: {
            if (inner.len == 2 and inner[0].data == .symbol and
                inner[0].data.symbol.ns == null and
                std.mem.eql(u8, inner[0].data.symbol.name, "quote"))
            {
                break :blk inner[1];
            }
            return error_catalog.raise(.feature_not_supported, arg.location, .{ .name = "require with non-quoted libspec (Phase 6.16.b-4 c.6+)" });
        },
        .symbol => arg,
        .vector => arg,
        else => return error_catalog.raise(.feature_not_supported, arg.location, .{ .name = "require with non-symbol/vector libspec (Phase 6.16.b-4 c.6+)" }),
    };

    // Two shapes: bare symbol `foo` or vector `[foo :as a :refer [x y]]`.
    var ns_sym: form_mod.SymbolRef = undefined;
    var alias_name: ?[]const u8 = null;
    var refer_names: []const []const u8 = &.{};

    switch (inner_form.data) {
        .symbol => |s| ns_sym = s,
        .vector => |vec| {
            if (vec.len == 0 or vec[0].data != .symbol)
                return error_catalog.raise(.feature_not_supported, inner_form.location, .{ .name = "require libspec must begin with a symbol" });
            ns_sym = vec[0].data.symbol;

            // Walk the rest pairwise: keyword + value.
            var i: usize = 1;
            while (i < vec.len) {
                if (vec[i].data != .keyword)
                    return error_catalog.raise(.feature_not_supported, vec[i].location, .{ .name = "require libspec options must be keyword/value pairs" });
                const kw = vec[i].data.keyword;
                if (kw.ns != null)
                    return error_catalog.raise(.feature_not_supported, vec[i].location, .{ .name = "require libspec keyword must be unqualified" });
                if (i + 1 >= vec.len)
                    return error_catalog.raise(.feature_not_supported, vec[i].location, .{ .name = "require libspec keyword without value" });
                const val = vec[i + 1];
                if (std.mem.eql(u8, kw.name, "as")) {
                    if (val.data != .symbol or val.data.symbol.ns != null)
                        return error_catalog.raise(.feature_not_supported, val.location, .{ .name = "require :as value must be an unqualified symbol" });
                    alias_name = try arena.dupe(u8, val.data.symbol.name);
                } else if (std.mem.eql(u8, kw.name, "refer")) {
                    if (val.data != .vector)
                        return error_catalog.raise(.feature_not_supported, val.location, .{ .name = "require :refer value must be a vector of symbols (Phase 6.16.b-4 c.6+: :all)" });
                    const refs = val.data.vector;
                    const buf = try arena.alloc([]const u8, refs.len);
                    var k: usize = 0;
                    while (k < refs.len) : (k += 1) {
                        if (refs[k].data != .symbol or refs[k].data.symbol.ns != null)
                            return error_catalog.raise(.feature_not_supported, refs[k].location, .{ .name = "require :refer entries must be unqualified symbols" });
                        buf[k] = try arena.dupe(u8, refs[k].data.symbol.name);
                    }
                    refer_names = buf;
                } else {
                    return error_catalog.raise(.feature_not_supported, vec[i].location, .{ .name = "require libspec keyword (only :as and :refer supported at c.5)" });
                }
                i += 2;
            }
        },
        else => return error_catalog.raise(.feature_not_supported, inner_form.location, .{ .name = "require libspec must be symbol or vector" }),
    }

    const ns_name: []const u8 = if (ns_sym.ns) |prefix|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, ns_sym.name })
    else
        try arena.dupe(u8, ns_sym.name);

    const n = try arena.create(Node);
    n.* = .{ .require_node = .{
        .ns_name = ns_name,
        .alias = alias_name,
        .refers = refer_names,
        .loc = form.location,
    } };
    return n;
}

/// `(ns foo)` or `(ns foo (:refer-clojure))`. ADR-0035 D1.
/// Phase 6.16.b-4 sub-cycle c.7 supports the bare ns name + an
/// optional `(:refer-clojure)` directive only; other directives
/// (`:require` / `:use` / `:import` / `:gen-class`) raise transient
/// `feature_not_supported`. Bare ns symbol is required (not quoted).
pub fn analyzeNs(
    arena: std.mem.Allocator,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len < 2)
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = "ns requires a name" });

    const name_form = items[1];
    if (name_form.data != .symbol)
        return error_catalog.raise(.feature_not_supported, name_form.location, .{ .name = "ns name must be a bare symbol" });
    const sym = name_form.data.symbol;
    const ns_name: []const u8 = if (sym.ns) |prefix|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, sym.name })
    else
        try arena.dupe(u8, sym.name);

    var refer_clojure: bool = true;

    // Walk references (items[2..]). Each must be a list starting with
    // a keyword directive.
    var i: usize = 2;
    while (i < items.len) : (i += 1) {
        const directive = items[i];
        if (directive.data != .list)
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive must be a list" });
        const inner = directive.data.list;
        if (inner.len == 0 or inner[0].data != .keyword)
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive must begin with a keyword" });
        const kw = inner[0].data.keyword;
        if (kw.ns != null)
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive keyword must be unqualified" });
        if (std.mem.eql(u8, kw.name, "refer-clojure")) {
            refer_clojure = true;
            // :exclude / :only filters land in a later cycle.
            if (inner.len > 1)
                return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns :refer-clojure filters (:exclude / :only) (Phase 6.16.b-4 c.8+)" });
        } else if (std.mem.eql(u8, kw.name, "require")) {
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns :require directive (Phase 6.16.b-4 c.8+: use separate (require ...) calls for now)" });
        } else {
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive (only :refer-clojure supported at c.7)" });
        }
    }

    const n = try arena.create(Node);
    n.* = .{ .ns_node = .{ .name = ns_name, .refer_clojure = refer_clojure, .loc = form.location } };
    return n;
}

pub fn analyzeInNs(
    arena: std.mem.Allocator,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_catalog.raise(.in_ns_arity_invalid, form.location, .{ .got = items.len - 1 });

    const arg = items[1];
    const sym = sym: switch (arg.data) {
        .symbol => |s| break :sym s,
        .list => |inner| {
            if (inner.len == 2 and inner[0].data == .symbol and
                inner[0].data.symbol.ns == null and
                std.mem.eql(u8, inner[0].data.symbol.name, "quote") and
                inner[1].data == .symbol)
            {
                break :sym inner[1].data.symbol;
            }
            return error_catalog.raise(.in_ns_arg_not_symbol, arg.location, .{ .actual = arg.typeName() });
        },
        else => return error_catalog.raise(.in_ns_arg_not_symbol, arg.location, .{ .actual = arg.typeName() }),
    };

    const ns_name: []const u8 = if (sym.ns) |prefix|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, sym.name })
    else
        try arena.dupe(u8, sym.name);

    const n = try arena.create(Node);
    n.* = .{ .in_ns_node = .{ .ns_name = ns_name, .loc = form.location } };
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
