// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.data — Non-core data functions (diff).
//! Replaces clojure/data.clj.
//! UPSTREAM-DIFF: Protocol dispatch uses cond on predicates (CW has no Java type hierarchy).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const Protocol = value_mod.Protocol;
const ProtocolFn = value_mod.ProtocolFn;
const MethodSig = value_mod.MethodSig;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const clojure_core_protocols = @import("clojure_core_protocols.zig");
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

fn callSet(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    // Ensure clojure.set is loaded (may be lazy in cache)
    var set_ns = env.findNamespace("clojure.set");
    if (set_ns == null) {
        // Trigger lazy loading via (require 'clojure.set)
        const require_sym = Value.initSymbol(allocator, .{ .ns = null, .name = "clojure.set" });
        _ = try callCore(allocator, "require", &.{require_sym});
        set_ns = env.findNamespace("clojure.set");
    }
    const ns = set_ns orelse return error.EvalError;
    const v = ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

// ============================================================
// Private helpers
// ============================================================

/// (atom-diff a b) → [a b nil] if different, [nil nil a] if same
fn atomDiff(a: Value, b: Value) [3]Value {
    if (a.eql(b)) {
        return .{ Value.nil_val, Value.nil_val, a };
    }
    return .{ a, b, Value.nil_val };
}

/// (vectorize m) — converts index map to vector, nil if empty
fn vectorize(allocator: Allocator, m: Value) !Value {
    if (m.tag() == .nil) return Value.nil_val;
    const s = try callCore(allocator, "seq", &.{m});
    if (s.tag() == .nil) return Value.nil_val;

    // Find max key
    const ks = try callCore(allocator, "keys", &.{m});
    const max_key = try callCore(allocator, "apply", &.{ try resolveCore(allocator, "max"), ks });
    const max_idx = max_key.asInteger();

    // Build vector of nils, then assoc values
    var result = try callCore(allocator, "vec", &.{
        try callCore(allocator, "repeat", &.{ Value.initInteger(max_idx), Value.nil_val }),
    });
    var seq = try callCore(allocator, "seq", &.{m});
    while (seq.tag() != .nil) {
        const entry = try callCore(allocator, "first", &.{seq});
        const k = try callCore(allocator, "key", &.{entry});
        const v = try callCore(allocator, "val", &.{entry});
        result = try callCore(allocator, "assoc", &.{ result, k, v });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

fn resolveCore(allocator: Allocator, name: []const u8) !Value {
    _ = allocator;
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

/// (diff-associative-key a b k) → [a-only, b-only, both] for key k
fn diffAssociativeKey(allocator: Allocator, a: Value, b: Value, k: Value) ![3]Value {
    const va = try callCore(allocator, "get", &.{ a, k });
    const vb = try callCore(allocator, "get", &.{ b, k });
    const sub = try diffFnImpl(allocator, va, vb);
    const a_star = sub[0];
    const b_star = sub[1];
    const ab = sub[2];
    const in_a_v = try callCore(allocator, "contains?", &.{ a, k });
    const in_b_v = try callCore(allocator, "contains?", &.{ b, k });
    const in_a = in_a_v.tag() == .boolean and in_a_v.asBoolean();
    const in_b = in_b_v.tag() == .boolean and in_b_v.asBoolean();
    const same = in_a and in_b and (ab.tag() != .nil or (va.tag() == .nil and vb.tag() == .nil));

    const ra = if (in_a and (a_star.tag() != .nil or !same))
        try callCore(allocator, "hash-map", &.{ k, a_star })
    else
        Value.nil_val;
    const rb = if (in_b and (b_star.tag() != .nil or !same))
        try callCore(allocator, "hash-map", &.{ k, b_star })
    else
        Value.nil_val;
    const rab = if (same)
        try callCore(allocator, "hash-map", &.{ k, ab })
    else
        Value.nil_val;

    return .{ ra, rb, rab };
}

/// (diff-associative a b ks) → [a-only, b-only, both]
fn diffAssociative(allocator: Allocator, a: Value, b: Value, ks: Value) ![3]Value {
    var result = [3]Value{ Value.nil_val, Value.nil_val, Value.nil_val };
    var seq = try callCore(allocator, "seq", &.{ks});
    while (seq.tag() != .nil) {
        const k = try callCore(allocator, "first", &.{seq});
        const key_diff = try diffAssociativeKey(allocator, a, b, k);
        // merge each position
        for (0..3) |i| {
            if (key_diff[i].tag() != .nil) {
                result[i] = if (result[i].tag() == .nil)
                    key_diff[i]
                else
                    try callCore(allocator, "merge", &.{ result[i], key_diff[i] });
            }
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (diff-sequential a b) → [a-only, b-only, both]
fn diffSequential(allocator: Allocator, a: Value, b: Value) ![3]Value {
    const va = if (isVector(a)) a else try callCore(allocator, "vec", &.{a});
    const vb = if (isVector(b)) b else try callCore(allocator, "vec", &.{b});
    const ca = try callCore(allocator, "count", &.{va});
    const cb = try callCore(allocator, "count", &.{vb});
    const max_count = try callCore(allocator, "max", &.{ ca, cb });
    const ks = try callCore(allocator, "range", &.{max_count});
    const d = try diffAssociative(allocator, va, vb, ks);
    return .{
        try vectorize(allocator, d[0]),
        try vectorize(allocator, d[1]),
        try vectorize(allocator, d[2]),
    };
}

fn isVector(v: Value) bool {
    return v.tag() == .vector;
}

fn isMap(v: Value) bool {
    return v.tag() == .map or v.tag() == .hash_map;
}

fn isSet(v: Value) bool {
    return v.tag() == .set;
}

fn isSequential(v: Value) bool {
    return v.tag() == .list or v.tag() == .vector or v.tag() == .cons or
        v.tag() == .lazy_seq or v.tag() == .chunked_cons;
}

// ============================================================
// Protocol implementations
// ============================================================

/// EqualityPartition for Object — cond dispatch based on type
fn equalityPartitionFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to equality-partition", .{args.len});
    const x = args[0];
    if (x.tag() == .nil) return Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "atom" });
    if (isMap(x)) return Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "map" });
    if (isSet(x)) return Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "set" });
    if (isSequential(x)) return Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "sequential" });
    return Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "atom" });
}

/// Diff for Object — cond dispatch based on type
fn diffSimilarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to diff-similar", .{args.len});
    const a = args[0];
    const b = args[1];

    if (a.tag() == .nil) {
        const d = atomDiff(a, b);
        return callCore(allocator, "vector", &.{ d[0], d[1], d[2] });
    }
    if (isSet(a)) {
        const aval = if (isSet(a)) a else try callCore(allocator, "set", &.{a});
        const bval = if (isSet(b)) b else try callCore(allocator, "set", &.{b});
        const a_only = try callCore(allocator, "not-empty", &.{try callSet(allocator, "difference", &.{ aval, bval })});
        const b_only = try callCore(allocator, "not-empty", &.{try callSet(allocator, "difference", &.{ bval, aval })});
        const both = try callCore(allocator, "not-empty", &.{try callSet(allocator, "intersection", &.{ aval, bval })});
        return callCore(allocator, "vector", &.{ a_only, b_only, both });
    }
    if (isMap(a)) {
        const ka = try callCore(allocator, "set", &.{try callCore(allocator, "keys", &.{a})});
        const kb = try callCore(allocator, "set", &.{try callCore(allocator, "keys", &.{b})});
        const all_keys = try callSet(allocator, "union", &.{ ka, kb });
        const d = try diffAssociative(allocator, a, b, all_keys);
        return callCore(allocator, "vector", &.{ d[0], d[1], d[2] });
    }
    if (isSequential(a)) {
        const d = try diffSequential(allocator, a, b);
        return callCore(allocator, "vector", &.{ d[0], d[1], d[2] });
    }
    // :atom fallback
    const d = atomDiff(a, b);
    return callCore(allocator, "vector", &.{ d[0], d[1], d[2] });
}

// ============================================================
// diff (public)
// ============================================================

/// (diff a b) — Recursively compares a and b.
fn diffFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to diff", .{args.len});
    const result = try diffFnImpl(allocator, args[0], args[1]);
    return callCore(allocator, "vector", &.{ result[0], result[1], result[2] });
}

/// Internal diff implementation returning array of 3 values
fn diffFnImpl(allocator: Allocator, a: Value, b: Value) ![3]Value {
    if (a.eql(b)) {
        return .{ Value.nil_val, Value.nil_val, a };
    }
    // Dispatch via equality-partition
    const ep_a = try equalityPartitionFn(allocator, &.{a});
    const ep_b = try equalityPartitionFn(allocator, &.{b});
    if (ep_a.eql(ep_b)) {
        // Use protocol dispatch (diff-similar)
        const result = try diffSimilarFn(allocator, &.{ a, b });
        // Extract from vector
        return .{
            try callCore(allocator, "nth", &.{ result, Value.initInteger(0) }),
            try callCore(allocator, "nth", &.{ result, Value.initInteger(1) }),
            try callCore(allocator, "nth", &.{ result, Value.initInteger(2) }),
        };
    }
    return atomDiff(a, b);
}

// ============================================================
// Protocol registration
// ============================================================

fn registerProtocols(allocator: Allocator, env: *Env) anyerror!void {
    const ns = try env.findOrCreateNamespace("clojure.data");

    // === EqualityPartition ===
    const ep_sigs = &[_]MethodSig{
        .{ .name = "equality-partition", .arity = 1 },
    };
    const ep = try clojure_core_protocols.createProtocol(allocator, ns, "EqualityPartition", ep_sigs, false);
    try clojure_core_protocols.extendType(allocator, ep, "Object", &.{
        .{ .name = "equality-partition", .func = &equalityPartitionFn },
    });

    // === Diff ===
    const diff_sigs = &[_]MethodSig{
        .{ .name = "diff-similar", .arity = 2 },
    };
    const diff_proto = try clojure_core_protocols.createProtocol(allocator, ns, "Diff", diff_sigs, false);
    try clojure_core_protocols.extendType(allocator, diff_proto, "Object", &.{
        .{ .name = "diff-similar", .func = &diffSimilarFn },
    });
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "diff", .func = &diffFn, .doc = "Recursively compares a and b, returning a tuple of [things-only-in-a things-only-in-b things-in-both]." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.data",
    .builtins = &builtins,
    .post_register = &registerProtocols,
};
