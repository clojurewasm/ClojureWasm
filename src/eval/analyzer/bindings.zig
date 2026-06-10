// SPDX-License-Identifier: EPL-2.0
//! Analyzer sub-module per D-030 split — binding-form analysers
//! (`fn*` / `let*` / `loop*`) plus the shared `analyzeBody` helper.
//!
//! Same cyclic-import pattern as `special_forms.zig`: this file
//! imports `analyzer.zig` for `AnalyzeError` / `Scope` / `analyze`,
//! and `analyzer.zig::analyzeSpecial` dispatches here for the three
//! arms.

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

pub fn analyzeFnStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 2)
        return error_catalog.raise(.fn_star_form_incomplete, form.location, .{});

    const slot_base: u16 = if (scope) |s| s.next_slot else 0;

    // Row 7.8 cycle 1 (ADR-0041): two body shapes — single-arity
    // `(fn* [params] body...)` (items[1] is vector) and multi-arity
    // `(fn* ([params] body...) ([params] body...) ...)` (items[1+] are
    // each a list). Normalise by collecting a slice of "(params_vec,
    // body_forms)" subforms; the same loop then handles both.
    var method_forms: std.ArrayList(MethodSubform) = .empty;
    defer method_forms.deinit(arena);

    if (items[1].data == .vector) {
        // Single-arity: the whole `items[1..]` is one method. An empty body
        // (`(fn* [])`) is valid (→ nil, clj parity); `analyzeBody` of an empty
        // slice yields `(do)` → nil.
        if (items.len < 2)
            return error_catalog.raise(.fn_star_form_incomplete, form.location, .{});
        try method_forms.append(arena, .{ .params_form = items[1], .body_forms = items[2..] });
    } else {
        // Multi-arity: each `items[i]` must be a list `(params body...)`. An
        // arity with an empty body (`([])`) is valid (→ nil, clj parity).
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            if (items[i].data != .list)
                return error_catalog.raise(.fn_star_params_not_vector, items[i].location, .{});
            const sub = items[i].data.list;
            if (sub.len < 1)
                return error_catalog.raise(.fn_star_form_incomplete, items[i].location, .{});
            if (sub[0].data != .vector)
                return error_catalog.raise(.fn_star_params_not_vector, sub[0].location, .{});
            try method_forms.append(arena, .{ .params_form = sub[0], .body_forms = sub[1..] });
        }
    }

    var methods: std.ArrayList(node_mod.FnMethod) = .empty;
    defer methods.deinit(arena);
    var variadic: ?node_mod.FnMethod = null;
    var seen_arities: std.AutoHashMapUnmanaged(u16, void) = .empty;
    defer seen_arities.deinit(arena);

    for (method_forms.items) |mf| {
        const m = try analyzeFnMethod(arena, rt, env, scope, mf, slot_base, form, macro_table);
        if (m.has_rest) {
            // JVM rule 1: at most one variadic per fn.
            if (variadic != null)
                return error_catalog.raise(.fn_star_variadic_duplicate, mf.params_form.location, .{});
            variadic = m;
        } else {
            // JVM rule 2: no two fixed methods share the same required arity.
            const gop = try seen_arities.getOrPut(arena, m.arity);
            if (gop.found_existing)
                return error_catalog.raise(.fn_star_arity_duplicate, mf.params_form.location, .{ .arity = m.arity });
            try methods.append(arena, m);
        }
    }

    // Sort fixed methods by arity ascending so callFunction's linear
    // scan + future binary-search optimisation see a deterministic
    // shape. Single-arity is a 1-element slice (no sort needed).
    std.mem.sort(node_mod.FnMethod, methods.items, {}, lessByArity);

    // Row 7.8 cycle 2 (ADR-0041): JVM rule 3 — no fixed method may
    // require more args than the variadic's required count, otherwise
    // call-site dispatch on `args.len == fixed.arity` would be
    // ambiguous (both fixed-arity and variadic accept it).
    if (variadic) |v| {
        for (methods.items) |m| {
            if (m.arity > v.arity) {
                return error_catalog.raise(.fn_star_fixed_exceeds_variadic, form.location, .{ .fixed = m.arity, .variadic = v.arity });
            }
        }
    }

    const n = try arena.create(Node);
    n.* = .{ .fn_node = .{
        .methods = try arena.dupe(node_mod.FnMethod, methods.items),
        .variadic = variadic,
        .slot_base = slot_base,
        // ADR-0119: every fn carries a name on the value. Default = a gensym
        // `fn__<id>` (clj parity for anonymous fns); a named context
        // (`defn` / `letfn*`) overrides this via a post-analyze patch.
        // `defining_ns` is display-only (the analyze-time current ns).
        .name = try rt.gensymFn(arena),
        .defining_ns = if (env.current_ns) |cns| cns.name else null,
        .loc = form.location,
    } };
    return n;
}

const MethodSubform = struct {
    params_form: Form,
    body_forms: []const Form,
};

fn lessByArity(_: void, a: node_mod.FnMethod, b: node_mod.FnMethod) bool {
    return a.arity < b.arity;
}

/// Parse one `(params body...)` subform into a `FnMethod`. Each method
/// runs body analysis in its own `child_scope` so `recur` inside
/// arity-N body re-enters arity-N body (JVM parity per ADR-0041 R1).
fn analyzeFnMethod(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    mf: MethodSubform,
    slot_base: u16,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!node_mod.FnMethod {
    const params_form = mf.params_form.data.vector;
    var has_rest = false;
    var arity: u16 = 0;
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(arena);

    var i: usize = 0;
    while (i < params_form.len) : (i += 1) {
        if (params_form[i].data != .symbol)
            return error_catalog.raise(.fn_star_param_not_symbol, params_form[i].location, .{});
        const ps = params_form[i].data.symbol;
        if (ps.ns != null)
            return error_catalog.raise(.fn_star_param_namespace_qualified, params_form[i].location, .{});
        if (std.mem.eql(u8, ps.name, "&")) {
            if (i + 1 >= params_form.len)
                return error_catalog.raise(.fn_star_rest_missing, params_form[i].location, .{});
            if (params_form[i + 1].data != .symbol)
                return error_catalog.raise(.fn_star_rest_not_symbol, params_form[i + 1].location, .{});
            try param_names.append(arena, params_form[i + 1].data.symbol.name);
            has_rest = true;
            break;
        }
        try param_names.append(arena, ps.name);
        arity += 1;
    }

    // A variadic fn's `recur` rebinds the rest param too, so the recur
    // target accepts `arity + 1` args (the trailing one is the rest seq) —
    // matches JVM `(fn [a & r] (recur x ys))` (D-090).
    const recur_arity: u16 = arity + @intFromBool(has_rest);
    var child_scope = if (scope) |s|
        Scope.childWithRecur(s, .{ .arity = recur_arity, .slot_base = slot_base, .kind = .fn_kw })
    else
        Scope{ .recur_target = .{ .arity = recur_arity, .slot_base = 0, .kind = .fn_kw } };
    defer child_scope.deinit(arena);
    // O-005: this method gets its OWN frame high-water counter (a nested
    // fn is a separate call frame, so its body slots must not inflate the
    // enclosing fn's frame_size). `slot_base` is the closure-capture
    // region, always part of the frame; declares + nested let/loop bump it.
    var frame_high_water: u16 = slot_base;
    child_scope.frame_high_water = &frame_high_water;
    for (param_names.items) |name| {
        _ = try child_scope.declare(arena, name);
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, mf.body_forms, form, macro_table);
    return .{
        .arity = arity,
        .has_rest = has_rest,
        .params = try arena.dupe([]const u8, param_names.items),
        .body = body_node,
        .frame_size = frame_high_water,
    };
}

/// Fold multiple body forms into a `do_node`; a single body form is
/// returned as-is. Used by `fn*` / `let*` / `loop*`.
pub fn analyzeBody(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: *const Scope,
    body_forms: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (body_forms.len == 1) {
        return analyzer_mod.analyze(arena, rt, env, scope, body_forms[0], macro_table);
    }
    var sub = try arena.alloc(Node, body_forms.len);
    for (body_forms, 0..) |f, i| {
        const n = try analyzer_mod.analyze(arena, rt, env, scope, f, macro_table);
        sub[i] = n.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = sub, .loc = form.location } };
    return n;
}

pub fn analyzeLetStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3)
        return error_catalog.raise(.bindings_form_incomplete, form.location, .{ .form = "let*" });
    if (items[1].data != .vector)
        return error_catalog.raise(.bindings_not_vector, items[1].location, .{ .form = "let*" });
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_catalog.raise(.bindings_arity_odd, items[1].location, .{ .form = "let*" });

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, binding_forms.len / 2);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_catalog.raise(.binding_name_not_symbol, binding_forms[fi].location, .{ .form = "let*" });
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null)
            return error_catalog.raise(.binding_name_namespace_qualified, binding_forms[fi].location, .{ .form = "let*" });
        const value_node = try analyzer_mod.analyze(arena, rt, env, &child_scope, binding_forms[fi + 1], macro_table);
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{
            .name = name_sym.name,
            .index = slot,
            .value_expr = value_node,
        };
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .let_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

/// `(letfn* [n1 e1 n2 e2 ...] body)`. Unlike `let*`, ALL binding names are
/// declared into the child scope BEFORE any init-expr is analysed, so each
/// `e_i` (a `fn*`) can resolve every sibling name — mutual recursion. The
/// slot layout is identical to `let*`; only the declare-before-analyse
/// ordering differs. The backend (`evalLetfn` / `op_letfn_patch`) wires the
/// captured-by-value closures together after allocation.
pub fn analyzeLetfnStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3)
        return error_catalog.raise(.bindings_form_incomplete, form.location, .{ .form = "letfn*" });
    if (items[1].data != .vector)
        return error_catalog.raise(.bindings_not_vector, items[1].location, .{ .form = "letfn*" });
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_catalog.raise(.bindings_arity_odd, items[1].location, .{ .form = "letfn*" });

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, binding_forms.len / 2);

    // Phase 1: declare every name first so each init sees all siblings.
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_catalog.raise(.binding_name_not_symbol, binding_forms[fi].location, .{ .form = "letfn*" });
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null)
            return error_catalog.raise(.binding_name_namespace_qualified, binding_forms[fi].location, .{ .form = "letfn*" });
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{ .name = name_sym.name, .index = slot, .value_expr = undefined };
        bi += 1;
    }

    // Phase 2: analyse each init against the fully-populated scope.
    bi = 0;
    fi = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        const init_node = try analyzer_mod.analyze(arena, rt, env, &child_scope, binding_forms[fi + 1], macro_table);
        // ADR-0119: name a letfn*-bound fn after its binding name (overrides
        // the gensym the anonymous `fn*` got; same seam as analyzeDef). The
        // analyzer-arena Node is mutable; `const` is only analyze()'s convention.
        if (std.meta.activeTag(init_node.*) == .fn_node)
            @constCast(init_node).fn_node.name = bindings[bi].name;
        bindings[bi].value_expr = init_node;
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .letfn_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

/// `(binding [*v1* e1 *v2* e2 ...] body)`. Unlike `let*`, the
/// even-position names resolve to **existing dynamic Vars** (no lexical
/// slots) and the init-exprs + body analyse in the OUTER `scope` (JVM
/// parallel-eval semantics). The dynamic-ness of each target is checked
/// at eval/push time (JVM-faithful site), not here — a Var's
/// `flags.dynamic` could in principle change between analysis and eval.
pub fn analyzeBinding(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // `(binding [..])` with no body is valid (→ nil, clj parity) — e.g. a
    // `(testing "label")` with no body expands to it. Only the binding vector
    // is required.
    if (items.len < 2)
        return error_catalog.raise(.bindings_form_incomplete, form.location, .{ .form = "binding" });
    if (items[1].data != .vector)
        return error_catalog.raise(.bindings_not_vector, items[1].location, .{ .form = "binding" });
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_catalog.raise(.bindings_arity_odd, items[1].location, .{ .form = "binding" });

    var pairs = try arena.alloc(node_mod.BindingNode.Pair, binding_forms.len / 2);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_catalog.raise(.binding_name_not_symbol, binding_forms[fi].location, .{ .form = "binding" });
        const name_sym = binding_forms[fi].data.symbol;
        // Resolve the target to its existing Var (qualified → alias then
        // findNs, else current ns), mirroring analyzeSymbol's global path.
        // `binding` rebinds an existing Var; it never declares a slot.
        const target_ns = if (name_sym.ns) |ns_name|
            (if (env.current_ns) |here| here.aliases.get(ns_name) else null) orelse
                env.findNs(ns_name) orelse
                return error_catalog.raise(.namespace_unknown, binding_forms[fi].location, .{ .ns = ns_name })
        else
            env.current_ns orelse
                return error_catalog.raise(.current_namespace_missing, binding_forms[fi].location, .{ .sym = name_sym.name });
        const var_ptr = target_ns.resolve(name_sym.name) orelse
            return error_catalog.raise(.symbol_unresolved, binding_forms[fi].location, .{ .sym = analyzer_mod.symFullName(name_sym) });
        // Init-expr analyses in the OUTER scope (parallel-eval): it sees
        // the surrounding bindings, NOT the other binding pairs.
        const value_node = try analyzer_mod.analyze(arena, rt, env, scope, binding_forms[fi + 1], macro_table);
        pairs[bi] = .{ .var_ptr = var_ptr, .value_expr = value_node };
        bi += 1;
    }

    // Body analyses in the OUTER scope too — `binding` introduces no
    // lexical slots. At top level (`scope == null`) an empty scope
    // stands in (there are no enclosing locals to resolve against).
    var empty_scope = Scope{};
    defer empty_scope.deinit(arena);
    const body_scope: *const Scope = scope orelse &empty_scope;
    const body_node = try analyzeBody(arena, rt, env, body_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .binding_node = .{
        .pairs = pairs,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

pub fn analyzeLoopStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3)
        return error_catalog.raise(.bindings_form_incomplete, form.location, .{ .form = "loop*" });
    if (items[1].data != .vector)
        return error_catalog.raise(.bindings_not_vector, items[1].location, .{ .form = "loop*" });
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_catalog.raise(.bindings_arity_odd, items[1].location, .{ .form = "loop*" });
    const pair_count = binding_forms.len / 2;
    if (pair_count > std.math.maxInt(u16))
        return error_catalog.raise(.arity_too_large, items[1].location, .{
            .form = "loop*",
            .got = pair_count,
        });

    const arity_u: u16 = @intCast(pair_count);
    const slot_base: u16 = if (scope) |s| s.next_slot else 0;

    var child_scope = if (scope) |s|
        Scope.childWithRecur(s, .{ .arity = arity_u, .slot_base = slot_base, .kind = .loop_kw })
    else
        Scope{ .recur_target = .{ .arity = arity_u, .slot_base = 0, .kind = .loop_kw } };
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, arity_u);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_catalog.raise(.binding_name_not_symbol, binding_forms[fi].location, .{ .form = "loop*" });
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null)
            return error_catalog.raise(.binding_name_namespace_qualified, binding_forms[fi].location, .{ .form = "loop*" });
        // Sequential binding scope (clj parity, mirrors let*): each init sees
        // the earlier loop bindings, so analyse against `child_scope` (where
        // prior slots are declared), not the outer `scope`. The slot for THIS
        // binding is declared after, so an init cannot see its own name.
        const value_node = try analyzer_mod.analyze(arena, rt, env, &child_scope, binding_forms[fi + 1], macro_table);
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{
            .name = name_sym.name,
            .index = slot,
            .value_expr = value_node,
        };
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .loop_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}
