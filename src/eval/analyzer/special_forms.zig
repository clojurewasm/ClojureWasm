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
const vector_mod = @import("../../runtime/collection/vector.zig");
const analyzer_mod = @import("analyzer.zig");
const bindings = @import("bindings.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const keyword_mod = @import("../../runtime/keyword.zig");

/// True when `meta` (a Clojure map Value, or null) maps `key` to a truthy value
/// — used to read `^:dynamic` / `^:private` off a `def` target's metadata.
fn metaFlag(rt: *Runtime, meta: ?Value, key: []const u8) bool {
    const m = meta orelse return false;
    const kw = keyword_mod.intern(rt, null, key) catch return false;
    const v = map_collection.get(m, kw) catch return false;
    return !v.isNil() and v != Value.false_val;
}
const AnalyzeError = analyzer_mod.AnalyzeError;
const Scope = analyzer_mod.Scope;
const type_descriptor_mod = @import("../../runtime/type_descriptor.zig");
const TypeDescriptor = type_descriptor_mod.TypeDescriptor;

/// Resolve a head namespace string from `(Class/method)` or `(Class. ...)`
/// to a `*const TypeDescriptor` in `rt.types`. ADR-0029 D5 keys
/// descriptors by their cljw-prefixed FQCN (e.g. `"cljw.java.util.UUID"`),
/// but user source writes the JVM form (e.g. `"java.util.UUID"`). This
/// helper bridges by trying, in order:
///   1. Literal `rt.types.get(head)` (e.g. `"java.util.UUID"`; also a
///      user `(deftype Math …)` shadowing the auto-import — local wins).
///   2. `rt.types.get("cljw." ++ head)` for the Java prefix translation
///      (`"java.util.UUID"` → `"cljw.java.util.UUID"`).
///   3. `rt.types.get("cljw.java.lang." ++ head)` for the `java.lang.*`
///      auto-import (ADR-0050 § R3): a bare class name like `Math` /
///      `System` resolves the way JVM Clojure default-imports
///      `java.lang.*` into every ns. Gated to dot-free heads so a
///      qualified head (already handled by 1/2) is not re-probed.
/// Returns `null` if none hit. `env` is read for the current ns's
/// per-ns `(:import …)` simple-name map (D-235), checked before the
/// always-on java.lang auto-import.
pub fn resolveJavaSurface(rt: *Runtime, env: *Env, head: []const u8) ?*const TypeDescriptor {
    if (rt.types.get(head)) |td| return td;
    var buf: [256]u8 = undefined;
    const prefixed = std.fmt.bufPrint(&buf, "cljw.{s}", .{head}) catch return null;
    if (rt.types.get(prefixed)) |td| return td;
    if (std.mem.findScalar(u8, head, '.') == null) {
        // A `(:import …)` simple name resolves to its FQCN first (D-235),
        // before the always-on java.lang auto-import.
        if (env.current_ns) |ns| {
            if (ns.imports.get(head)) |fqcn| {
                if (rt.types.get(fqcn)) |td| return td;
                var ibuf: [256]u8 = undefined;
                const iprefixed = std.fmt.bufPrint(&ibuf, "cljw.{s}", .{fqcn}) catch return null;
                if (rt.types.get(iprefixed)) |td| return td;
            }
        }
        var buf2: [256]u8 = undefined;
        const auto = std.fmt.bufPrint(&buf2, "cljw.java.lang.{s}", .{head}) catch return null;
        if (rt.types.get(auto)) |td| return td;
    }
    return null;
}

/// Construct an instance of `type_name` from already-evaluated `args`.
/// Shared by both backends (TreeWalk `evalConstructorCall` + VM
/// `op_ctor_call`) so the resolution + dispatch is identical — the
/// dual-backend parity contract (ADR-0036). Resolves via
/// `resolveJavaSurface` (deftype/record + java-surface), then:
///   - `field_layout` present (deftype/record) → arity-check + allocInstance;
///   - else a `<init>` method entry (java surface, e.g. `java.io.File.`) →
///     call it through the runtime vtable;
///   - else the descriptor exists but takes no ctor → arity / unresolved
///     diagnostic (zero expected args).
/// Mirrors the prior TreeWalk-only body verbatim; the VM previously used a
/// deftype-only `rt.types.get` + allocInstance path that missed java-surface
/// ctors (D-196 blocker 3).
pub fn constructInstance(
    rt: *Runtime,
    env: *Env,
    type_name: []const u8,
    args: []const Value,
    loc: error_catalog.SourceLocation,
) anyerror!Value {
    // D-284: cljw has no clojure.lang.MapEntry type — a map entry IS a 2-vector
    // `[k v]` (core.clj). `(MapEntry. k v)` (or the qualified form) constructs that
    // 2-vector, so collection libs that build entries explicitly (priority-map,
    // ordered, …) work. `key`/`val`/`nth` already operate on a 2-vector.
    if (std.mem.eql(u8, type_name, "MapEntry") or std.mem.eql(u8, type_name, "clojure.lang.MapEntry")) {
        if (args.len != 2)
            return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "MapEntry.", .expected = 2 });
        return vector_mod.fromSlice(rt, args);
    }
    const td = resolveJavaSurface(rt, env, type_name) orelse
        return error_catalog.raise(.symbol_unresolved, loc, .{ .sym = type_name });
    if (td.field_layout) |fl| {
        if (args.len != fl.len)
            return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = type_name, .expected = fl.len });
        return type_descriptor_mod.allocInstance(rt, td, args);
    }
    if (td.lookupMethod(null, "<init>")) |me| {
        if (me.method_val.tag() == .nil)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "constructor declared but not implemented" });
        const vt = rt.vtable orelse return error.NoVTable;
        return vt.callFn(rt, env, me.method_val, args, loc);
    }
    if (args.len != 0)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = type_name, .expected = 0 });
    return error_catalog.raise(.symbol_unresolved, loc, .{ .sym = type_name });
}

/// `(Name. args...)` constructor analyzer arm. Per ADR-0050, builds an
/// `InteropCallNode { .kind = .constructor }`. The type name is kept as
/// a string for eval-time `resolveJavaSurface` lookup — this allows
/// `(deftype Foo ...)` forms to forward-declare types referenced by a
/// later `(Foo. ...)` call within the same `do` block.
/// `(. recv member)` / `(. recv member args…)` / `(. recv (member args…))` —
/// the canonical interop special form that `(.member recv …)` / `(Class/m …)`
/// sugar over. Lowers to the existing `InteropCallNode`: a static call when
/// `recv` is a symbol naming a resolvable class with that method, else an
/// instance member. The `(member args…)` list shape and the flat
/// `member args…` shape are equivalent (clj parity). No new Node / backend
/// plumbing — both backends already handle InteropCallNode.
pub fn analyzeDot(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3)
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = ". form needs a receiver and a member" });
    const recv = items[1];
    const member_form = items[2];
    // Normalise the member name + args from either shape.
    var member_name: []const u8 = undefined;
    var arg_forms: []const Form = undefined;
    switch (member_form.data) {
        .symbol => |m| {
            if (m.ns != null)
                return error_catalog.raise(.feature_not_supported, member_form.location, .{ .name = ". member must be an unqualified symbol" });
            member_name = m.name;
            arg_forms = items[3..];
        },
        .list => |inner| {
            if (items.len != 3 or inner.len == 0 or inner[0].data != .symbol or inner[0].data.symbol.ns != null)
                return error_catalog.raise(.feature_not_supported, member_form.location, .{ .name = ". (member args) form must be (member …) with an unqualified head" });
            member_name = inner[0].data.symbol.name;
            arg_forms = inner[1..];
        },
        else => return error_catalog.raise(.feature_not_supported, member_form.location, .{ .name = ". member must be a symbol or (member …) list" }),
    }
    // A `.-field` style leading-dash member reads a field only.
    const field_only = member_name.len >= 1 and member_name[0] == '-';
    const resolved_member = if (field_only) member_name[1..] else member_name;
    // Static when the receiver is a symbol naming a class with this method.
    if (recv.data == .symbol and recv.data.symbol.ns == null) {
        if (resolveJavaSurface(rt, env, recv.data.symbol.name)) |td| {
            if (td.lookupMethod(null, resolved_member) != null) {
                return analyzeStaticMethodCall(arena, rt, env, scope, td, resolved_member, arg_forms, form, macro_table);
            }
        }
    }
    return analyzeInstanceMember(arena, rt, env, scope, resolved_member, recv, arg_forms, form, macro_table, field_only);
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
    n.* = .{ .interop_call_node = .{
        .kind = .constructor,
        .type_name = type_name,
        .args = args,
        .loc = form.location,
    } };
    return n;
}

/// `(new Classname args...)` — the constructor special form, equivalent to the
/// `(Classname. args...)` sugar. Lowers to the same `analyzeCtorCall`
/// (constructor InteropCallNode). The class must be a bare symbol.
pub fn analyzeNew(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 2 or items[1].data != .symbol)
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = "new (requires a class symbol: (new Classname args…))" });
    const cls = items[1].data.symbol;
    const type_name: []const u8 = if (cls.ns) |prefix|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, cls.name })
    else
        cls.name;
    return analyzeCtorCall(arena, rt, env, scope, type_name, items[2..], form, macro_table);
}

/// `(.member recv args...)` / `(.-field recv)` instance member analyzer arm
/// (ADR-0050 am1). Builds an `InteropCallNode { .kind = .instance_member }`,
/// consolidating the former `.instance_field` (arity 1) and
/// `.instance_method` (arity ≥ 2) arms into one. Member-vs-field is decided
/// at eval from the receiver's descriptor shape (field-first, keyed on
/// `field_layout` presence), so the analyzer no longer branches on arity.
/// `field_only` is set by the `.-name` reader form and restricts eval-time
/// resolution to a field read (never a method call).
pub fn analyzeInstanceMember(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    member_name: []const u8,
    target_form: Form,
    arg_forms: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
    field_only: bool,
) AnalyzeError!*const Node {
    const target = try analyzer_mod.analyze(arena, rt, env, scope, target_form, macro_table);
    const args = try arena.alloc(Node, arg_forms.len);
    for (arg_forms, 0..) |af, i| {
        const sub = try analyzer_mod.analyze(arena, rt, env, scope, af, macro_table);
        args[i] = sub.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .interop_call_node = .{
        .kind = .instance_member,
        .target = target,
        .name = member_name,
        .args = args,
        .field_only = field_only,
        .loc = form.location,
    } };
    return n;
}

/// `(Class/method args...)` static-method analyzer arm (D-121 + ADR-0050).
/// The class is resolved at analyze time via `resolveJavaSurface`; the
/// descriptor pointer is process-lifetime (heap-copied by
/// `_host_api.installAll`), so the dispatch is one indirection + one
/// linear method_table scan at eval. Args are analysed recursively (no
/// receiver — static dispatch has no `this`).
pub fn analyzeStaticMethodCall(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    descriptor: *const TypeDescriptor,
    method_name: []const u8,
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
    n.* = .{ .interop_call_node = .{
        .kind = .static_method,
        .descriptor = descriptor,
        .name = method_name,
        .args = args,
        .loc = form.location,
    } };
    return n;
}

/// Row 14.6 (D-099): user-defined `(defmacro NAME [PARAMS] BODY...)`.
/// Lowers to a `DefNode { is_macro = true, value_expr = (fn* [PARAMS]
/// BODY...) }`. The Var's `flags.macro_` bit lands at eval-time when
/// `evalDef` / VM `op_def` (DEF_FLAG_MACRO) sees `DefNode.is_macro`.
/// Cf. JVM Clojure's `clojure.core/defmacro` (clojure/core.clj L446)
/// which expands to `(do (defn NAME [&form &env PARAMS] BODY...) (.
/// (var NAME) (setMacro)) (var NAME))`. cw v1 prepends the implicit
/// `&form` / `&env` params too (ADR-0086, via
/// `prependImplicitMacroParams`).
/// Prepend the implicit `&form &env` symbols to a `defmacro` arity's param
/// vector (ADR-0086). `params_vec.data` is `.vector`.
fn prependImplicitMacroParams(arena: std.mem.Allocator, params_vec: Form, loc: error_catalog.SourceLocation) AnalyzeError!Form {
    const orig = params_vec.data.vector;
    const out = try arena.alloc(Form, orig.len + 2);
    out[0] = macro_dispatch.makeSymbol("&form", loc);
    out[1] = macro_dispatch.makeSymbol("&env", loc);
    @memcpy(out[2..], orig);
    return Form{ .data = .{ .vector = out }, .location = params_vec.location };
}

/// Unwrap a `(quote X)` form to `X`; any other form passes through. clj
/// evaluates def-target metadata values at def time, and the idiomatic
/// non-self-evaluating value is a quoted datum (`'([k v])`, `'(a b)`); a
/// quote lifts to its datum, matching clj.
fn unwrapQuote(f: Form) Form {
    if (f.data == .list and f.data.list.len == 2) {
        const head = f.data.list[0];
        if (head.data == .symbol and head.data.symbol.ns == null and
            std.mem.eql(u8, head.data.symbol.name, "quote"))
            return f.data.list[1];
    }
    return f;
}

/// Apply quote-evaluation to a metadata map Form's VALUES before lifting it to
/// a Value (D-316). Keys (always literal keywords) are untouched. Arbitrary
/// computed metadata (`{:k (+ 1 2)}`) still needs def-time RUNTIME eval — the
/// narrow D-316 residual — and is left as-is rather than mis-claimed.
fn unquoteMetaValues(arena: std.mem.Allocator, map_form: Form) AnalyzeError!Form {
    if (map_form.data != .map) return map_form;
    const pairs = map_form.data.map;
    const out = try arena.alloc(Form, pairs.len);
    for (pairs, 0..) |p, i| out[i] = if (i % 2 == 1) unwrapQuote(p) else p;
    return .{ .data = .{ .map = out }, .location = map_form.location };
}

pub fn analyzeDefmacro(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3)
        return error_catalog.raise(.defmacro_arity_invalid, form.location, .{});
    if (items[1].data != .symbol)
        return error_catalog.raise(.defmacro_name_not_symbol, items[1].location, .{});
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null)
        return error_catalog.raise(.def_name_namespace_qualified, items[1].location, .{ .ns = name_sym.ns.?, .name = name_sym.name });

    // D-187: accept a leading docstring (string) + attr-map (map) after the
    // name, like `defn` (was a hard `defmacro_params_not_vector` error on a
    // valid `(defmacro m "doc" [x] …)`).
    var head: usize = 2;
    var doc_form: ?Form = null;
    var attr_form: ?Form = null;
    if (head < items.len and items[head].data == .string) {
        doc_form = items[head];
        head += 1;
    }
    if (head < items.len and items[head].data == .map) {
        attr_form = items[head];
        head += 1;
    }
    // Single-arity `[params] body…` (vector head) or multi-arity
    // `([a] …) ([a b] …)` (list heads), mirroring defn's two body shapes.
    if (head >= items.len or (items[head].data != .vector and items[head].data != .list))
        return error_catalog.raise(.defmacro_params_not_vector, form.location, .{});
    const multi_arity = items[head].data == .list;

    // Pre-register the macro Var with `flags.macro_ = true` so the
    // analyzer's `expandIfMacro` can see the macro flag before the
    // user-fn body actually evaluates. evalDef + VM op_def will
    // overwrite root + re-assert flags at runtime per the existing
    // analyzeDef pattern (ADR-0038).
    const ns = env.current_ns orelse
        return error_catalog.raiseInternal(form.location, "defmacro: no current namespace");
    // ADR-0038 amendment (D-184): declare-if-absent (no root reset).
    const placeholder_var = try env.internDeclare(ns, name_sym.name);
    placeholder_var.flags.macro_ = true;

    // D-187: lower docstring / attr-map / synthesized :arglists into
    // Var.meta (mirrors defn's D-183(d), so `(:doc (meta #'m))` works);
    // reader `^meta` on the name merges first. :arglists is always present.
    {
        var meta_items: std.ArrayList(Form) = .empty;
        if (items[1].meta) |mf| try meta_items.appendSlice(arena, mf.data.map);
        if (attr_form) |a| try meta_items.appendSlice(arena, a.data.map);
        if (doc_form) |d| {
            try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "doc" } }, .location = form.location });
            try meta_items.append(arena, d);
        }
        // :arglists is the list of param vectors: `([params])` for single
        // arity, `([a] [a b] …)` for multi-arity (each clause's vector).
        const arglists_inner = if (multi_arity) blk: {
            const clauses = items[head..];
            const av = try arena.alloc(Form, clauses.len);
            for (clauses, 0..) |c, j| {
                if (c.data != .list or c.data.list.len == 0 or c.data.list[0].data != .vector)
                    return error_catalog.raise(.defmacro_params_not_vector, c.location, .{});
                av[j] = c.data.list[0];
            }
            break :blk av;
        } else blk: {
            const av = try arena.alloc(Form, 1);
            av[0] = items[head];
            break :blk av;
        };
        try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "arglists" } }, .location = form.location });
        try meta_items.append(arena, .{ .data = .{ .list = arglists_inner }, .location = form.location });
        const meta_map: Form = .{ .data = .{ .map = try arena.dupe(Form, meta_items.items) }, .location = form.location };
        placeholder_var.meta = try analyzer_mod.formToValue(rt, env, try unquoteMetaValues(arena, meta_map));
    }

    // Build the synthetic fn* Form, then analyse it through the regular path
    // so multi-arity / closure / arg checks all ride existing FnNode
    // infrastructure. Every arity's param vector is prefixed with the implicit
    // `&form &env` (ADR-0086) so the macro body can introspect its call form +
    // lexical environment; `expandIfMacro` prepends the matching two Values.
    // Single arity → `(fn* [&form &env PARAMS…] BODY…)`; multi-arity →
    // `(fn* ([&form &env a] …) …)`.
    const fn_form: Form = if (multi_arity) blk: {
        const clauses = items[head..];
        const fn_items = try arena.alloc(Form, 1 + clauses.len);
        fn_items[0] = macro_dispatch.makeSymbol("fn*", form.location);
        for (clauses, 0..) |c, j| {
            const sub = c.data.list; // ([params] body…) — validated above
            const new_clause = try arena.alloc(Form, sub.len);
            new_clause[0] = try prependImplicitMacroParams(arena, sub[0], form.location);
            @memcpy(new_clause[1..], sub[1..]);
            fn_items[1 + j] = .{ .data = .{ .list = new_clause }, .location = c.location };
        }
        break :blk .{ .data = .{ .list = fn_items }, .location = form.location };
    } else blk: {
        const fn_items = try arena.alloc(Form, 2 + (items.len - head - 1));
        fn_items[0] = macro_dispatch.makeSymbol("fn*", form.location);
        fn_items[1] = try prependImplicitMacroParams(arena, items[head], form.location);
        @memcpy(fn_items[2..], items[head + 1 ..]);
        break :blk .{ .data = .{ .list = fn_items }, .location = form.location };
    };
    const value_node = try analyzer_mod.analyze(arena, rt, env, scope, fn_form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .def_node = .{
        .name = name_sym.name,
        .value_expr = value_node,
        .is_macro = true,
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
    if (items.len < 2 or items.len > 4)
        return error_catalog.raise(.def_arity_invalid, form.location, .{ .got = items.len - 1 });
    if (items[1].data != .symbol)
        return error_catalog.raise(.def_name_not_symbol, items[1].location, .{});
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null)
        return error_catalog.raise(.def_name_namespace_qualified, items[1].location, .{ .ns = name_sym.ns.?, .name = name_sym.name });

    // `(def name doc-string init)` (clj): the 4-element form carries a string
    // docstring between name and init (→ `:doc` in Var.meta). 2-elem = no init,
    // 3-elem = `(def name init)`. A 4-elem form whose 3rd item is not a string
    // is a genuine arity error.
    var doc_form: ?Form = null;
    const init_idx: ?usize = switch (items.len) {
        2 => null,
        3 => 2,
        else => blk: {
            if (items[2].data != .string)
                return error_catalog.raise(.def_arity_invalid, form.location, .{ .got = items.len - 1 });
            doc_form = items[2];
            break :blk 3;
        },
    };
    // ADR-0038: pre-register the Var at analyze time so recursive
    // defns + forward references inside `(do ...)` resolve. Var lands
    // with placeholder nil; `evalDef` (tree_walk.zig:466) and the VM
    // op_def arm re-intern with the actual value at runtime. env.intern
    // is idempotent (env.zig:353-357 updates root in place).
    const ns = env.current_ns orelse
        return error_catalog.raiseInternal(form.location, "def: no current namespace");
    // ADR-0038 amendment (D-184): declare-if-absent — pre-register so
    // recursive / forward refs resolve, but do NOT reset an existing Var's
    // root to nil (evalDef sets the value at eval time; a throwing re-def
    // must leave the old root intact — JVM parity).
    const var_ptr = try env.internDeclare(ns, name_sym.name);
    // D-183 part (c): honour a `^meta` map on the def target. cljw
    // symbols are metadata-less (ADR-0037), so the reader parks the
    // metadata on the name Form's `.meta` side-channel; lift it into the
    // (otherwise dormant) `Var.meta` Clojure-map slot here, at analyze
    // time. `env.intern`'s runtime re-intern (ADR-0038) updates root only
    // and never touches `.meta`, so this survives evaluation.
    // Combine the reader `^meta` map (if any) with an optional `:doc` from the
    // `(def name doc init)` form, then lift into Var.meta.
    if (items[1].meta != null or doc_form != null) {
        var meta_items: std.ArrayList(Form) = .empty;
        if (items[1].meta) |mf| {
            if (mf.data == .map) try meta_items.appendSlice(arena, mf.data.map);
        }
        if (doc_form) |d| {
            try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "doc" } }, .location = form.location });
            try meta_items.append(arena, d);
        }
        const meta_map: Form = .{ .data = .{ .map = try arena.dupe(Form, meta_items.items) }, .location = form.location };
        var_ptr.meta = try analyzer_mod.formToValue(rt, env, try unquoteMetaValues(arena, meta_map));
    }
    // `^:dynamic` / `^:private` on the def target set the Var flags (evalDef /
    // op_def copy DefNode flags onto the Var). Without this the metadata was
    // lifted into Var.meta but the flags stayed false, so `(def ^:dynamic *x*)`
    // could not be `binding`-rebound. `^:macro` has its own defmacro path.
    const is_dynamic = metaFlag(rt, var_ptr.meta, "dynamic");
    const is_private = metaFlag(rt, var_ptr.meta, "private");
    const value_node = if (init_idx) |idx|
        try analyzer_mod.analyze(arena, rt, env, scope, items[idx], macro_table)
    else
        try analyzer_mod.makeConstant(arena, .nil_val, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .def_node = .{
        .name = name_sym.name,
        .value_expr = value_node,
        .is_dynamic = is_dynamic,
        .is_private = is_private,
        .has_init = init_idx != null,
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
    env: *Env,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_catalog.raise(.quote_arity_invalid, form.location, .{ .got = items.len - 1 });
    const v = try analyzer_mod.formToValue(rt, env, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .quote_node = .{ .quoted = v, .loc = form.location } };
    return n;
}

/// `(var sym)` — the Var that `sym` resolves to, as a `.var_ref` Value.
/// `#'sym` reads to this form. Const-folded at analyse time: `env.intern`
/// is idempotent and a `*Var` is stable across re-`def` / `alter-var-root`
/// (which mutate the Var's root, not its identity), so a constant
/// `.var_ref` to the resolved `*Var` stays correct. This rides the
/// existing `.constant` Node (both backends already lower it) — no new
/// Node variant, so the dual-backend parity contract is not engaged.
pub fn analyzeVar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    _ = rt;
    if (items.len != 2)
        return error_catalog.raise(.var_arity_invalid, form.location, .{ .got = items.len - 1 });
    const target = items[1];
    if (target.data != .symbol)
        return error_catalog.raise(.var_arg_not_symbol, form.location, .{ .actual = target.typeName() });
    const sym = target.data.symbol;
    const ns: *env_mod.Namespace = if (sym.ns) |ns_name|
        (env.findNs(ns_name) orelse return error_catalog.raise(.var_unresolved, form.location, .{ .sym = sym.name }))
    else
        (env.current_ns orelse return error_catalog.raise(.var_unresolved, form.location, .{ .sym = sym.name }));
    const var_ptr = ns.resolve(sym.name) orelse
        return error_catalog.raise(.var_unresolved, form.location, .{ .sym = sym.name });
    const n = try arena.create(Node);
    n.* = .{ .constant = .{ .value = Value.encodeHeapPtr(.var_ref, var_ptr), .loc = form.location } };
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

    const libspec = try parseLibspecForm(arena, inner_form, form.location, false);
    const n = try arena.create(Node);
    n.* = .{ .require_node = libspec };
    return n;
}

/// Shared libspec-vector parser. Used by `analyzeRequire` (top-level
/// `(require '[ns :as alias :refer [...]])`) AND by `analyzeNs`'s
/// `:require` arm (row 14.7 / D-098). Accepts a bare-symbol shape or
/// a `[ns :as alias :refer [names]]` vector; raises
/// `feature_not_supported` cleanly for `:reload` / `:refer :all` /
/// `:as-alias`. Returns a `node_mod.RequireNode` with arena-owned
/// strings. NOT a top-level pub function — `analyzeRequire` and the
/// new `parseNsLibspec` (below) are its only callers.
fn parseLibspecForm(
    arena: std.mem.Allocator,
    inner_form: Form,
    loc: @import("../../runtime/error/info.zig").SourceLocation,
    default_refer_all: bool,
) AnalyzeError!node_mod.RequireNode {
    var ns_sym: form_mod.SymbolRef = undefined;
    var alias_name: ?[]const u8 = null;
    var refer_names: []const []const u8 = &.{};
    var exclude_names: []const []const u8 = &.{};
    // `null` = caller default (bare `:use` → all, bare `:require` → none);
    // `:refer :all`/`:exclude` set it true, `:refer [..]`/`:only` set it false.
    var refer_all_override: ?bool = null;

    switch (inner_form.data) {
        .symbol => |s| ns_sym = s,
        .vector => |vec| {
            if (vec.len == 0 or vec[0].data != .symbol)
                return error_catalog.raise(.feature_not_supported, inner_form.location, .{ .name = "require libspec must begin with a symbol" });
            ns_sym = vec[0].data.symbol;
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
                    // `:refer :all` refers every public var (env.referAll).
                    if (val.data == .keyword and val.data.keyword.ns == null and std.mem.eql(u8, val.data.keyword.name, "all")) {
                        refer_all_override = true;
                        i += 2;
                        continue;
                    }
                    refer_names = try parseSymbolNameSeq(arena, val, "require :refer value must be a vector of symbols or :all");
                    refer_all_override = false;
                } else if (std.mem.eql(u8, kw.name, "only")) {
                    // `:only (a b)` (a `:use` whitelist) ≡ `:refer [a b]`.
                    refer_names = try parseSymbolNameSeq(arena, val, "require/use :only value must be a list or vector of symbols");
                    refer_all_override = false;
                } else if (std.mem.eql(u8, kw.name, "exclude")) {
                    // `:exclude (a b)` (a `:use` blacklist) → refer-all minus these.
                    exclude_names = try parseSymbolNameSeq(arena, val, "require/use :exclude value must be a list or vector of symbols");
                    refer_all_override = true;
                } else if (std.mem.eql(u8, kw.name, "include-macros") or
                    std.mem.eql(u8, kw.name, "refer-macros") or
                    std.mem.eql(u8, kw.name, "require-macros"))
                {
                    // D-300: cljs-only LIBSPEC keywords. JVM clj IGNORES all three
                    // inside a libspec (oracle-confirmed; only `(:require-macros …)`
                    // as a top-level DIRECTIVE is rejected). The macros are already
                    // reachable via the ordinary `:require` on the JVM. Tolerate +
                    // skip the value (boolean for include/require, vector for refer)
                    // so cljc libraries load. The `i += 2` below consumes the value.
                } else {
                    return error_catalog.raise(.feature_not_supported, vec[i].location, .{ .name = "require libspec keyword (only :as / :refer / :only / :exclude / :include-macros / :require-macros supported)" });
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

    return .{
        .ns_name = ns_name,
        .alias = alias_name,
        .refers = refer_names,
        .refer_all = refer_all_override orelse default_refer_all,
        .exclude = exclude_names,
        .loc = loc,
    };
}

/// Parse a `:refer`/`:only`/`:exclude` value into a slice of unqualified
/// symbol names. Accepts both vector (`[a b]`) and list (`(a b)`) shapes —
/// `:use` filter values are conventionally lists, `:refer` a vector.
fn parseSymbolNameSeq(
    arena: std.mem.Allocator,
    val: Form,
    comptime err_name: []const u8,
) AnalyzeError![]const []const u8 {
    const items: []const Form = switch (val.data) {
        .vector => |v| v,
        .list => |l| l,
        else => return error_catalog.raise(.feature_not_supported, val.location, .{ .name = err_name }),
    };
    const buf = try arena.alloc([]const u8, items.len);
    for (items, 0..) |entry, k| {
        if (entry.data != .symbol or entry.data.symbol.ns != null)
            return error_catalog.raise(.feature_not_supported, entry.location, .{ .name = err_name });
        buf[k] = try arena.dupe(u8, entry.data.symbol.name);
    }
    return buf;
}

/// `(ns foo)` / `(ns foo (:refer-clojure))` /
/// `(ns foo (:refer-clojure :exclude [+]))` /
/// `(ns foo (:refer-clojure :only [reduce]))` /
/// `(ns foo (:require [other :as a :refer [v1 v2]]))`. ADR-0035 D1.
/// Row 14.7 (D-098): extended from bare `(:refer-clojure)`-only to
/// `:exclude` / `:only` filters + ns-level `(:require [...])` arms.
/// `:rename` remains a clean `feature_not_supported` raise pending
/// D-112 (separate follow-up; rarely needed in Tier-A test corpora).
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
    var refer_clojure_exclude: []const []const u8 = &.{};
    var refer_clojure_only: ?[]const []const u8 = null;
    var libspecs: std.ArrayList(node_mod.RequireNode) = .empty;
    defer libspecs.deinit(arena);
    var imports: std.ArrayList(node_mod.ImportEntry) = .empty;
    defer imports.deinit(arena);

    var i: usize = 2;
    // Optional docstring + attr-map after the name (clj: `(ns name doc? attrs?
    // refs*)`) — real libs open with a docstring; skip before the directives.
    if (i < items.len and items[i].data == .string) i += 1;
    if (i < items.len and items[i].data == .map) i += 1;
    while (i < items.len) : (i += 1) {
        const directive = items[i];
        // D-299: clj accepts a list `(:require …)` OR a vector `[:require …]`
        // ns directive (clojure.core's own string.clj uses the vector form).
        const inner: []const Form = switch (directive.data) {
            .list => |l| l,
            .vector => |v| v,
            else => return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive must be a list or vector" }),
        };
        if (inner.len == 0 or inner[0].data != .keyword)
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive must begin with a keyword" });
        const kw = inner[0].data.keyword;
        if (kw.ns != null)
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive keyword must be unqualified" });
        if (std.mem.eql(u8, kw.name, "refer-clojure")) {
            refer_clojure = true;
            try parseReferClojureFilters(arena, inner[1..], &refer_clojure_exclude, &refer_clojure_only, directive.location);
        } else if (std.mem.eql(u8, kw.name, "require")) {
            for (inner[1..]) |libspec_form| {
                const ls = try parseLibspecForm(arena, libspec_form, libspec_form.location, false);
                try libspecs.append(arena, ls);
            }
        } else if (std.mem.eql(u8, kw.name, "use")) {
            // `(:use foo)` = require foo + refer ALL its publics; `[foo :only
            // (a)]` narrows to a whitelist, `[foo :exclude (a)]` to a blacklist
            // (default_refer_all=true is the bare-`:use` shape).
            for (inner[1..]) |libspec_form| {
                const ls = try parseLibspecForm(arena, libspec_form, libspec_form.location, true);
                try libspecs.append(arena, ls);
            }
        } else if (std.mem.eql(u8, kw.name, "import")) {
            try parseImportForms(arena, inner[1..], &imports);
        } else {
            // NB `(:require-macros …)` is a cljs-only DIRECTIVE that clj REJECTS
            // on the JVM (oracle-confirmed) — well-formed cljc guards it behind a
            // reader conditional, so cljw matches clj by rejecting it here. The
            // cljs `:include-macros`/`:refer-macros` LIBSPEC keywords (which clj
            // DOES ignore) are tolerated in parseLibspecForm (D-300).
            return error_catalog.raise(.feature_not_supported, directive.location, .{ .name = "ns directive (only :refer-clojure / :require / :use / :import supported; :rename pending)" });
        }
    }

    const n = try arena.create(Node);
    n.* = .{ .ns_node = .{
        .name = ns_name,
        .refer_clojure = refer_clojure,
        .refer_clojure_exclude = refer_clojure_exclude,
        .refer_clojure_only = refer_clojure_only,
        .libspecs = try arena.dupe(node_mod.RequireNode, libspecs.items),
        .imports = try arena.dupe(node_mod.ImportEntry, imports.items),
        .loc = form.location,
    } };
    return n;
}

/// Parse `(:import …)` entries into `(simple, fqcn)` pairs. Two shapes per
/// JVM Clojure: a bare qualified symbol `pkg.Class` (→ simple = the class
/// segment, fqcn = the whole symbol text), or a prefix list/vector
/// `[pkg C1 C2 …]` (→ each `Ci` becomes `pkg.Ci`). Arena-owned strings.
fn parseImportForms(
    arena: std.mem.Allocator,
    args: []const Form,
    out: *std.ArrayList(node_mod.ImportEntry),
) AnalyzeError!void {
    for (args) |entry| {
        switch (entry.data) {
            .symbol => |s| {
                // `pkg.Class` reads as a single dotted name (ns=null). The
                // simple name is the segment after the final '.'.
                const fqcn = try symFullText(arena, s);
                const dot = std.mem.findScalarLast(u8, fqcn, '.');
                const simple = if (dot) |d| fqcn[d + 1 ..] else fqcn;
                try out.append(arena, .{ .simple = try arena.dupe(u8, simple), .fqcn = fqcn });
            },
            .list, .vector => {
                const elems = if (entry.data == .list) entry.data.list else entry.data.vector;
                if (elems.len < 2 or elems[0].data != .symbol)
                    return error_catalog.raise(.feature_not_supported, entry.location, .{ .name = ":import prefix form must be (package Class …)" });
                const pkg = try symFullText(arena, elems[0].data.symbol);
                for (elems[1..]) |ce| {
                    if (ce.data != .symbol or ce.data.symbol.ns != null)
                        return error_catalog.raise(.feature_not_supported, ce.location, .{ .name = ":import class entry must be a simple symbol" });
                    const cname = ce.data.symbol.name;
                    const fqcn = try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg, cname });
                    try out.append(arena, .{ .simple = try arena.dupe(u8, cname), .fqcn = fqcn });
                }
            },
            else => return error_catalog.raise(.feature_not_supported, entry.location, .{ .name = ":import entry must be a symbol or (package Class …) list" }),
        }
    }
}

/// Reconstruct a symbol's full dotted text (`ns.name`, or just `name`).
fn symFullText(arena: std.mem.Allocator, s: form_mod.SymbolRef) ![]const u8 {
    return if (s.ns) |prefix|
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, s.name })
    else
        try arena.dupe(u8, s.name);
}

/// Walk `(:refer-clojure ...args)`'s argument list, materialising
/// `:exclude` / `:only` filter sets into arena-owned slices.
/// `:rename` raises `feature_not_supported` cleanly per D-112.
fn parseReferClojureFilters(
    arena: std.mem.Allocator,
    args: []const Form,
    exclude_out: *[]const []const u8,
    only_out: *?[]const []const u8,
    loc: @import("../../runtime/error/info.zig").SourceLocation,
) AnalyzeError!void {
    var i: usize = 0;
    while (i < args.len) {
        if (args[i].data != .keyword)
            return error_catalog.raise(.feature_not_supported, args[i].location, .{ .name = ":refer-clojure args must be keyword/value pairs" });
        const kw = args[i].data.keyword;
        if (kw.ns != null)
            return error_catalog.raise(.feature_not_supported, args[i].location, .{ .name = ":refer-clojure keyword must be unqualified" });
        if (i + 1 >= args.len)
            return error_catalog.raise(.feature_not_supported, args[i].location, .{ .name = ":refer-clojure keyword without value" });
        const val = args[i + 1];
        if (std.mem.eql(u8, kw.name, "exclude")) {
            // D-299: clj accepts a list OR vector arg (`:exclude (vec)` / `[vec]`).
            exclude_out.* = try parseSymbolNameSeq(arena, val, ":refer-clojure :exclude value must be a list or vector of symbols");
        } else if (std.mem.eql(u8, kw.name, "only")) {
            only_out.* = try parseSymbolNameSeq(arena, val, ":refer-clojure :only value must be a list or vector of symbols");
        } else if (std.mem.eql(u8, kw.name, "rename")) {
            return error_catalog.raise(.feature_not_supported, args[i].location, .{ .name = ":refer-clojure :rename (D-112 follow-up)" });
        } else {
            _ = loc;
            return error_catalog.raise(.feature_not_supported, args[i].location, .{ .name = ":refer-clojure keyword (only :exclude / :only supported; :rename = D-112)" });
        }
        i += 2;
    }
}


/// `(set! var-symbol value)` — assign to a dynamic Var's binding. The
/// target must be a symbol naming an existing `^:dynamic` Var (resolved
/// here, mirroring `binding`). The field-set form `(set! (.f o) v)` is a
/// separate, unsupported sub-case (clean `feature_not_supported`).
pub fn analyzeSetBang(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len != 3)
        return error_catalog.raise(.set_arity_invalid, form.location, .{ .got = items.len - 1 });
    if (items[1].data != .symbol)
        return error_catalog.raise(.feature_not_supported, items[1].location, .{ .name = "set! on a non-symbol target (field assignment)" });
    const name_sym = items[1].data.symbol;
    // ADR-0104: a bare deftype mutable field (in a method's field context, not
    // shadowed by a local) → in-place field write. Checked before Var
    // resolution; locals win (so a shadowing let* binding takes the Var path
    // and errors like clj). External `(set! (.f o) v)` stays the non-symbol
    // feature_not_supported branch above (clj rejects it too).
    if (name_sym.ns == null) {
        if (scope) |s| {
            if (s.lookup(name_sym.name) == null) {
                if (s.mutable_fields) |ctx| {
                    if (ctx.contains(name_sym.name)) {
                        const target = try arena.create(Node);
                        target.* = .{ .local_ref = .{ .name = "this", .index = ctx.this_slot, .loc = form.location } };
                        const value_node = try analyzer_mod.analyze(arena, rt, env, scope, items[2], macro_table);
                        const n = try arena.create(Node);
                        n.* = .{ .set_field_node = .{
                            .target = target,
                            .field_name = name_sym.name,
                            .value_expr = value_node,
                            .loc = form.location,
                        } };
                        return n;
                    }
                }
            }
        }
    }
    // Resolve the target Var exactly as `binding` does (qualified → alias
    // then findNs, else current ns). `set!` mutates an existing Var.
    const target_ns = if (name_sym.ns) |ns_name|
        (if (env.current_ns) |here| here.aliases.get(ns_name) else null) orelse
            env.findNs(ns_name) orelse
            return error_catalog.raise(.namespace_unknown, items[1].location, .{ .ns = ns_name })
    else
        env.current_ns orelse
            return error_catalog.raise(.current_namespace_missing, items[1].location, .{ .sym = name_sym.name });
    const var_ptr = target_ns.resolve(name_sym.name) orelse
        return error_catalog.raise(.symbol_unresolved, items[1].location, .{ .sym = analyzer_mod.symFullName(name_sym) });
    // ADR-0096: no analyze-time dynamic check — JVM's `set!` only checks
    // thread-binding at runtime (a non-dynamic var is simply never bound). The
    // analyze-time check also raced the eval-time `flags.dynamic` set, falsely
    // rejecting a same-unit `(do (def ^:dynamic z 0) (binding [z 1] (set! z 9)))`.

    const value_node = try analyzer_mod.analyze(arena, rt, env, scope, items[2], macro_table);
    const n = try arena.create(Node);
    n.* = .{ .set_node = .{
        .var_ptr = var_ptr,
        .value_expr = value_node,
        .loc = form.location,
    } };
    return n;
}

/// `(__mut-fields* this [mfield…] body…)` — ADR-0104 internal transport the
/// deftype macro emits around a method body that declares ≥1 mutable field. It
/// pushes the Scope mutable-field context (so a bare mutable field reads live
/// and `(set! field v)` writes the slot) and returns the analyzed body — the
/// form is transparent at eval (no own Node). `this` is the method's instance
/// param (already a local in the enclosing scope).
pub fn analyzeMutFields(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 4 or items[1].data != .symbol or items[2].data != .vector)
        return error_catalog.raiseInternal(form.location, "__mut-fields*: malformed compiler-emitted form");
    const parent = scope orelse
        return error_catalog.raiseInternal(form.location, "__mut-fields*: no enclosing scope");
    const this_slot = parent.lookup(items[1].data.symbol.name) orelse
        return error_catalog.raiseInternal(form.location, "__mut-fields*: instance param not in scope");

    const name_forms = items[2].data.vector;
    const names = try arena.alloc([]const u8, name_forms.len);
    for (name_forms, 0..) |nf, i| {
        if (nf.data != .symbol)
            return error_catalog.raiseInternal(form.location, "__mut-fields*: non-symbol field name");
        names[i] = nf.data.symbol.name;
    }
    const ctx = try arena.create(analyzer_mod.MutFieldCtx);
    ctx.* = .{ .this_slot = this_slot, .names = names };

    var child = parent.child();
    child.mutable_fields = ctx;
    defer child.deinit(arena);

    return bindings.analyzeBody(arena, rt, env, &child, items[3..], form, macro_table);
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
