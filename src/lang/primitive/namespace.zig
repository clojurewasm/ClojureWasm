// SPDX-License-Identifier: EPL-2.0
//! Namespace reflection primitives (ADR-0083, D-230): `ns-name`, `the-ns`,
//! `find-ns`, `all-ns`, `create-ns`, `ns-interns`, `ns-publics`, `ns-map`,
//! `ns-resolve`. They read the Env namespace graph and return the current
//! namespace as a first-class `.ns` Value (`Env.nsValue`).
//!
//! Backend: impl-only (reads `Env`/`Namespace`/`Var` directly)
//! Impl deps: none
//! Clojure peer: clojure.core/{ns-name,the-ns,find-ns,all-ns,create-ns,…}
//!
//! `*ns*` itself is a dynamic Var interned in bootstrap.zig (kept in sync by
//! `Env.setCurrentNs`), not a primitive here. `in-ns` stays the analyzer form
//! (it routes through `setCurrentNs`), so it is not re-interned here. `remove-ns`
//! is deferred (a dangling `.ns` → freed Env `*Namespace` is a use-after-free
//! needing a tombstone design — separate debt).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Namespace = env_mod.Namespace;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const list_collection = @import("../../runtime/collection/list.zig");

/// Resolve a `ns-or-symbol` argument to a `*Namespace`: an `.ns` Value decodes
/// directly; a symbol is looked up by name; anything else (or an unknown
/// symbol) yields `null`.
fn resolveNs(env: *Env, v: Value) ?*Namespace {
    return switch (v.tag()) {
        .ns => v.decodePtr(*Namespace),
        .symbol => env.findNs(symbol_mod.asSymbol(v).name),
        else => null,
    };
}

/// `(the-ns x)` — `x` if it is a Namespace; the named ns if `x` is a symbol;
/// throws if the symbol names no ns. Spec: clojure.core/the-ns.
pub fn theNsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("the-ns", args, 1, loc);
    if (args[0].tag() == .ns) return args[0];
    if (resolveNs(env, args[0])) |ns| return Env.nsValue(ns);
    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "the-ns on a non-namespace / unknown ns" });
}

/// `(ns-name ns)` — the namespace's name as a symbol. Accepts a ns or a symbol
/// (via the-ns, like clj `(.name (the-ns ns))`). Spec: clojure.core/ns-name.
pub fn nsNameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-name", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-name on a non-namespace" });
    return symbol_mod.intern(rt, null, ns.name);
}

/// `(find-ns sym)` — the named Namespace value, or nil. Spec:
/// clojure.core/find-ns.
pub fn findNsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("find-ns", args, 1, loc);
    if (args[0].tag() != .symbol) return Value.nil_val;
    if (env.findNs(symbol_mod.asSymbol(args[0]).name)) |ns| return Env.nsValue(ns);
    return Value.nil_val;
}

/// `(create-ns sym)` — find-or-create the named ns, return it. Spec:
/// clojure.core/create-ns (does NOT switch current ns).
pub fn createNsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("create-ns", args, 1, loc);
    if (args[0].tag() != .symbol)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "create-ns on a non-symbol" });
    const ns = try env.findOrCreateNs(symbol_mod.asSymbol(args[0]).name);
    return Env.nsValue(ns);
}

/// `(all-ns)` — a seq of every Namespace value. Order is unspecified (clj's is
/// unordered too). Spec: clojure.core/all-ns.
pub fn allNsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("all-ns", args, 0, loc);
    var acc = try list_collection.emptyList(rt);
    var it = env.namespaces.valueIterator();
    while (it.next()) |ns_ptr| {
        acc = try list_collection.consHeap(rt, Env.nsValue(ns_ptr.*), acc);
    }
    return acc;
}

/// Build a `{symbol → var-value}` map over a VarMap (the interned-vars view).
/// When `publics_only`, `^:private` Vars are skipped.
fn mapOfVars(rt: *Runtime, vm: *const env_mod.VarMap, publics_only: bool) !Value {
    var m = map_collection.empty();
    var it = vm.iterator();
    while (it.next()) |entry| {
        const v: *env_mod.Var = entry.value_ptr.*;
        if (publics_only and v.flags.private) continue;
        const sym = try symbol_mod.intern(rt, null, entry.key_ptr.*);
        m = try map_collection.assoc(rt, m, sym, Value.encodeHeapPtr(.var_ref, v));
    }
    return m;
}

/// `(ns-interns ns)` — map of the ns's INTERNED vars (its own `mappings`, not
/// refers). Spec: clojure.core/ns-interns.
pub fn nsInternsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-interns", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-interns on a non-namespace" });
    return mapOfVars(rt, &ns.mappings, false);
}

/// `(ns-publics ns)` — map of the ns's PUBLIC interned vars (private skipped).
/// Spec: clojure.core/ns-publics.
pub fn nsPublicsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-publics", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-publics on a non-namespace" });
    return mapOfVars(rt, &ns.mappings, true);
}

/// `(ns-map ns)` — map of EVERY var visible in the ns (interned + refers).
/// Spec: clojure.core/ns-map.
pub fn nsMapFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-map", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-map on a non-namespace" });
    var m = try mapOfVars(rt, &ns.mappings, false);
    var it = ns.refers.iterator();
    while (it.next()) |entry| {
        const v: *env_mod.Var = entry.value_ptr.*;
        const sym = try symbol_mod.intern(rt, null, entry.key_ptr.*);
        m = try map_collection.assoc(rt, m, sym, Value.encodeHeapPtr(.var_ref, v));
    }
    return m;
}

/// `(ns-resolve ns sym)` — the Var `sym` resolves to within `ns` (mappings then
/// refers), or nil. Spec: clojure.core/ns-resolve (2-arity; the 3-arity env
/// form is not modelled).
pub fn nsResolveFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("ns-resolve", args, 2, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-resolve on a non-namespace" });
    if (args[1].tag() != .symbol) return Value.nil_val;
    if (ns.resolve(symbol_mod.asSymbol(args[1]).name)) |v| return Value.encodeHeapPtr(.var_ref, v);
    return Value.nil_val;
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "the-ns", .f = &theNsFn },
    .{ .name = "ns-name", .f = &nsNameFn },
    .{ .name = "find-ns", .f = &findNsFn },
    .{ .name = "create-ns", .f = &createNsFn },
    .{ .name = "all-ns", .f = &allNsFn },
    .{ .name = "ns-interns", .f = &nsInternsFn },
    .{ .name = "ns-publics", .f = &nsPublicsFn },
    .{ .name = "ns-map", .f = &nsMapFn },
    .{ .name = "ns-resolve", .f = &nsResolveFn },
};

/// Intern the cluster into `rt` (→ referred into user/ + clojure.core).
pub fn register(env: *Env, rt_ns: *Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
