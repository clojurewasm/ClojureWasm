// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.spec.gen.alpha — Lightweight generator implementation for spec.alpha.
//! Replaces clojure/spec/gen/alpha.clj (566 lines).
//! No rose tree or shrinking — size-based generation using CW's built-in PRNG.
//! Generator representation: {:cljw/gen true :gen (fn [size] value)}

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const PersistentList = @import("../../runtime/collections.zig").PersistentList;
const PersistentVector = @import("../../runtime/collections.zig").PersistentVector;
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Helpers
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn resolveCore(name: []const u8) !Value {
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

fn resolveGenVar(allocator: Allocator, name: []const u8) !Value {
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const gen_ns = env.findNamespace("clojure.spec.gen.alpha") orelse return error.EvalError;
    const v = gen_ns.mappings.get(name) orelse {
        _ = allocator;
        return error.EvalError;
    };
    return v.deref();
}

/// Create a generator map: {:cljw/gen true :gen gen-fn}
fn makeGen(allocator: Allocator, gen_fn: Value) !Value {
    const kw_marker = Value.initKeyword(allocator, .{ .ns = "cljw", .name = "gen" });
    const kw_gen = Value.initKeyword(allocator, .{ .ns = null, .name = "gen" });
    return callCore(allocator, "array-map", &.{ kw_marker, Value.true_val, kw_gen, gen_fn });
}

/// Extract the :gen function from a generator map.
fn getGenFn(allocator: Allocator, gen: Value) !Value {
    const kw_gen = Value.initKeyword(allocator, .{ .ns = null, .name = "gen" });
    return callCore(allocator, "get", &.{ gen, kw_gen });
}

/// Call a generator's :gen fn with a size.
fn callGen(allocator: Allocator, gen: Value, size: Value) !Value {
    const gen_fn = try getGenFn(allocator, gen);
    return bootstrap.callFnVal(allocator, gen_fn, &.{size});
}

// ============================================================
// Layer 0: Foundation
// ============================================================

/// (make-gen gen-fn)
fn makeGenFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-gen", .{args.len});
    return makeGen(allocator, args[0]);
}

/// (generator? x)
fn generatorQFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to generator?", .{args.len});
    const x = args[0];
    const is_map = try callCore(allocator, "map?", &.{x});
    if (!(is_map.tag() == .boolean and is_map.asBoolean())) return Value.false_val;
    const kw_marker = Value.initKeyword(allocator, .{ .ns = "cljw", .name = "gen" });
    const marker = try callCore(allocator, "get", &.{ x, kw_marker });
    return if (marker.tag() == .boolean and marker.asBoolean()) Value.true_val else Value.false_val;
}

/// (generate g) or (generate g size)
fn generateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to generate", .{args.len});
    const g = args[0];
    const size = if (args.len == 2) args[1] else Value.initInteger(30);
    return callGen(allocator, g, size);
}

/// (return val) — generator that always returns val
fn returnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to return", .{args.len});
    // Create a fn that ignores size and returns val
    const helper = Value.initBuiltinFn(&returnHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0] });
    return makeGen(allocator, closure);
}

fn returnHelper(_: Allocator, args: []const Value) anyerror!Value {
    // [val, _size]
    if (args.len != 2) return error.ArityError;
    return args[0];
}

// ============================================================
// Layer 1: Combinators
// ============================================================

/// (fmap f gen) — apply f to generated values
fn fmapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to fmap", .{args.len});
    const f = args[0];
    const gen_fn = try getGenFn(allocator, args[1]);
    const helper = Value.initBuiltinFn(&fmapHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, f, gen_fn });
    return makeGen(allocator, closure);
}

fn fmapHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [f, gen-fn, size]
    if (args.len != 3) return error.ArityError;
    const v = try bootstrap.callFnVal(allocator, args[1], &.{args[2]});
    return bootstrap.callFnVal(allocator, args[0], &.{v});
}

/// (bind gen f) — generate a value, pass to f which returns a new generator
fn bindFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bind", .{args.len});
    const gen_fn = try getGenFn(allocator, args[0]);
    const f = args[1];
    const helper = Value.initBuiltinFn(&bindHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, gen_fn, f });
    return makeGen(allocator, closure);
}

fn bindHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-fn, f, size]
    if (args.len != 3) return error.ArityError;
    const inner = try bootstrap.callFnVal(allocator, args[0], &.{args[2]});
    const gen2 = try bootstrap.callFnVal(allocator, args[1], &.{inner});
    const gen2_fn = try getGenFn(allocator, gen2);
    return bootstrap.callFnVal(allocator, gen2_fn, &.{args[2]});
}

/// (one-of gens) — randomly choose from generators
fn oneOfFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to one-of", .{args.len});
    const helper = Value.initBuiltinFn(&oneOfHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0] });
    return makeGen(allocator, closure);
}

fn oneOfHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gens, size]
    if (args.len != 2) return error.ArityError;
    const g = try callCore(allocator, "rand-nth", &.{args[0]});
    return callGen(allocator, g, args[1]);
}

/// (such-that pred gen max-tries) — generate values satisfying pred
fn suchThatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to such-that", .{args.len});
    const gen_fn = try getGenFn(allocator, args[1]);
    const helper = Value.initBuiltinFn(&suchThatHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0], gen_fn, args[2] });
    return makeGen(allocator, closure);
}

fn suchThatHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [pred, gen-fn, max-tries, size]
    if (args.len != 4) return error.ArityError;
    const pred = args[0];
    const gen_fn = args[1];
    const max_tries = args[2].asInteger();
    const size = args[3];
    var tries: i64 = 0;
    while (true) {
        const v = try bootstrap.callFnVal(allocator, gen_fn, &.{size});
        const ok = try bootstrap.callFnVal(allocator, pred, &.{v});
        if (ok.isTruthy()) return v;
        if (tries >= max_tries) {
            return callCore(allocator, "throw", &.{
                try callCore(allocator, "ex-info", &.{
                    Value.initString(allocator, "Couldn't satisfy such-that predicate after max tries"),
                    try callCore(allocator, "hash-map", &.{
                        Value.initKeyword(allocator, .{ .ns = null, .name = "max-tries" }),
                        Value.initInteger(max_tries),
                        Value.initKeyword(allocator, .{ .ns = null, .name = "last-val" }),
                        v,
                    }),
                }),
            });
        }
        tries += 1;
    }
}

/// (tuple & gens) — generate vectors from each gen
fn tupleFn(allocator: Allocator, args: []const Value) anyerror!Value {
    // Collect gens into a vector
    const gens = try callCore(allocator, "vec", &.{
        try callCore(allocator, "list*", args),
    });
    const helper = Value.initBuiltinFn(&tupleHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, gens });
    return makeGen(allocator, closure);
}

fn tupleHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gens, size]
    if (args.len != 2) return error.ArityError;
    const gens = args[0];
    const size = args[1];
    const cnt = try callCore(allocator, "count", &.{gens});
    const n = cnt.asInteger();
    const items = try allocator.alloc(Value, @intCast(n));
    for (0..@intCast(n)) |i| {
        const g = try callCore(allocator, "nth", &.{ gens, Value.initInteger(@intCast(i)) });
        items[i] = try callGen(allocator, g, size);
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (frequency pairs) — weighted random choice
fn frequencyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to frequency", .{args.len});
    const pairs = args[0];
    // Calculate total weight
    var total: i64 = 0;
    var seq = try callCore(allocator, "seq", &.{pairs});
    while (seq.tag() != .nil) {
        const pair = try callCore(allocator, "first", &.{seq});
        const w = try callCore(allocator, "first", &.{pair});
        total += w.asInteger();
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    const helper = Value.initBuiltinFn(&frequencyHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, Value.initInteger(total), pairs });
    return makeGen(allocator, closure);
}

fn frequencyHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [total, pairs, size]
    if (args.len != 3) return error.ArityError;
    const total = args[0];
    const pairs = args[1];
    const size = args[2];
    var n = (try callCore(allocator, "rand-int", &.{total})).asInteger();
    var seq = try callCore(allocator, "seq", &.{pairs});
    while (seq.tag() != .nil) {
        const pair = try callCore(allocator, "first", &.{seq});
        const w = (try callCore(allocator, "first", &.{pair})).asInteger();
        const g = try callCore(allocator, "second", &.{pair});
        if (n <= w) return callGen(allocator, g, size);
        n -= w;
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    // Fallback: last generator
    const last_pair = try callCore(allocator, "last", &.{pairs});
    const last_gen = try callCore(allocator, "second", &.{last_pair});
    return callGen(allocator, last_gen, size);
}

/// (hash-map & kvs) — generator from alternating key gen pairs
fn hashMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const pairs = try callCore(allocator, "vec", &.{
        try callCore(allocator, "partition", &.{ Value.initInteger(2), try callCore(allocator, "list*", args) }),
    });
    const helper = Value.initBuiltinFn(&hashMapHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, pairs });
    return makeGen(allocator, closure);
}

fn hashMapHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [pairs, size]
    if (args.len != 2) return error.ArityError;
    const pairs = args[0];
    const size = args[1];
    var result = try callCore(allocator, "array-map", &.{});
    var seq = try callCore(allocator, "seq", &.{pairs});
    while (seq.tag() != .nil) {
        const pair = try callCore(allocator, "first", &.{seq});
        const k = try callCore(allocator, "first", &.{pair});
        const g = try callCore(allocator, "second", &.{pair});
        const v = try callGen(allocator, g, size);
        result = try callCore(allocator, "assoc", &.{ result, k, v });
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (elements coll) — randomly choose from coll
fn elementsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to elements", .{args.len});
    const v = try callCore(allocator, "vec", &.{args[0]});
    const helper = Value.initBuiltinFn(&elementsHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, v });
    return makeGen(allocator, closure);
}

fn elementsHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [v, _size]
    if (args.len != 2) return error.ArityError;
    return callCore(allocator, "rand-nth", &.{args[0]});
}

/// (vector gen), (vector gen num), (vector gen min max)
fn vectorFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 3) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vector", .{args.len});
    const gen_fn = try getGenFn(allocator, args[0]);
    if (args.len == 2) {
        // Fixed count
        const helper = Value.initBuiltinFn(&vectorFixedHelper);
        const closure = try callCore(allocator, "partial", &.{ helper, gen_fn, args[1] });
        return makeGen(allocator, closure);
    }
    const min_el = if (args.len >= 3) args[1] else Value.initInteger(0);
    const max_el = if (args.len >= 3) args[2] else Value.initInteger(30);
    const helper = Value.initBuiltinFn(&vectorRangeHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, gen_fn, min_el, max_el });
    return makeGen(allocator, closure);
}

fn vectorFixedHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-fn, count, size]
    if (args.len != 3) return error.ArityError;
    const gen_fn = args[0];
    const count = args[1].asInteger();
    const size = args[2];
    const items = try allocator.alloc(Value, @intCast(count));
    for (0..@intCast(count)) |i| {
        items[i] = try bootstrap.callFnVal(allocator, gen_fn, &.{size});
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

fn vectorRangeHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-fn, min, max, size]
    if (args.len != 4) return error.ArityError;
    const gen_fn = args[0];
    const min_el = args[1].asInteger();
    const max_el = args[2].asInteger();
    const size = args[3];
    const range = @max(1, max_el - min_el + 1);
    const r = try callCore(allocator, "rand-int", &.{Value.initInteger(range)});
    const n = min_el + r.asInteger();
    const items = try allocator.alloc(Value, @intCast(n));
    for (0..@intCast(n)) |i| {
        items[i] = try bootstrap.callFnVal(allocator, gen_fn, &.{size});
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (vector-distinct gen opts)
fn vectorDistinctFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vector-distinct", .{args.len});
    const gen_fn = try getGenFn(allocator, args[0]);
    const helper = Value.initBuiltinFn(&vectorDistinctHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, gen_fn, args[1] });
    return makeGen(allocator, closure);
}

fn vectorDistinctHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-fn, opts, size]
    if (args.len != 3) return error.ArityError;
    const gen_fn = args[0];
    const opts = args[1];
    const size = args[2];

    const num_el = try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "num-elements" }) });
    const min_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "min-elements" });
    const max_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "max-elements" });
    const tries_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "max-tries" });
    const min_el = if ((try callCore(allocator, "get", &.{ opts, min_kw })).tag() != .nil) (try callCore(allocator, "get", &.{ opts, min_kw })).asInteger() else @as(i64, 0);
    const max_el = if ((try callCore(allocator, "get", &.{ opts, max_kw })).tag() != .nil) (try callCore(allocator, "get", &.{ opts, max_kw })).asInteger() else @as(i64, 30);
    const max_tries = if ((try callCore(allocator, "get", &.{ opts, tries_kw })).tag() != .nil) (try callCore(allocator, "get", &.{ opts, tries_kw })).asInteger() else @as(i64, 100);

    const target = if (num_el.tag() != .nil) num_el.asInteger() else blk: {
        const range = @max(1, max_el - min_el + 1);
        const r = try callCore(allocator, "rand-int", &.{Value.initInteger(range)});
        break :blk min_el + r.asInteger();
    };

    var result = try callCore(allocator, "vector", &.{});
    var seen = try callCore(allocator, "hash-set", &.{});
    var tries: i64 = 0;
    while ((try callCore(allocator, "count", &.{result})).asInteger() < target) {
        if (tries >= max_tries) {
            return callCore(allocator, "throw", &.{
                try callCore(allocator, "ex-info", &.{
                    Value.initString(allocator, "Couldn't generate enough distinct values"),
                    try callCore(allocator, "hash-map", &.{
                        Value.initKeyword(allocator, .{ .ns = null, .name = "target" }),
                        Value.initInteger(target),
                        Value.initKeyword(allocator, .{ .ns = null, .name = "generated" }),
                        try callCore(allocator, "count", &.{result}),
                    }),
                }),
            });
        }
        const v = try bootstrap.callFnVal(allocator, gen_fn, &.{size});
        const contains = try callCore(allocator, "contains?", &.{ seen, v });
        if (contains.tag() == .boolean and contains.asBoolean()) {
            tries += 1;
        } else {
            result = try callCore(allocator, "conj", &.{ result, v });
            seen = try callCore(allocator, "conj", &.{ seen, v });
        }
    }
    return result;
}

// ============================================================
// Layer 2: Delay + Collection generators
// ============================================================

/// (delay-gen f) — f is a no-arg fn returning a generator
fn delayGenFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to delay-gen", .{args.len});
    const helper = Value.initBuiltinFn(&delayGenHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0] });
    return makeGen(allocator, closure);
}

fn delayGenHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [f, size]
    if (args.len != 2) return error.ArityError;
    const gen = try bootstrap.callFnVal(allocator, args[0], &.{});
    return callGen(allocator, gen, args[1]);
}

/// delay macro: (delay & body) → (delay-gen (fn [] body...))
fn delayMacro(allocator: Allocator, args: []const Value) anyerror!Value {
    // Build: (clojure.spec.gen.alpha/delay-gen (fn [] body...))
    const fn_sym = Value.initSymbol(allocator, .{ .ns = null, .name = "fn" });
    const empty_vec_items = try allocator.alloc(Value, 0);
    const empty_vec = try allocator.create(PersistentVector);
    empty_vec.* = .{ .items = empty_vec_items };
    const empty_v = Value.initVector(empty_vec);

    // Build (fn [] body...)
    const fn_form_items = try allocator.alloc(Value, 2 + args.len);
    fn_form_items[0] = fn_sym;
    fn_form_items[1] = empty_v;
    for (args, 0..) |arg, i| {
        fn_form_items[2 + i] = arg;
    }
    const fn_form_list = try allocator.create(PersistentList);
    fn_form_list.* = .{ .items = fn_form_items };
    const fn_form = Value.initList(fn_form_list);

    // Build (clojure.spec.gen.alpha/delay-gen fn-form)
    const delay_gen_sym = Value.initSymbol(allocator, .{ .ns = "clojure.spec.gen.alpha", .name = "delay-gen" });
    const result_items = try allocator.alloc(Value, 2);
    result_items[0] = delay_gen_sym;
    result_items[1] = fn_form;
    const result_list = try allocator.create(PersistentList);
    result_list.* = .{ .items = result_items };
    return Value.initList(result_list);
}

/// (list gen) — like vector but generates lists
fn listFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to list", .{args.len});
    const list_star = try resolveCore("list*");
    const vec_gen = try vectorFn(allocator, &.{args[0]});
    return fmapFn(allocator, &.{ list_star, vec_gen });
}

/// (map key-gen val-gen) or (map key-gen val-gen opts)
fn mapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map", .{args.len});
    const key_gen = args[0];
    const val_gen = args[1];

    const min_el: i64 = if (args.len == 3) blk: {
        const v = try callCore(allocator, "get", &.{ args[2], Value.initKeyword(allocator, .{ .ns = null, .name = "min-elements" }), Value.initInteger(0) });
        break :blk v.asInteger();
    } else 0;
    const max_el: i64 = if (args.len == 3) blk: {
        const v = try callCore(allocator, "get", &.{ args[2], Value.initKeyword(allocator, .{ .ns = null, .name = "max-elements" }), Value.initInteger(10) });
        break :blk v.asInteger();
    } else 10;
    const num_el = if (args.len == 3) try callCore(allocator, "get", &.{ args[2], Value.initKeyword(allocator, .{ .ns = null, .name = "num-elements" }) }) else Value.nil_val;

    // Build kv-gen: generates [k, v] pairs
    const kv_helper = Value.initBuiltinFn(&mapKvHelper);
    const key_fn = try getGenFn(allocator, key_gen);
    const val_fn = try getGenFn(allocator, val_gen);
    const kv_closure = try callCore(allocator, "partial", &.{ kv_helper, key_fn, val_fn });
    const kv_gen = try makeGen(allocator, kv_closure);

    // into-fn: (fn [coll] (into {} coll))
    const into_fn = Value.initBuiltinFn(&mapIntoHelper);

    if (num_el.tag() != .nil) {
        const vec_gen = try vectorFn(allocator, &.{ kv_gen, num_el });
        return fmapFn(allocator, &.{ into_fn, vec_gen });
    }
    const vec_gen = try vectorFn(allocator, &.{ kv_gen, Value.initInteger(min_el), Value.initInteger(max_el) });
    return fmapFn(allocator, &.{ into_fn, vec_gen });
}

fn mapKvHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [key-fn, val-fn, size]
    if (args.len != 3) return error.ArityError;
    const k = try bootstrap.callFnVal(allocator, args[0], &.{args[2]});
    const v = try bootstrap.callFnVal(allocator, args[1], &.{args[2]});
    return callCore(allocator, "vector", &.{ k, v });
}

fn mapIntoHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [coll]
    if (args.len != 1) return error.ArityError;
    const empty_map = try callCore(allocator, "hash-map", &.{});
    return callCore(allocator, "into", &.{ empty_map, args[0] });
}

/// (set gen) — like vector but generates sets
fn setFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set", .{args.len});
    const into_set_fn = Value.initBuiltinFn(&setIntoHelper);
    const vec_gen = try vectorFn(allocator, &.{args[0]});
    return fmapFn(allocator, &.{ into_set_fn, vec_gen });
}

fn setIntoHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const empty_set = try callCore(allocator, "hash-set", &.{});
    return callCore(allocator, "into", &.{ empty_set, args[0] });
}

/// (not-empty gen) — retry if empty
fn notEmptyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to not-empty", .{args.len});
    const seq_fn = try resolveCore("seq");
    return suchThatFn(allocator, &.{ seq_fn, args[0], Value.initInteger(100) });
}

/// (cat & gens) — concatenate generator results
fn catFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const gens = try callCore(allocator, "vec", &.{try callCore(allocator, "list*", args)});
    const helper = Value.initBuiltinFn(&catHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, gens });
    return makeGen(allocator, closure);
}

fn catHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gens, size]
    if (args.len != 2) return error.ArityError;
    const gens = args[0];
    const size = args[1];
    var result = try callCore(allocator, "vector", &.{});
    var seq = try callCore(allocator, "seq", &.{gens});
    while (seq.tag() != .nil) {
        const g = try callCore(allocator, "first", &.{seq});
        const v = try callGen(allocator, g, size);
        const is_seq = try callCore(allocator, "sequential?", &.{v});
        if (is_seq.tag() == .boolean and is_seq.asBoolean()) {
            result = try callCore(allocator, "into", &.{ result, v });
        } else {
            result = try callCore(allocator, "conj", &.{ result, v });
        }
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return result;
}

/// (shuffle coll) — Fisher-Yates shuffle
fn shuffleFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to shuffle", .{args.len});
    const v = try callCore(allocator, "vec", &.{args[0]});
    const helper = Value.initBuiltinFn(&shuffleHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, v });
    return makeGen(allocator, closure);
}

fn shuffleHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [v, _size]
    if (args.len != 2) return error.ArityError;
    var v = args[0];
    const n = (try callCore(allocator, "count", &.{v})).asInteger();
    var i = n - 1;
    while (i > 0) : (i -= 1) {
        const j = (try callCore(allocator, "rand-int", &.{Value.initInteger(i + 1)})).asInteger();
        const vi = try callCore(allocator, "nth", &.{ v, Value.initInteger(i) });
        const vj = try callCore(allocator, "nth", &.{ v, Value.initInteger(j) });
        v = try callCore(allocator, "assoc", &.{ v, Value.initInteger(i), vj, Value.initInteger(j), vi });
    }
    return v;
}

// ============================================================
// Layer 3-5: Primitive generators + public wrappers
// ============================================================

fn genIntImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    const range = 1 + 2 * size;
    const r = try callCore(allocator, "rand-int", &.{Value.initInteger(range)});
    return Value.initInteger(r.asInteger() - size);
}

fn genPosIntImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    return Value.initInteger(1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(size)})).asInteger());
}

fn genNatImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    return Value.initInteger((try callCore(allocator, "rand-int", &.{Value.initInteger(size + 1)})).asInteger());
}

fn genNegIntImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    return Value.initInteger(-(1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(size)})).asInteger()));
}

fn genBooleanImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const r = try callCore(allocator, "rand", &.{});
    return if (r.asFloat() < 0.5) Value.true_val else Value.false_val;
}

fn genCharImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const n = 32 + (try callCore(allocator, "rand-int", &.{Value.initInteger(95)})).asInteger();
    return callCore(allocator, "char", &.{Value.initInteger(n)});
}

fn genCharAlphaImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const r = try callCore(allocator, "rand", &.{});
    if (r.asFloat() < 0.5) {
        const n = 65 + (try callCore(allocator, "rand-int", &.{Value.initInteger(26)})).asInteger();
        return callCore(allocator, "char", &.{Value.initInteger(n)});
    }
    const n = 97 + (try callCore(allocator, "rand-int", &.{Value.initInteger(26)})).asInteger();
    return callCore(allocator, "char", &.{Value.initInteger(n)});
}

fn genCharAlphanumImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const n = (try callCore(allocator, "rand-int", &.{Value.initInteger(62)})).asInteger();
    const c: i64 = if (n < 10) 48 + n else if (n < 36) 55 + n else 61 + n;
    return callCore(allocator, "char", &.{Value.initInteger(c)});
}

fn genCharAsciiImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const n = (try callCore(allocator, "rand-int", &.{Value.initInteger(128)})).asInteger();
    return callCore(allocator, "char", &.{Value.initInteger(n)});
}

fn genStringImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-char-fn, size]
    if (args.len != 2) return error.ArityError;
    const char_fn = args[0];
    const size = args[1];
    const n = (try callCore(allocator, "rand-int", &.{Value.initInteger(size.asInteger() + 1)})).asInteger();
    var result = Value.initString(allocator, "");
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        result = try callCore(allocator, "str", &.{ result, c });
    }
    return result;
}

fn genKeywordImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-char-alpha-fn, size]
    if (args.len != 2) return error.ArityError;
    const char_fn = args[0];
    const size = args[1];
    const len = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 20))})).asInteger();
    var s = Value.initString(allocator, "");
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        s = try callCore(allocator, "str", &.{ s, c });
    }
    return callCore(allocator, "keyword", &.{s});
}

fn genKeywordNsImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-char-alpha-fn, size]
    if (args.len != 2) return error.ArityError;
    const char_fn = args[0];
    const size = args[1];
    const len1 = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 10))})).asInteger();
    const len2 = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 10))})).asInteger();
    var ns = Value.initString(allocator, "");
    var i: i64 = 0;
    while (i < len1) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        ns = try callCore(allocator, "str", &.{ ns, c });
    }
    var name = Value.initString(allocator, "");
    i = 0;
    while (i < len2) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        name = try callCore(allocator, "str", &.{ name, c });
    }
    return callCore(allocator, "keyword", &.{ ns, name });
}

fn genSymbolImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-char-alpha-fn, size]
    if (args.len != 2) return error.ArityError;
    const char_fn = args[0];
    const size = args[1];
    const len = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 20))})).asInteger();
    var s = Value.initString(allocator, "");
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        s = try callCore(allocator, "str", &.{ s, c });
    }
    return callCore(allocator, "symbol", &.{s});
}

fn genSymbolNsImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    // [gen-char-alpha-fn, size]
    if (args.len != 2) return error.ArityError;
    const char_fn = args[0];
    const size = args[1];
    const len1 = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 10))})).asInteger();
    const len2 = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(@min(size.asInteger(), 10))})).asInteger();
    var ns_str = Value.initString(allocator, "");
    var i: i64 = 0;
    while (i < len1) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        ns_str = try callCore(allocator, "str", &.{ ns_str, c });
    }
    var name = Value.initString(allocator, "");
    i = 0;
    while (i < len2) : (i += 1) {
        const c = try bootstrap.callFnVal(allocator, char_fn, &.{size});
        name = try callCore(allocator, "str", &.{ name, c });
    }
    return callCore(allocator, "symbol", &.{ ns_str, name });
}

fn genDoubleImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asFloat();
    const r = (try callCore(allocator, "rand", &.{})).asFloat();
    return Value.initFloat(r * 2.0 * size - size);
}

fn genRatioImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    const n = (try callCore(allocator, "rand-int", &.{Value.initInteger(1 + 2 * size)})).asInteger() - size;
    const d = 1 + (try callCore(allocator, "rand-int", &.{Value.initInteger(size)})).asInteger();
    return callCore(allocator, "/", &.{ Value.initInteger(n), Value.initInteger(d) });
}

fn genUuidImpl(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const hex = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    // 8-4-4xxx-Yxxx-12 where 4 is version and Y is variant
    for (0..36) |i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            buf[i] = '-';
        } else if (i == 14) {
            buf[i] = '4'; // version
        } else if (i == 19) {
            const r = (try callCore(allocator, "rand-int", &.{Value.initInteger(4)})).asInteger();
            buf[i] = "89ab"[@intCast(r)];
        } else {
            const r = (try callCore(allocator, "rand-int", &.{Value.initInteger(16)})).asInteger();
            buf[i] = hex[@intCast(r)];
        }
    }
    return Value.initString(allocator, try allocator.dupe(u8, &buf));
}

// --- Public wrapper functions that return generators ---

/// Lookup a private generator var from the gen.alpha namespace.
fn lookupGenVar(allocator: Allocator, name: []const u8) !Value {
    return resolveGenVar(allocator, name);
}

fn booleanFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to boolean", .{args.len});
    return lookupGenVar(allocator, "__gen-boolean");
}

fn bytesFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bytes", .{args.len});
    return lookupGenVar(allocator, "__gen-bytes");
}

fn chooseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to choose", .{args.len});
    const helper = Value.initBuiltinFn(&chooseHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0], args[1] });
    return makeGen(allocator, closure);
}

fn chooseHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [lower, upper, _size]
    if (args.len != 3) return error.ArityError;
    const lower = args[0].asInteger();
    const upper = args[1].asInteger();
    const range = 1 + upper - lower;
    const r = (try callCore(allocator, "rand-int", &.{Value.initInteger(range)})).asInteger();
    return Value.initInteger(lower + r);
}

fn sampleFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sample", .{args.len});
    const gen = args[0];
    const n = if (args.len == 2) args[1].asInteger() else @as(i64, 10);
    const items = try allocator.alloc(Value, @intCast(n));
    for (0..@intCast(n)) |i| {
        items[i] = try generateFn(allocator, &.{ gen, Value.initInteger(@intCast(i + 1)) });
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

fn intWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to int", .{args.len});
    return lookupGenVar(allocator, "__gen-int");
}

fn doubleWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to double", .{args.len});
    return lookupGenVar(allocator, "__gen-double");
}

fn largeIntegerFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to large-integer", .{args.len});
    return largeIntegerStarFn(allocator, &.{try callCore(allocator, "hash-map", &.{})});
}

fn largeIntegerStarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to large-integer*", .{args.len});
    const opts = args[0];
    const mn = try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "min" }), Value.initInteger(-1000000) });
    const mx = try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "max" }), Value.initInteger(1000000) });
    return chooseFn(allocator, &.{ mn, mx });
}

fn doubleStarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to double*", .{args.len});
    const opts = args[0];
    const mn = try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "min" }), Value.initFloat(-1000.0) });
    const mx = try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "max" }), Value.initFloat(1000.0) });
    const helper = Value.initBuiltinFn(&doubleStarHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, mn, mx });
    return makeGen(allocator, closure);
}

fn doubleStarHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    // [min, max, _size]
    if (args.len != 3) return error.ArityError;
    const mn = args[0].asFloat();
    const mx = args[1].asFloat();
    const r = (try callCore(allocator, "rand", &.{})).asFloat();
    return Value.initFloat(mn + r * (mx - mn));
}

fn charWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char", .{args.len});
    return lookupGenVar(allocator, "__gen-char");
}

fn charAlphaWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char-alpha", .{args.len});
    return lookupGenVar(allocator, "__gen-char-alpha");
}

fn charAlphanumericWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char-alphanumeric", .{args.len});
    return lookupGenVar(allocator, "__gen-char-alphanumeric");
}

fn charAsciiWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char-ascii", .{args.len});
    return lookupGenVar(allocator, "__gen-char-ascii");
}

fn keywordWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keyword", .{args.len});
    return lookupGenVar(allocator, "__gen-keyword");
}

fn keywordNsWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keyword-ns", .{args.len});
    return lookupGenVar(allocator, "__gen-keyword-ns");
}

fn symbolWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to symbol", .{args.len});
    return lookupGenVar(allocator, "__gen-symbol");
}

fn symbolNsWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to symbol-ns", .{args.len});
    return lookupGenVar(allocator, "__gen-symbol-ns");
}

fn stringWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to string", .{args.len});
    return lookupGenVar(allocator, "__gen-string");
}

fn stringAlphanumericWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to string-alphanumeric", .{args.len});
    return lookupGenVar(allocator, "__gen-string-alphanumeric");
}

fn stringAsciiWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to string-ascii", .{args.len});
    return lookupGenVar(allocator, "__gen-string-ascii");
}

fn ratioWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ratio", .{args.len});
    return lookupGenVar(allocator, "__gen-ratio");
}

fn uuidWrapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to uuid", .{args.len});
    return lookupGenVar(allocator, "__gen-uuid");
}

fn simpleTypeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to simple-type", .{args.len});
    return lookupGenVar(allocator, "__gen-simple-type");
}

fn simpleTypePrintableFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to simple-type-printable", .{args.len});
    return lookupGenVar(allocator, "__gen-simple-type-printable");
}

fn anyPrintableFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to any-printable", .{args.len});
    return lookupGenVar(allocator, "__gen-any-printable");
}

fn anyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to any", .{args.len});
    return lookupGenVar(allocator, "__gen-any");
}

// ============================================================
// Layer 6-7: Metaprogramming + stubs
// ============================================================

fn delayImplFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to delay-impl", .{args.len});
    // gfnd is a delay wrapping a generator
    const helper = Value.initBuiltinFn(&delayImplHelper);
    const closure = try callCore(allocator, "partial", &.{ helper, args[0] });
    return makeGen(allocator, closure);
}

fn delayImplHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const gen = try callCore(allocator, "deref", &.{args[0]});
    return callGen(allocator, gen, args[1]);
}

fn genForNameFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to gen-for-name", .{args.len});
    const s = args[0];
    const ns_sym = try callCore(allocator, "symbol", &.{try callCore(allocator, "namespace", &.{s})});
    _ = try callCore(allocator, "require", &.{ns_sym});
    const v = try callCore(allocator, "resolve", &.{s});
    if (v.tag() == .nil) {
        return callCore(allocator, "throw", &.{
            try callCore(allocator, "ex-info", &.{
                try callCore(allocator, "str", &.{ Value.initString(allocator, "Var "), s, Value.initString(allocator, " is not on the classpath") }),
                try callCore(allocator, "hash-map", &.{}),
            }),
        });
    }
    const val = try callCore(allocator, "deref", &.{v});
    const is_gen = try generatorQFn(allocator, &.{val});
    if (is_gen.tag() == .boolean and is_gen.asBoolean()) return val;
    return callCore(allocator, "throw", &.{
        try callCore(allocator, "ex-info", &.{
            try callCore(allocator, "str", &.{ Value.initString(allocator, "Var "), s, Value.initString(allocator, " is not a generator") }),
            try callCore(allocator, "hash-map", &.{}),
        }),
    });
}

/// (gen-for-pred pred) — lookup predicate → generator mapping
fn genForPredFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to gen-for-pred", .{args.len});
    const pred = args[0];
    // If pred is a set, return (elements pred)
    const is_set = try callCore(allocator, "set?", &.{pred});
    if (is_set.tag() == .boolean and is_set.asBoolean()) {
        return elementsFn(allocator, &.{pred});
    }
    // Lookup in __gen-builtins map
    const gen_builtins = try lookupGenVar(allocator, "__gen-builtins");
    return callCore(allocator, "get", &.{ gen_builtins, pred });
}

// No-op macros
fn lazyCombinatorMacro(_: Allocator, _: []const Value) anyerror!Value {
    return Value.nil_val;
}

fn lazyCombinatorsMacro(_: Allocator, _: []const Value) anyerror!Value {
    return Value.nil_val;
}

fn lazyPrimMacro(_: Allocator, _: []const Value) anyerror!Value {
    return Value.nil_val;
}

fn lazyPrimsMacro(_: Allocator, _: []const Value) anyerror!Value {
    return Value.nil_val;
}

// Stubs for quick-check / for-all*
fn quickCheckFn(allocator: Allocator, _: []const Value) anyerror!Value {
    return callCore(allocator, "throw", &.{
        try callCore(allocator, "ex-info", &.{
            Value.initString(allocator, "quick-check not implemented (requires test.check)"),
            try callCore(allocator, "hash-map", &.{}),
        }),
    });
}

fn forAllStarFn(allocator: Allocator, _: []const Value) anyerror!Value {
    return callCore(allocator, "throw", &.{
        try callCore(allocator, "ex-info", &.{
            Value.initString(allocator, "for-all* not implemented (requires test.check)"),
            try callCore(allocator, "hash-map", &.{}),
        }),
    });
}

// ============================================================
// Post-register: create private generators + gen-builtins map
// ============================================================

fn postRegister(allocator: Allocator, env: *Env) anyerror!void {
    const ns = env.findNamespace("clojure.spec.gen.alpha") orelse return;

    // Primitive gen fns
    const char_fn = Value.initBuiltinFn(&genCharImpl);
    const char_alpha_fn = Value.initBuiltinFn(&genCharAlphaImpl);
    const char_alphanum_fn = Value.initBuiltinFn(&genCharAlphanumImpl);
    const char_ascii_fn = Value.initBuiltinFn(&genCharAsciiImpl);

    // Build string gen fns using partial
    const str_helper = Value.initBuiltinFn(&genStringImpl);
    const str_fn = try callCore(allocator, "partial", &.{ str_helper, char_fn });
    const str_alphanum_fn = try callCore(allocator, "partial", &.{ str_helper, char_alphanum_fn });
    const str_ascii_fn = try callCore(allocator, "partial", &.{ str_helper, char_ascii_fn });

    // Build keyword/symbol gen fns using partial
    const kw_helper = Value.initBuiltinFn(&genKeywordImpl);
    const kw_ns_helper = Value.initBuiltinFn(&genKeywordNsImpl);
    const sym_helper = Value.initBuiltinFn(&genSymbolImpl);
    const sym_ns_helper = Value.initBuiltinFn(&genSymbolNsImpl);
    const kw_fn = try callCore(allocator, "partial", &.{ kw_helper, char_alpha_fn });
    const kw_ns_fn = try callCore(allocator, "partial", &.{ kw_ns_helper, char_alpha_fn });
    const sym_fn = try callCore(allocator, "partial", &.{ sym_helper, char_alpha_fn });
    const sym_ns_fn = try callCore(allocator, "partial", &.{ sym_ns_helper, char_alpha_fn });

    // Create primitive generators
    const gen_int = try makeGen(allocator, Value.initBuiltinFn(&genIntImpl));
    const gen_pos_int = try makeGen(allocator, Value.initBuiltinFn(&genPosIntImpl));
    const gen_nat = try makeGen(allocator, Value.initBuiltinFn(&genNatImpl));
    const gen_neg_int = try makeGen(allocator, Value.initBuiltinFn(&genNegIntImpl));
    const gen_boolean = try makeGen(allocator, Value.initBuiltinFn(&genBooleanImpl));
    const gen_char = try makeGen(allocator, char_fn);
    const gen_char_alpha = try makeGen(allocator, char_alpha_fn);
    const gen_char_alphanum = try makeGen(allocator, char_alphanum_fn);
    const gen_char_ascii = try makeGen(allocator, char_ascii_fn);
    const gen_string = try makeGen(allocator, str_fn);
    const gen_string_alphanum = try makeGen(allocator, str_alphanum_fn);
    const gen_string_ascii = try makeGen(allocator, str_ascii_fn);
    const gen_keyword = try makeGen(allocator, kw_fn);
    const gen_keyword_ns = try makeGen(allocator, kw_ns_fn);
    const gen_symbol = try makeGen(allocator, sym_fn);
    const gen_symbol_ns = try makeGen(allocator, sym_ns_fn);
    const gen_double = try makeGen(allocator, Value.initBuiltinFn(&genDoubleImpl));
    const gen_ratio = try makeGen(allocator, Value.initBuiltinFn(&genRatioImpl));
    const gen_uuid = try makeGen(allocator, Value.initBuiltinFn(&genUuidImpl));

    // Bytes generator
    const bytes_helper = Value.initBuiltinFn(&genBytesHelper);
    const gen_bytes = try makeGen(allocator, bytes_helper);

    // Bind all private generators to hidden vars
    const bindings = [_]struct { name: []const u8, val: Value }{
        .{ .name = "__gen-int", .val = gen_int },
        .{ .name = "__gen-pos-int", .val = gen_pos_int },
        .{ .name = "__gen-nat", .val = gen_nat },
        .{ .name = "__gen-neg-int", .val = gen_neg_int },
        .{ .name = "__gen-boolean", .val = gen_boolean },
        .{ .name = "__gen-char", .val = gen_char },
        .{ .name = "__gen-char-alpha", .val = gen_char_alpha },
        .{ .name = "__gen-char-alphanumeric", .val = gen_char_alphanum },
        .{ .name = "__gen-char-ascii", .val = gen_char_ascii },
        .{ .name = "__gen-string", .val = gen_string },
        .{ .name = "__gen-string-alphanumeric", .val = gen_string_alphanum },
        .{ .name = "__gen-string-ascii", .val = gen_string_ascii },
        .{ .name = "__gen-keyword", .val = gen_keyword },
        .{ .name = "__gen-keyword-ns", .val = gen_keyword_ns },
        .{ .name = "__gen-symbol", .val = gen_symbol },
        .{ .name = "__gen-symbol-ns", .val = gen_symbol_ns },
        .{ .name = "__gen-double", .val = gen_double },
        .{ .name = "__gen-ratio", .val = gen_ratio },
        .{ .name = "__gen-uuid", .val = gen_uuid },
        .{ .name = "__gen-bytes", .val = gen_bytes },
    };
    for (bindings) |b| {
        const v = try ns.intern(b.name);
        v.bindRoot(b.val);
    }

    // Composite generators that depend on the primitives
    const gen_simple_type = try oneOfFn(allocator, &.{
        try callCore(allocator, "vector", &.{ gen_int, try largeIntegerFn(allocator, &.{}), gen_double, gen_char, gen_string, gen_boolean, gen_keyword, gen_keyword_ns, gen_symbol, gen_symbol_ns, gen_uuid }),
    });
    const gen_simple_type_printable = try oneOfFn(allocator, &.{
        try callCore(allocator, "vector", &.{ gen_int, try largeIntegerFn(allocator, &.{}), gen_double, gen_char_alphanum, gen_string_alphanum, gen_boolean, gen_keyword, gen_keyword_ns, gen_symbol, gen_symbol_ns, gen_uuid }),
    });

    const stp_var = try ns.intern("__gen-simple-type");
    stp_var.bindRoot(gen_simple_type);
    const stpp_var = try ns.intern("__gen-simple-type-printable");
    stpp_var.bindRoot(gen_simple_type_printable);

    // any-printable and any need vector/set/map generators built from the simples
    const gen_any_printable = try oneOfFn(allocator, &.{
        try callCore(allocator, "vector", &.{
            gen_int,
            try largeIntegerFn(allocator, &.{}),
            gen_double,
            gen_char_alphanum,
            gen_string_alphanum,
            gen_boolean,
            gen_keyword,
            gen_keyword_ns,
            gen_symbol,
            gen_symbol_ns,
            try returnFn(allocator, &.{Value.nil_val}),
            gen_uuid,
            try vectorFn(allocator, &.{ gen_simple_type_printable, Value.initInteger(0), Value.initInteger(5) }),
            try setFn(allocator, &.{gen_simple_type_printable}),
            try mapFn(allocator, &.{ gen_keyword, gen_simple_type_printable }),
        }),
    });
    const gen_any = try oneOfFn(allocator, &.{
        try callCore(allocator, "vector", &.{
            gen_int,
            try largeIntegerFn(allocator, &.{}),
            gen_double,
            gen_char,
            gen_string,
            gen_boolean,
            gen_keyword,
            gen_keyword_ns,
            gen_symbol,
            gen_symbol_ns,
            try returnFn(allocator, &.{Value.nil_val}),
            gen_uuid,
            try vectorFn(allocator, &.{ gen_simple_type, Value.initInteger(0), Value.initInteger(5) }),
            try setFn(allocator, &.{gen_simple_type}),
            try mapFn(allocator, &.{ gen_keyword, gen_simple_type }),
        }),
    });

    const ap_var = try ns.intern("__gen-any-printable");
    ap_var.bindRoot(gen_any_printable);
    const a_var = try ns.intern("__gen-any");
    a_var.bindRoot(gen_any);

    // Build gen-builtins map: predicate fn → generator
    // Resolve predicates from clojure.core
    const core_ns = env.findNamespace("clojure.core") orelse return;
    const preds = [_]struct { name: []const u8, gen: Value }{
        .{ .name = "integer?", .gen = gen_int },
        .{ .name = "int?", .gen = gen_int },
        .{ .name = "pos-int?", .gen = gen_pos_int },
        .{ .name = "neg-int?", .gen = gen_neg_int },
        .{ .name = "nat-int?", .gen = gen_nat },
        .{ .name = "float?", .gen = gen_double },
        .{ .name = "double?", .gen = gen_double },
        .{ .name = "number?", .gen = gen_int },
        .{ .name = "ratio?", .gen = gen_ratio },
        .{ .name = "string?", .gen = gen_string },
        .{ .name = "keyword?", .gen = gen_keyword },
        .{ .name = "simple-keyword?", .gen = gen_keyword },
        .{ .name = "qualified-keyword?", .gen = gen_keyword_ns },
        .{ .name = "symbol?", .gen = gen_symbol },
        .{ .name = "simple-symbol?", .gen = gen_symbol },
        .{ .name = "qualified-symbol?", .gen = gen_symbol_ns },
        .{ .name = "char?", .gen = gen_char },
        .{ .name = "boolean?", .gen = gen_boolean },
        .{ .name = "ident?", .gen = gen_keyword },
        .{ .name = "qualified-ident?", .gen = gen_keyword_ns },
        .{ .name = "simple-ident?", .gen = gen_keyword },
    };

    // Start with an empty hash-map and assoc each pred→gen pair
    var gen_builtins_map = try callCore(allocator, "hash-map", &.{});
    for (preds) |p| {
        if (core_ns.mappings.get(p.name)) |pred_var| {
            gen_builtins_map = try callCore(allocator, "assoc", &.{ gen_builtins_map, pred_var.deref(), p.gen });
        }
    }
    // Add special constant generators
    const zero_gen = try returnFn(allocator, &.{Value.initInteger(0)});
    const true_gen = try returnFn(allocator, &.{Value.true_val});
    const false_gen = try returnFn(allocator, &.{Value.false_val});
    const nil_gen = try returnFn(allocator, &.{Value.nil_val});
    const empty_gen = try returnFn(allocator, &.{try callCore(allocator, "vector", &.{})});
    const not_empty_gen = try vectorFn(allocator, &.{ gen_int, Value.initInteger(1), Value.initInteger(5) });
    const special_preds = [_]struct { name: []const u8, gen: Value }{
        .{ .name = "zero?", .gen = zero_gen },
        .{ .name = "true?", .gen = true_gen },
        .{ .name = "false?", .gen = false_gen },
        .{ .name = "nil?", .gen = nil_gen },
        .{ .name = "some?", .gen = gen_int },
        .{ .name = "any?", .gen = gen_int },
        .{ .name = "empty?", .gen = empty_gen },
        .{ .name = "pos?", .gen = gen_pos_int },
        .{ .name = "neg?", .gen = gen_neg_int },
    };
    for (special_preds) |p| {
        if (core_ns.mappings.get(p.name)) |pred_var| {
            gen_builtins_map = try callCore(allocator, "assoc", &.{ gen_builtins_map, pred_var.deref(), p.gen });
        }
    }

    // Collection predicate generators
    const coll_gen = try vectorFn(allocator, &.{gen_int});
    const list_gen = try fmapFn(allocator, &.{ try resolveCore("list*"), try vectorFn(allocator, &.{ gen_int, Value.initInteger(0), Value.initInteger(5) }) });
    const vec_gen = try vectorFn(allocator, &.{ gen_int, Value.initInteger(0), Value.initInteger(5) });
    const map_gen = try mapFn(allocator, &.{ gen_keyword, gen_int });
    const set_gen = try setFn(allocator, &.{gen_int});
    const seq_gen = try fmapFn(allocator, &.{ try resolveCore("seq"), try vectorFn(allocator, &.{ gen_int, Value.initInteger(1), Value.initInteger(5) }) });
    const sorted_gen = try fmapFn(allocator, &.{ try resolveCore("sorted-set"), try vectorFn(allocator, &.{ gen_int, Value.initInteger(0), Value.initInteger(5) }) });
    const coll_preds = [_]struct { name: []const u8, gen: Value }{
        .{ .name = "coll?", .gen = coll_gen },
        .{ .name = "list?", .gen = list_gen },
        .{ .name = "vector?", .gen = vec_gen },
        .{ .name = "map?", .gen = map_gen },
        .{ .name = "set?", .gen = set_gen },
        .{ .name = "seq?", .gen = seq_gen },
        .{ .name = "seqable?", .gen = vec_gen },
        .{ .name = "sequential?", .gen = vec_gen },
        .{ .name = "associative?", .gen = vec_gen },
        .{ .name = "sorted?", .gen = sorted_gen },
        .{ .name = "counted?", .gen = vec_gen },
        .{ .name = "reversible?", .gen = vec_gen },
        .{ .name = "indexed?", .gen = vec_gen },
        .{ .name = "not-empty", .gen = not_empty_gen },
    };
    for (coll_preds) |p| {
        if (core_ns.mappings.get(p.name)) |pred_var| {
            gen_builtins_map = try callCore(allocator, "assoc", &.{ gen_builtins_map, pred_var.deref(), p.gen });
        }
    }
    // even?/odd? generators
    if (core_ns.mappings.get("even?")) |pred_var| {
        const even_fn = Value.initBuiltinFn(&evenFmapHelper);
        const even_gen = try fmapFn(allocator, &.{ even_fn, gen_int });
        gen_builtins_map = try callCore(allocator, "assoc", &.{ gen_builtins_map, pred_var.deref(), even_gen });
    }
    if (core_ns.mappings.get("odd?")) |pred_var| {
        const odd_fn = Value.initBuiltinFn(&oddFmapHelper);
        const odd_gen = try fmapFn(allocator, &.{ odd_fn, gen_int });
        gen_builtins_map = try callCore(allocator, "assoc", &.{ gen_builtins_map, pred_var.deref(), odd_gen });
    }

    const gb_var = try ns.intern("__gen-builtins");
    gb_var.bindRoot(gen_builtins_map);
}

fn genBytesHelper(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const size = args[0].asInteger();
    const n = (try callCore(allocator, "rand-int", &.{Value.initInteger(size + 1)})).asInteger();
    // Return a vector of bytes (CW doesn't have byte arrays)
    const items = try allocator.alloc(Value, @intCast(n));
    for (0..@intCast(n)) |i| {
        const b = (try callCore(allocator, "rand-int", &.{Value.initInteger(256)})).asInteger() - 128;
        items[i] = Value.initInteger(b);
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

fn evenFmapHelper(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.initInteger(args[0].asInteger() * 2);
}

fn oddFmapHelper(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.initInteger(1 + args[0].asInteger() * 2);
}

// ============================================================
// Namespace definition
// ============================================================

const builtins_arr = [_]BuiltinDef{
    .{ .name = "make-gen", .func = &makeGenFn, .doc = "Create a generator from a function of size." },
    .{ .name = "generator?", .func = &generatorQFn, .doc = "Returns true if x is a generator." },
    .{ .name = "generate", .func = &generateFn, .doc = "Generate a single value from generator g, using optional size (default 30)." },
    .{ .name = "return", .func = &returnFn, .doc = "Generator that always returns val." },
    .{ .name = "fmap", .func = &fmapFn, .doc = "Create a generator that applies f to values from gen." },
    .{ .name = "bind", .func = &bindFn, .doc = "Create a generator that generates a value from gen, passes to f which returns a new gen." },
    .{ .name = "one-of", .func = &oneOfFn, .doc = "Create a generator that randomly chooses from the given generators." },
    .{ .name = "such-that", .func = &suchThatFn, .doc = "Create a generator that generates values satisfying pred." },
    .{ .name = "tuple", .func = &tupleFn, .doc = "Create a generator that generates vectors with values from each gen." },
    .{ .name = "frequency", .func = &frequencyFn, .doc = "Create a generator that chooses from [weight gen] pairs proportional to weight." },
    .{ .name = "hash-map", .func = &hashMapFn, .doc = "Create a generator from alternating key gen pairs." },
    .{ .name = "elements", .func = &elementsFn, .doc = "Create a generator that randomly chooses from coll." },
    .{ .name = "vector", .func = &vectorFn, .doc = "Create a generator that generates vectors of values from gen." },
    .{ .name = "vector-distinct", .func = &vectorDistinctFn, .doc = "Create a generator that generates vectors of distinct values." },
    .{ .name = "delay-gen", .func = &delayGenFn, .doc = "Helper for delay macro." },
    .{ .name = "list", .func = &listFn, .doc = "Like vector but generates lists." },
    .{ .name = "map", .func = &mapFn, .doc = "Create a generator that generates maps." },
    .{ .name = "set", .func = &setFn, .doc = "Like vector but generates sets." },
    .{ .name = "not-empty", .func = &notEmptyFn, .doc = "Wrap gen to retry if it generates an empty collection." },
    .{ .name = "cat", .func = &catFn, .doc = "Concatenate generators into a single generator." },
    .{ .name = "shuffle", .func = &shuffleFn, .doc = "Create a generator that shuffles coll." },
    .{ .name = "boolean", .func = &booleanFn, .doc = "Fn returning a generator of booleans." },
    .{ .name = "bytes", .func = &bytesFn, .doc = "Returns a generator for byte arrays." },
    .{ .name = "choose", .func = &chooseFn, .doc = "Generator that returns longs in [lower, upper] inclusive." },
    .{ .name = "sample", .func = &sampleFn, .doc = "Generate n (default 10) samples from generator." },
    .{ .name = "int", .func = &intWrapFn, .doc = "Fn returning a generator of ints." },
    .{ .name = "double", .func = &doubleWrapFn, .doc = "Fn returning a generator of doubles." },
    .{ .name = "large-integer", .func = &largeIntegerFn, .doc = "Fn returning a generator of large integers." },
    .{ .name = "large-integer*", .func = &largeIntegerStarFn, .doc = "Generator for large integers. opts: :min, :max" },
    .{ .name = "double*", .func = &doubleStarFn, .doc = "Generator for doubles. opts: :min, :max" },
    .{ .name = "char", .func = &charWrapFn, .doc = "Fn returning a generator of printable chars." },
    .{ .name = "char-alpha", .func = &charAlphaWrapFn, .doc = "Fn returning a generator of alpha chars." },
    .{ .name = "char-alphanumeric", .func = &charAlphanumericWrapFn, .doc = "Fn returning a generator of alphanumeric chars." },
    .{ .name = "char-ascii", .func = &charAsciiWrapFn, .doc = "Fn returning a generator of ASCII chars." },
    .{ .name = "keyword", .func = &keywordWrapFn, .doc = "Fn returning a generator of keywords." },
    .{ .name = "keyword-ns", .func = &keywordNsWrapFn, .doc = "Fn returning a generator of namespaced keywords." },
    .{ .name = "symbol", .func = &symbolWrapFn, .doc = "Fn returning a generator of symbols." },
    .{ .name = "symbol-ns", .func = &symbolNsWrapFn, .doc = "Fn returning a generator of namespaced symbols." },
    .{ .name = "string", .func = &stringWrapFn, .doc = "Fn returning a generator of strings." },
    .{ .name = "string-alphanumeric", .func = &stringAlphanumericWrapFn, .doc = "Fn returning a generator of alphanumeric strings." },
    .{ .name = "string-ascii", .func = &stringAsciiWrapFn, .doc = "Fn returning a generator of ASCII strings." },
    .{ .name = "ratio", .func = &ratioWrapFn, .doc = "Fn returning a generator of ratios." },
    .{ .name = "uuid", .func = &uuidWrapFn, .doc = "Fn returning a generator of UUIDs." },
    .{ .name = "simple-type", .func = &simpleTypeFn, .doc = "Fn returning a generator of simple types." },
    .{ .name = "simple-type-printable", .func = &simpleTypePrintableFn, .doc = "Fn returning a generator of simple printable types." },
    .{ .name = "any-printable", .func = &anyPrintableFn, .doc = "Fn returning a generator of any printable value." },
    .{ .name = "any", .func = &anyFn, .doc = "Fn returning a generator of any value." },
    .{ .name = "delay-impl", .func = &delayImplFn, .doc = "Implementation detail for delay." },
    .{ .name = "gen-for-name", .func = &genForNameFn, .doc = "Dynamically loads a generator named by symbol s." },
    .{ .name = "gen-for-pred", .func = &genForPredFn, .doc = "Given a predicate, returns a generator for values satisfying it." },
    .{ .name = "quick-check", .func = &quickCheckFn, .doc = "Not implemented (requires test.check)." },
    .{ .name = "for-all*", .func = &forAllStarFn, .doc = "Not implemented (requires test.check)." },
};

const macro_builtins = [_]BuiltinDef{
    .{ .name = "delay", .func = &delayMacro, .doc = "Create a generator that delays evaluation of body." },
    .{ .name = "lazy-combinator", .func = &lazyCombinatorMacro, .doc = "Implementation macro, do not call directly." },
    .{ .name = "lazy-combinators", .func = &lazyCombinatorsMacro, .doc = "Implementation macro, do not call directly." },
    .{ .name = "lazy-prim", .func = &lazyPrimMacro, .doc = "Implementation macro, do not call directly." },
    .{ .name = "lazy-prims", .func = &lazyPrimsMacro, .doc = "Implementation macro, do not call directly." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.spec.gen.alpha",
    .builtins = &builtins_arr,
    .macro_builtins = &macro_builtins,
    .loading = .lazy,
    .post_register = &postRegister,
};
