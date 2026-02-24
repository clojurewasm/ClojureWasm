// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.walk — generic tree walker with replacement.
//! Replaces clojure/walk.clj.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../engine/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const metadata = @import("../builtins/metadata.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Helpers
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

/// Returns true if val is a record (map with :__reify_type key whose value is a string).
fn isRecord(allocator: Allocator, val: Value) bool {
    const key = Value.initKeyword(allocator, .{ .ns = null, .name = "__reify_type" });
    if (val.tag() == .map) {
        if (val.asMap().get(key)) |v| return v.tag() == .string;
    } else if (val.tag() == .hash_map) {
        if (val.asHashMap().get(key)) |v| return v.tag() == .string;
    }
    return false;
}

/// Resolve a core var's value (not call it).
fn resolveCore(allocator: Allocator, name: []const u8) !Value {
    _ = allocator;
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

/// Resolve a var from clojure.walk namespace.
fn resolveWalk(name: []const u8) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const walk_ns = env.findNamespace("clojure.walk") orelse return error.EvalError;
    const v = walk_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

/// Helper: reduce over record entries, skipping :__reify_type, applying inner to each entry
fn reduceRecordWalk(allocator: Allocator, inner: Value, form: Value) !Value {
    var result = form;
    var seq = try callCore(allocator, "seq", &.{form});
    while (seq.tag() != .nil) {
        const entry = try callCore(allocator, "first", &.{seq});
        const k = try callCore(allocator, "key", &.{entry});
        const skip = blk: {
            if (k.tag() == .keyword) {
                const kw = k.asKeyword();
                if (kw.ns == null and std.mem.eql(u8, kw.name, "__reify_type")) break :blk true;
            }
            break :blk false;
        };
        if (!skip) {
            const transformed = try bootstrap.callFnVal(allocator, inner, &.{entry});
            result = try callCore(allocator, "conj", &.{ result, transformed });
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() != .nil and seq.tag() != .list and seq.tag() != .cons and
            seq.tag() != .lazy_seq and seq.tag() != .chunked_cons)
        {
            break;
        }
    }
    return result;
}

// ============================================================
// walk / postwalk / prewalk
// ============================================================

/// (walk inner outer form)
fn walkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to walk", .{args.len});
    const inner = args[0];
    const outer = args[1];
    const form = args[2];

    if (form.tag() == .list) {
        const mapped = try callCore(allocator, "map", &.{ inner, form });
        const list_fn = try resolveCore(allocator, "list");
        const as_list = try callCore(allocator, "apply", &.{ list_fn, mapped });
        const form_meta = metadata.getMeta(form);
        const with_m = if (form_meta.tag() != .nil)
            try metadata.withMetaFn(allocator, &.{ as_list, form_meta })
        else
            as_list;
        return bootstrap.callFnVal(allocator, outer, &.{with_m});
    }

    if (form.tag() == .cons or form.tag() == .lazy_seq or form.tag() == .chunked_cons) {
        const mapped = try callCore(allocator, "map", &.{ inner, form });
        const realized = try callCore(allocator, "doall", &.{mapped});
        const form_meta = metadata.getMeta(form);
        const with_m = if (form_meta.tag() != .nil)
            try metadata.withMetaFn(allocator, &.{ realized, form_meta })
        else
            realized;
        return bootstrap.callFnVal(allocator, outer, &.{with_m});
    }

    if (isRecord(allocator, form)) {
        const reduced = try reduceRecordWalk(allocator, inner, form);
        return bootstrap.callFnVal(allocator, outer, &.{reduced});
    }

    switch (form.tag()) {
        .vector, .map, .hash_map, .set => {
            const mapped = try callCore(allocator, "map", &.{ inner, form });
            const empty = try callCore(allocator, "empty", &.{form});
            const result = try callCore(allocator, "into", &.{ empty, mapped });
            return bootstrap.callFnVal(allocator, outer, &.{result});
        },
        else => {},
    }

    return bootstrap.callFnVal(allocator, outer, &.{form});
}

/// (postwalk f form) — depth-first, post-order traversal
fn postwalkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to postwalk", .{args.len});
    const f = args[0];
    const form = args[1];
    const pw_fn = try resolveWalk("postwalk");
    const partial_f = try callCore(allocator, "partial", &.{ pw_fn, f });
    return walkFn(allocator, &.{ partial_f, f, form });
}

/// (prewalk f form) — depth-first, pre-order traversal
fn prewalkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prewalk", .{args.len});
    const f = args[0];
    const form = args[1];
    const pw_fn = try resolveWalk("prewalk");
    const partial_f = try callCore(allocator, "partial", &.{ pw_fn, f });
    const identity_fn = try resolveCore(allocator, "identity");
    const transformed = try bootstrap.callFnVal(allocator, f, &.{form});
    return walkFn(allocator, &.{ partial_f, identity_fn, transformed });
}

// ============================================================
// postwalk-demo / prewalk-demo
// ============================================================

fn postwalkDemoFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to postwalk-demo", .{args.len});
    const demo_fn = Value.initBuiltinFn(&walkDemoPrint);
    return postwalkFn(allocator, &.{ demo_fn, args[0] });
}

fn prewalkDemoFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prewalk-demo", .{args.len});
    const demo_fn = Value.initBuiltinFn(&walkDemoPrint);
    return prewalkFn(allocator, &.{ demo_fn, args[0] });
}

fn walkDemoPrint(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    _ = try callCore(allocator, "print", &.{Value.initString(allocator, "Walked: ")});
    _ = try callCore(allocator, "prn", &.{args[0]});
    return args[0];
}

// ============================================================
// postwalk-replace / prewalk-replace
// ============================================================

fn postwalkReplaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to postwalk-replace", .{args.len});
    const smap = args[0];
    const form = args[1];
    const replacer_fn = Value.initBuiltinFn(&replacerHelper);
    const replacer = try callCore(allocator, "partial", &.{ replacer_fn, smap });
    return postwalkFn(allocator, &.{ replacer, form });
}

fn prewalkReplaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prewalk-replace", .{args.len});
    const smap = args[0];
    const form = args[1];
    const replacer_fn = Value.initBuiltinFn(&replacerHelper);
    const replacer = try callCore(allocator, "partial", &.{ replacer_fn, smap });
    return prewalkFn(allocator, &.{ replacer, form });
}

fn replacerHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const smap = args[0];
    const x = args[1];
    const contains = try callCore(allocator, "contains?", &.{ smap, x });
    if (contains.tag() == .boolean and contains.asBoolean()) {
        return callCore(allocator, "get", &.{ smap, x });
    }
    return x;
}

// ============================================================
// keywordize-keys / stringify-keys
// ============================================================

fn keywordizeKeysFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keywordize-keys", .{args.len});
    const kw_fn = Value.initBuiltinFn(&keywordizeWalker);
    return postwalkFn(allocator, &.{ kw_fn, args[0] });
}

fn keywordizeWalker(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const x = args[0];
    if (x.tag() != .map and x.tag() != .hash_map) return x;
    const entry_fn = Value.initBuiltinFn(&keywordizeEntry);
    const mapped = try callCore(allocator, "map", &.{ entry_fn, x });
    const empty_map = try callCore(allocator, "hash-map", &.{});
    return callCore(allocator, "into", &.{ empty_map, mapped });
}

fn keywordizeEntry(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const entry = args[0];
    const k = try callCore(allocator, "key", &.{entry});
    const v = try callCore(allocator, "val", &.{entry});
    if (k.tag() == .string) {
        const kw = try callCore(allocator, "keyword", &.{k});
        return callCore(allocator, "vector", &.{ kw, v });
    }
    return callCore(allocator, "vector", &.{ k, v });
}

fn stringifyKeysFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stringify-keys", .{args.len});
    const str_fn = Value.initBuiltinFn(&stringifyWalker);
    return postwalkFn(allocator, &.{ str_fn, args[0] });
}

fn stringifyWalker(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const x = args[0];
    if (x.tag() != .map and x.tag() != .hash_map) return x;
    const entry_fn = Value.initBuiltinFn(&stringifyEntry);
    const mapped = try callCore(allocator, "map", &.{ entry_fn, x });
    const empty_map = try callCore(allocator, "hash-map", &.{});
    return callCore(allocator, "into", &.{ empty_map, mapped });
}

fn stringifyEntry(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const entry = args[0];
    const k = try callCore(allocator, "key", &.{entry});
    const v = try callCore(allocator, "val", &.{entry});
    if (k.tag() == .keyword) {
        const name = try callCore(allocator, "name", &.{k});
        return callCore(allocator, "vector", &.{ name, v });
    }
    return callCore(allocator, "vector", &.{ k, v });
}

// ============================================================
// macroexpand-all
// ============================================================

fn macroexpandAllFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to macroexpand-all", .{args.len});
    const expand_fn = Value.initBuiltinFn(&macroexpandWalker);
    return prewalkFn(allocator, &.{ expand_fn, args[0] });
}

fn macroexpandWalker(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const x = args[0];
    switch (x.tag()) {
        .list, .cons, .lazy_seq, .chunked_cons => {
            return callCore(allocator, "macroexpand", &.{x});
        },
        else => return x,
    }
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "walk", .func = &walkFn, .doc = "Traverses form, an arbitrary data structure. inner and outer are functions. Applies inner to each element of form, building up a data structure of the same type, then applies outer to the result." },
    .{ .name = "postwalk", .func = &postwalkFn, .doc = "Performs a depth-first, post-order traversal of form. Calls f on each sub-form, uses f's return value in place of the original." },
    .{ .name = "prewalk", .func = &prewalkFn, .doc = "Like postwalk, but does pre-order traversal." },
    .{ .name = "postwalk-demo", .func = &postwalkDemoFn, .doc = "Demonstrates the behavior of postwalk by printing each form as it is walked. Returns form." },
    .{ .name = "prewalk-demo", .func = &prewalkDemoFn, .doc = "Demonstrates the behavior of prewalk by printing each form as it is walked. Returns form." },
    .{ .name = "postwalk-replace", .func = &postwalkReplaceFn, .doc = "Recursively transforms form by replacing keys in smap with their values. Does replacement at the leaves of the tree first." },
    .{ .name = "prewalk-replace", .func = &prewalkReplaceFn, .doc = "Recursively transforms form by replacing keys in smap with their values. Does replacement at the root of the tree first." },
    .{ .name = "keywordize-keys", .func = &keywordizeKeysFn, .doc = "Recursively transforms all map keys from strings to keywords." },
    .{ .name = "stringify-keys", .func = &stringifyKeysFn, .doc = "Recursively transforms all map keys from keywords to strings." },
    .{ .name = "macroexpand-all", .func = &macroexpandAllFn, .doc = "Recursively performs all possible macroexpansions in form." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.walk",
    .builtins = &builtins,
};
