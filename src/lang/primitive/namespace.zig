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

const std = @import("std");
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
const keyword_mod = @import("../../runtime/keyword.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const list_collection = @import("../../runtime/collection/list.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const loader = @import("../../eval/loader.zig");

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

/// `(find-var sym)` — the Var named by a FULLY-QUALIFIED symbol `ns/name`, or
/// nil if no such var (the ns must exist). Spec: clojure.core/find-var.
pub fn findVarFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("find-var", args, 1, loc);
    if (args[0].tag() != .symbol or symbol_mod.asSymbol(args[0]).ns == null)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "find-var needs a namespace-qualified symbol" });
    const sym = symbol_mod.asSymbol(args[0]);
    const ns = env.findNs(sym.ns.?) orelse
        return error_catalog.raise(.namespace_unknown, loc, .{ .ns = sym.ns.? });
    if (ns.resolve(sym.name)) |v| return Value.encodeHeapPtr(.var_ref, v);
    return Value.nil_val;
}

/// `(ns-refers ns)` — map of `symbol → Var` for the vars REFERRED into the ns
/// (via use / refer / require :refer), excluding the ns's own interned vars.
/// Spec: clojure.core/ns-refers (the refers-only counterpart of `ns-map`).
pub fn nsRefersFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-refers", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-refers on a non-namespace" });
    var m = map_collection.empty();
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

/// `(alias alias-sym ns-sym)` — add `alias-sym → (the-ns ns-sym)` to the current
/// ns's alias table (the named ns must already exist). Spec: clojure.core/alias.
pub fn aliasFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("alias", args, 2, loc);
    if (args[0].tag() != .symbol or args[1].tag() != .symbol)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "alias requires two symbols" });
    const target = env.findNs(symbol_mod.asSymbol(args[1]).name) orelse
        return error_catalog.raise(.lib_not_found, loc, .{ .ns = symbol_mod.asSymbol(args[1]).name });
    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = symbol_mod.asSymbol(args[0]).name });
    try env.setAlias(here, symbol_mod.asSymbol(args[0]).name, target);
    return Value.nil_val;
}

/// `(ns-aliases ns)` — map of `alias-symbol → Namespace value` for the ns.
/// Spec: clojure.core/ns-aliases.
pub fn nsAliasesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("ns-aliases", args, 1, loc);
    const ns = resolveNs(env, args[0]) orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "ns-aliases on a non-namespace" });
    var m = map_collection.empty();
    var it = ns.aliases.iterator();
    while (it.next()) |entry| {
        const sym = try symbol_mod.intern(rt, null, entry.key_ptr.*);
        m = try map_collection.assoc(rt, m, sym, Env.nsValue(entry.value_ptr.*));
    }
    return m;
}

/// `(in-ns sym)` — switch `*ns*` to the named namespace (creating it),
/// returning it as an `.ns` Value (ADR-0083 / ADR-0085). The runtime-fn
/// counterpart of the `in-ns` special form: reached when the arg is computed
/// (`(in-ns (gensym))`) or in non-head position (`(apply in-ns …)`).
pub fn inNsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("in-ns", args, 1, loc);
    if (args[0].tag() != .symbol)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "in-ns requires a symbol" });
    const ns = try env.findOrCreateNs(symbol_mod.asSymbol(args[0]).name);
    env.setCurrentNs(ns);
    return Env.nsValue(ns);
}

/// Collect the symbol names from a vector/list of symbols (a `:only` /
/// `:exclude` filter value) into a gpa-owned slice. The inner name slices
/// point at the stable symbol interner; the caller frees the outer slice.
fn collectNames(rt: *Runtime, coll: Value) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(rt.gpa);
    switch (coll.tag()) {
        .vector => {
            const n = vector_collection.count(coll);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const e = vector_collection.nth(coll, i);
                if (e.tag() == .symbol) try names.append(rt.gpa, symbol_mod.asSymbol(e).name);
            }
        },
        .list => {
            // Guard on `.list` + count, not `!isEmpty`: `rest` of a
            // single-element list returns nil (tag != .list), and
            // `isEmpty(nil)` is false — an `!isEmpty` loop would spin.
            var cur = coll;
            while (cur.tag() == .list and list_collection.countOf(cur) > 0) {
                const e = list_collection.first(cur);
                if (e.tag() == .symbol) try names.append(rt.gpa, symbol_mod.asSymbol(e).name);
                cur = list_collection.rest(cur);
            }
        },
        else => {},
    }
    return names.toOwnedSlice(rt.gpa);
}

const ReferOpts = struct {
    only: ?[]const []const u8 = null,
    exclude: []const []const u8 = &.{},
    /// gpa-owned slices to free after the refer call (the `only` whitelist +
    /// the `exclude` blacklist when they were built from a filter collection).
    free_only: ?[]const []const u8 = null,
    free_exclude: ?[]const []const u8 = null,

    fn deinit(self: ReferOpts, rt: *Runtime) void {
        if (self.free_only) |s| rt.gpa.free(s);
        if (self.free_exclude) |s| rt.gpa.free(s);
    }
};

/// Parse `:only (a b)` / `:exclude (a b)` keyword-value pairs from `kvs`
/// (refer's trailing args, or a vector libspec's elements after the ns).
/// `:rename` / `:as` raise (deferred). Returns owned filter slices in `out`.
fn parseReferOpts(rt: *Runtime, kvs: []const Value, loc: SourceLocation) anyerror!ReferOpts {
    var out: ReferOpts = .{};
    errdefer out.deinit(rt);
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (kvs[i].tag() != .keyword) continue;
        const kname = keyword_mod.asKeyword(kvs[i]).name;
        if (std.mem.eql(u8, kname, "only")) {
            const names = try collectNames(rt, kvs[i + 1]);
            out.only = names;
            out.free_only = names;
        } else if (std.mem.eql(u8, kname, "exclude")) {
            const names = try collectNames(rt, kvs[i + 1]);
            out.exclude = names;
            out.free_exclude = names;
        } else if (std.mem.eql(u8, kname, "rename") or std.mem.eql(u8, kname, "as")) {
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "use/refer :rename / :as" });
        }
    }
    return out;
}

/// `(refer ns-sym & filters)` — refer the named (already-loaded) namespace's
/// publics into the current ns, honouring `:only` / `:exclude`. Spec:
/// clojure.core/refer (the runtime fn the `:use`/`:require :refer` directives
/// share the env primitive with).
pub fn referFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1 or args[0].tag() != .symbol)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "refer requires a namespace symbol" });
    const target = env.findNs(symbol_mod.asSymbol(args[0]).name) orelse
        return error_catalog.raise(.lib_not_found, loc, .{ .ns = symbol_mod.asSymbol(args[0]).name });
    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = symbol_mod.asSymbol(args[0]).name });
    var opts = try parseReferOpts(rt, args[1..], loc);
    defer opts.deinit(rt);
    try env.referAllWithFilter(target, here, opts.exclude, opts.only);
    return Value.nil_val;
}

/// `(use & libspecs)` — load (require if needed) + refer each libspec. Each
/// libspec is a namespace symbol (`'clojure.set`) or a vector
/// (`['clojure.set :only (union)]`). The runtime-fn counterpart that
/// `clojure.test-helper`'s `temp-ns` calls via `apply`. Spec: clojure.core/use.
pub fn useFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = "use" });
    for (args) |libspec| {
        switch (libspec.tag()) {
            .symbol => {
                const target = try loader.loadOrFindNs(rt, env, symbol_mod.asSymbol(libspec).name, loc);
                try env.referAllWithFilter(target, here, &.{}, null);
            },
            .vector => {
                const cnt = vector_collection.count(libspec);
                if (cnt < 1 or vector_collection.nth(libspec, 0).tag() != .symbol)
                    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "use libspec vector must start with a namespace symbol" });
                const target = try loader.loadOrFindNs(rt, env, symbol_mod.asSymbol(vector_collection.nth(libspec, 0)).name, loc);
                // Gather the opts (elements after the ns symbol) into a slice.
                var kv_buf: [16]Value = undefined;
                const opt_n = @min(@as(usize, cnt - 1), kv_buf.len);
                var k: usize = 0;
                while (k < opt_n) : (k += 1) kv_buf[k] = vector_collection.nth(libspec, @intCast(k + 1));
                var opts = try parseReferOpts(rt, kv_buf[0..opt_n], loc);
                defer opts.deinit(rt);
                try env.referAllWithFilter(target, here, opts.exclude, opts.only);
            },
            else => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "use libspec must be a symbol or vector" }),
        }
    }
    return Value.nil_val;
}

/// `(require & libspecs)` — load each libspec (require-if-needed) and apply its
/// `:as` alias / `:refer` list. The runtime-fn counterpart of the require
/// special form (ADR-0085): reached when a libspec is computed (`(require ns)`
/// with `ns` a local, `(apply require specs)`). Each libspec is a namespace
/// symbol or a `[ns :as alias :refer [a b] | :refer :all]` vector. Flag
/// keywords (`:reload` / `:verbose`) are accepted and ignored (cljw always
/// loads once). Returns nil.
pub fn requireFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = "require" });
    for (args) |libspec| {
        switch (libspec.tag()) {
            .keyword => {}, // :reload / :verbose / :reload-all — load-once, ignore
            .symbol => {
                _ = try loader.loadOrFindNs(rt, env, symbol_mod.asSymbol(libspec).name, loc);
            },
            .vector => {
                const cnt = vector_collection.count(libspec);
                if (cnt < 1 or vector_collection.nth(libspec, 0).tag() != .symbol)
                    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "require libspec vector must start with a namespace symbol" });
                const target = try loader.loadOrFindNs(rt, env, symbol_mod.asSymbol(vector_collection.nth(libspec, 0)).name, loc);
                var i: u32 = 1;
                while (i + 1 <= cnt - 1) : (i += 2) {
                    const opt = vector_collection.nth(libspec, i);
                    const val = vector_collection.nth(libspec, i + 1);
                    if (opt.tag() != .keyword) continue;
                    const on = keyword_mod.asKeyword(opt).name;
                    if (std.mem.eql(u8, on, "as")) {
                        if (val.tag() != .symbol)
                            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "require :as needs a symbol alias" });
                        try env.setAlias(here, symbol_mod.asSymbol(val).name, target);
                    } else if (std.mem.eql(u8, on, "refer")) {
                        if (val.tag() == .keyword and std.mem.eql(u8, keyword_mod.asKeyword(val).name, "all")) {
                            try env.referAllWithFilter(target, here, &.{}, null);
                        } else {
                            const names = try collectNames(rt, val);
                            defer rt.gpa.free(names);
                            for (names) |nm| _ = try env.referOne(target, here, nm);
                        }
                    } else if (std.mem.eql(u8, on, "rename") or std.mem.eql(u8, on, "as-alias")) {
                        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "require :rename / :as-alias" });
                    }
                }
            },
            else => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "require libspec must be a symbol or vector" }),
        }
    }
    return Value.nil_val;
}

/// `(import* "pkg.Class")` — register the class's simple name → FQCN in the
/// current ns's import map (so a bare `Class` / `(Class. …)` resolves to it).
/// The runtime primitive the `import` macro expands to (clj parity: clj's
/// import expands to `clojure.core/import*` calls). Returns nil.
pub fn importStarFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    try error_catalog.checkArity("import*", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "import* requires a class-name string" });
    const fqcn = string_collection.asString(args[0]);
    const here = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = "import*" });
    // Simple name = the segment after the final '.' (the whole string if none).
    const simple = if (std.mem.findScalarLast(u8, fqcn, '.')) |dot| fqcn[dot + 1 ..] else fqcn;
    try here.addImport(env.alloc, simple, fqcn);
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
    .{ .name = "ns-refers", .f = &nsRefersFn },
    .{ .name = "ns-resolve", .f = &nsResolveFn },
    .{ .name = "find-var", .f = &findVarFn },
    .{ .name = "alias", .f = &aliasFn },
    .{ .name = "ns-aliases", .f = &nsAliasesFn },
    .{ .name = "in-ns", .f = &inNsFn },
    .{ .name = "refer", .f = &referFn },
    .{ .name = "use", .f = &useFn },
    .{ .name = "require", .f = &requireFn },
    .{ .name = "import*", .f = &importStarFn },
};

/// Intern the cluster into `rt` (→ referred into user/ + clojure.core).
pub fn register(env: *Env, rt_ns: *Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
