// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.set — Relational algebra operations on sets.
//! Replaces clojure/set.clj.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Helper: resolve a core var by name and call it
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn resolveCoreFn(name: []const u8) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

// ============================================================
// Private helpers
// ============================================================

/// (bubble-max-key k coll) — moves max-key element to front
fn bubbleMaxKey(allocator: Allocator, k_fn: Value, coll: Value) !Value {
    const max_key_fn = try resolveCoreFn("max-key");
    const max = try callCore(allocator, "apply", &.{ max_key_fn, k_fn, coll });
    // (cons max (remove #(identical? max %) coll))
    // Since we can't create anonymous fns in Zig, iterate manually
    var result_items = std.ArrayList(Value).empty;
    result_items.append(allocator, max) catch return error.EvalError;
    var seq = try callCore(allocator, "seq", &.{coll});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        // identical? = same enum value (Value is enum(u64))
        if (item != max) {
            result_items.append(allocator, item) catch return error.EvalError;
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    // Build list from items (reverse order for cons)
    var result: Value = Value.nil_val;
    var i = result_items.items.len;
    while (i > 0) {
        i -= 1;
        result = try callCore(allocator, "cons", &.{ result_items.items[i], result });
    }
    return result;
}

// ============================================================
// Public builtins
// ============================================================

/// (union) (union s1) (union s1 s2) (union s1 s2 & sets)
fn unionFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return callCore(allocator, "hash-set", &.{});
    if (args.len == 1) return args[0];
    if (args.len == 2) {
        const s1 = args[0];
        const s2 = args[1];
        const n1 = (try callCore(allocator, "count", &.{s1})).asInteger();
        const n2 = (try callCore(allocator, "count", &.{s2})).asInteger();
        if (n1 < n2) {
            return callCore(allocator, "reduce", &.{ try resolveCoreFn("conj"), s2, s1 });
        } else {
            return callCore(allocator, "reduce", &.{ try resolveCoreFn("conj"), s1, s2 });
        }
    }
    // variadic: bubble-max-key count, then reduce into
    const count_fn = try resolveCoreFn("count");
    var coll: Value = Value.nil_val;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        coll = try callCore(allocator, "cons", &.{ args[i], coll });
    }
    const bubbled = try bubbleMaxKey(allocator, count_fn, coll);
    const first_set = try callCore(allocator, "first", &.{bubbled});
    const rest_sets = try callCore(allocator, "rest", &.{bubbled});
    return callCore(allocator, "reduce", &.{ try resolveCoreFn("into"), first_set, rest_sets });
}

/// (intersection s1) (intersection s1 s2) (intersection s1 s2 & sets)
fn intersectionFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to intersection", .{args.len});
    if (args.len == 1) return args[0];
    if (args.len == 2) {
        var s1 = args[0];
        var s2 = args[1];
        const c1 = (try callCore(allocator, "count", &.{s1})).asInteger();
        const c2 = (try callCore(allocator, "count", &.{s2})).asInteger();
        if (c2 < c1) {
            const tmp = s1;
            s1 = s2;
            s2 = tmp;
        }
        var result = s1;
        var seq = try callCore(allocator, "seq", &.{s1});
        while (seq.tag() != .nil) {
            const item = try callCore(allocator, "first", &.{seq});
            const has = try callCore(allocator, "contains?", &.{ s2, item });
            if (!has.isTruthy()) {
                result = try callCore(allocator, "disj", &.{ result, item });
            }
            seq = try callCore(allocator, "next", &.{seq});
            if (seq.tag() == .nil) break;
        }
        return result;
    }
    // variadic: reduce intersection pairwise
    var result = try intersectionFn(allocator, args[0..2]);
    for (args[2..]) |s| {
        result = try intersectionFn(allocator, &.{ result, s });
    }
    return result;
}

/// (difference s1) (difference s1 s2) (difference s1 s2 & sets)
fn differenceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to difference", .{args.len});
    if (args.len == 1) return args[0];
    if (args.len == 2) {
        const s1 = args[0];
        const s2 = args[1];
        const c1 = (try callCore(allocator, "count", &.{s1})).asInteger();
        const c2 = (try callCore(allocator, "count", &.{s2})).asInteger();
        if (c1 < c2) {
            var result = s1;
            var seq = try callCore(allocator, "seq", &.{s1});
            while (seq.tag() != .nil) {
                const item = try callCore(allocator, "first", &.{seq});
                const has = try callCore(allocator, "contains?", &.{ s2, item });
                if (has.isTruthy()) {
                    result = try callCore(allocator, "disj", &.{ result, item });
                }
                seq = try callCore(allocator, "next", &.{seq});
                if (seq.tag() == .nil) break;
            }
            return result;
        } else {
            return callCore(allocator, "reduce", &.{ try resolveCoreFn("disj"), s1, s2 });
        }
    }
    // variadic: reduce difference
    var result = args[0];
    for (args[1..]) |s| {
        result = try differenceFn(allocator, &.{ result, s });
    }
    return result;
}

/// (select pred xset) — filter set by predicate
fn selectFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to select", .{args.len});
    const pred = args[0];
    const xset = args[1];
    var result = xset;
    var seq = try callCore(allocator, "seq", &.{xset});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        const keep = try bootstrap.callFnVal(allocator, pred, &.{item});
        if (!keep.isTruthy()) {
            result = try callCore(allocator, "disj", &.{ result, item });
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (project xrel ks) — select-keys on each map in relation set
fn projectFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to project", .{args.len});
    const xrel = args[0];
    const ks = args[1];
    const orig_meta = try callCore(allocator, "meta", &.{xrel});
    var result = try callCore(allocator, "hash-set", &.{});
    var seq = try callCore(allocator, "seq", &.{xrel});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        const projected = try callCore(allocator, "select-keys", &.{ item, ks });
        result = try callCore(allocator, "conj", &.{ result, projected });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    if (orig_meta.tag() != .nil) {
        result = try callCore(allocator, "with-meta", &.{ result, orig_meta });
    }
    return result;
}

/// (rename-keys map kmap) — rename keys in a map
fn renameKeysFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rename-keys", .{args.len});
    const map_val = args[0];
    const kmap = args[1];
    const kmap_keys = try callCore(allocator, "keys", &.{kmap});
    var base = try callCore(allocator, "apply", &.{ try resolveCoreFn("dissoc"), map_val, kmap_keys });
    var seq = try callCore(allocator, "seq", &.{kmap});
    while (seq.tag() != .nil) {
        const entry = try callCore(allocator, "first", &.{seq});
        const old_key = try callCore(allocator, "first", &.{entry});
        const new_key = try callCore(allocator, "second", &.{entry});
        const has = try callCore(allocator, "contains?", &.{ map_val, old_key });
        if (has.isTruthy()) {
            const old_val = try callCore(allocator, "get", &.{ map_val, old_key });
            base = try callCore(allocator, "assoc", &.{ base, new_key, old_val });
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return base;
}

/// (rename xrel kmap) — rename keys in each map of relation set
fn renameFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rename", .{args.len});
    const xrel = args[0];
    const kmap = args[1];
    const orig_meta = try callCore(allocator, "meta", &.{xrel});
    var result = try callCore(allocator, "hash-set", &.{});
    var seq = try callCore(allocator, "seq", &.{xrel});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        const renamed = try renameKeysFn(allocator, &.{ item, kmap });
        result = try callCore(allocator, "conj", &.{ result, renamed });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    if (orig_meta.tag() != .nil) {
        result = try callCore(allocator, "with-meta", &.{ result, orig_meta });
    }
    return result;
}

/// (index xrel ks) — group relation by key subset
fn indexFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to index", .{args.len});
    const xrel = args[0];
    const ks = args[1];
    var result = try callCore(allocator, "hash-map", &.{});
    var seq = try callCore(allocator, "seq", &.{xrel});
    while (seq.tag() != .nil) {
        const x = try callCore(allocator, "first", &.{seq});
        const ik = try callCore(allocator, "select-keys", &.{ x, ks });
        const existing = try callCore(allocator, "get", &.{ result, ik, try callCore(allocator, "hash-set", &.{}) });
        const new_set = try callCore(allocator, "conj", &.{ existing, x });
        result = try callCore(allocator, "assoc", &.{ result, ik, new_set });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (map-invert m) — swap keys and values
fn mapInvertFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map-invert", .{args.len});
    const m = args[0];
    var result = try callCore(allocator, "hash-map", &.{});
    var seq = try callCore(allocator, "seq", &.{m});
    while (seq.tag() != .nil) {
        const entry = try callCore(allocator, "first", &.{seq});
        const k = try callCore(allocator, "first", &.{entry});
        const v = try callCore(allocator, "second", &.{entry});
        result = try callCore(allocator, "assoc", &.{ result, v, k });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (join xrel yrel) (join xrel yrel km) — relational join
fn joinFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to join", .{args.len});
    const xrel = args[0];
    const yrel = args[1];

    if (args.len == 2) {
        // Natural join
        const xseq = try callCore(allocator, "seq", &.{xrel});
        const yseq = try callCore(allocator, "seq", &.{yrel});
        if (xseq.tag() == .nil or yseq.tag() == .nil) return callCore(allocator, "hash-set", &.{});

        const x_first = try callCore(allocator, "first", &.{xrel});
        const y_first = try callCore(allocator, "first", &.{yrel});
        const x_key_set = try callCore(allocator, "set", &.{try callCore(allocator, "keys", &.{x_first})});
        const y_key_set = try callCore(allocator, "set", &.{try callCore(allocator, "keys", &.{y_first})});
        const ks = try intersectionFn(allocator, &.{ x_key_set, y_key_set });

        const xcount = (try callCore(allocator, "count", &.{xrel})).asInteger();
        const ycount = (try callCore(allocator, "count", &.{yrel})).asInteger();
        const r = if (xcount <= ycount) xrel else yrel;
        const s = if (xcount <= ycount) yrel else xrel;
        const idx = try indexFn(allocator, &.{ r, ks });

        var result = try callCore(allocator, "hash-set", &.{});
        var seq = try callCore(allocator, "seq", &.{s});
        while (seq.tag() != .nil) {
            const x = try callCore(allocator, "first", &.{seq});
            const sel = try callCore(allocator, "select-keys", &.{ x, ks });
            const found = try callCore(allocator, "get", &.{ idx, sel });
            if (found.tag() != .nil) {
                var fseq = try callCore(allocator, "seq", &.{found});
                while (fseq.tag() != .nil) {
                    const f = try callCore(allocator, "first", &.{fseq});
                    const merged = try callCore(allocator, "merge", &.{ f, x });
                    result = try callCore(allocator, "conj", &.{ result, merged });
                    fseq = try callCore(allocator, "next", &.{fseq});
                    if (fseq.tag() == .nil) break;
                }
            }
            seq = try callCore(allocator, "next", &.{seq});
            if (seq.tag() == .nil) break;
        }
        return result;
    } else {
        // Keyed join: (join xrel yrel km)
        const km = args[2];
        const xcount = (try callCore(allocator, "count", &.{xrel})).asInteger();
        const ycount = (try callCore(allocator, "count", &.{yrel})).asInteger();
        const r = if (xcount <= ycount) xrel else yrel;
        const s = if (xcount <= ycount) yrel else xrel;
        const k = if (xcount <= ycount) try mapInvertFn(allocator, &.{km}) else km;
        const k_vals = try callCore(allocator, "vals", &.{k});
        const idx = try indexFn(allocator, &.{ r, k_vals });

        var result = try callCore(allocator, "hash-set", &.{});
        var seq = try callCore(allocator, "seq", &.{s});
        while (seq.tag() != .nil) {
            const x = try callCore(allocator, "first", &.{seq});
            const k_keys = try callCore(allocator, "keys", &.{k});
            const sel = try callCore(allocator, "select-keys", &.{ x, k_keys });
            const renamed = try renameKeysFn(allocator, &.{ sel, k });
            const found = try callCore(allocator, "get", &.{ idx, renamed });
            if (found.tag() != .nil) {
                var fseq = try callCore(allocator, "seq", &.{found});
                while (fseq.tag() != .nil) {
                    const f = try callCore(allocator, "first", &.{fseq});
                    const merged = try callCore(allocator, "merge", &.{ f, x });
                    result = try callCore(allocator, "conj", &.{ result, merged });
                    fseq = try callCore(allocator, "next", &.{fseq});
                    if (fseq.tag() == .nil) break;
                }
            }
            seq = try callCore(allocator, "next", &.{seq});
            if (seq.tag() == .nil) break;
        }
        return result;
    }
}

/// (subset? set1 set2)
fn subsetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subset?", .{args.len});
    const set1 = args[0];
    const set2 = args[1];
    const c1 = (try callCore(allocator, "count", &.{set1})).asInteger();
    const c2 = (try callCore(allocator, "count", &.{set2})).asInteger();
    if (c1 > c2) return Value.false_val;
    var seq = try callCore(allocator, "seq", &.{set1});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        const has = try callCore(allocator, "contains?", &.{ set2, item });
        if (!has.isTruthy()) return Value.false_val;
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return Value.true_val;
}

/// (superset? set1 set2)
fn supersetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to superset?", .{args.len});
    const set1 = args[0];
    const set2 = args[1];
    const c1 = (try callCore(allocator, "count", &.{set1})).asInteger();
    const c2 = (try callCore(allocator, "count", &.{set2})).asInteger();
    if (c1 < c2) return Value.false_val;
    var seq = try callCore(allocator, "seq", &.{set2});
    while (seq.tag() != .nil) {
        const item = try callCore(allocator, "first", &.{seq});
        const has = try callCore(allocator, "contains?", &.{ set1, item });
        if (!has.isTruthy()) return Value.false_val;
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return Value.true_val;
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "union", .func = &unionFn, .doc = "Return a set that is the union of the input sets." },
    .{ .name = "intersection", .func = &intersectionFn, .doc = "Return a set that is the intersection of the input sets." },
    .{ .name = "difference", .func = &differenceFn, .doc = "Return a set that is the first set without elements of the remaining sets." },
    .{ .name = "select", .func = &selectFn, .doc = "Returns a set of the elements for which pred is true." },
    .{ .name = "project", .func = &projectFn, .doc = "Returns a rel of the elements of xrel with only the keys in ks." },
    .{ .name = "rename-keys", .func = &renameKeysFn, .doc = "Returns the map with the keys in kmap renamed to the vals in kmap." },
    .{ .name = "rename", .func = &renameFn, .doc = "Returns a rel of the maps in xrel with the keys in kmap renamed to the vals in kmap." },
    .{ .name = "index", .func = &indexFn, .doc = "Returns a map of the distinct values of ks in the xrel mapped to a set of the maps in xrel with the corresponding values of ks." },
    .{ .name = "map-invert", .func = &mapInvertFn, .doc = "Returns the map with the vals mapped to the keys." },
    .{ .name = "join", .func = &joinFn, .doc = "When passed 2 rels, returns the rel corresponding to the natural join. When passed an additional keymap, joins on the corresponding keys." },
    .{ .name = "subset?", .func = &subsetFn, .doc = "Is set1 a subset of set2?" },
    .{ .name = "superset?", .func = &supersetFn, .doc = "Is set1 a superset of set2?" },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.set",
    .builtins = &builtins,
};
