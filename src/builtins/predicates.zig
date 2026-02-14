// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Type predicate functions — nil?, number?, string?, etc.
//!
//! Simple type checks on Value tag. All take exactly 1 argument
//! and return a boolean.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Env = @import("../runtime/env.zig").Env;
const err = @import("../runtime/error.zig");
const collections = @import("../runtime/collections.zig");
const BigInt = collections.BigInt;
const misc_mod = @import("misc.zig");
const Ratio = collections.Ratio;
const interop_dispatch = @import("../interop/dispatch.zig");

/// Check if a value is a class instance with a given :__reify_type.
fn isClassInstance(v: Value, class_name: []const u8) bool {
    if (v.tag() != .map) return false;
    const reify_type = interop_dispatch.getReifyType(v) orelse return false;
    return std.mem.eql(u8, reify_type, class_name);
}

/// Runtime env for bound? resolution. Set by bootstrap.setupMacroEnv.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var current_env: ?*Env = null;

// ============================================================
// Implementations
// ============================================================

fn predicate(args: []const Value, comptime check: fn (Value) bool) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to predicate", .{args.len});
    return Value.initBoolean(check(args[0]));
}

fn isNil(v: Value) bool {
    return v.tag() == .nil;
}
fn isBoolean(v: Value) bool {
    return v.tag() == .boolean;
}
fn isNumber(v: Value) bool {
    return v.tag() == .integer or v.tag() == .float or v.tag() == .big_int or v.tag() == .big_decimal or v.tag() == .ratio;
}
fn isInteger(v: Value) bool {
    return v.tag() == .integer or v.tag() == .big_int;
}
fn isFloat(v: Value) bool {
    return v.tag() == .float;
}
fn isString(v: Value) bool {
    return v.tag() == .string;
}
fn isKeyword(v: Value) bool {
    return v.tag() == .keyword;
}
fn isSymbol(v: Value) bool {
    return v.tag() == .symbol;
}
fn isMap(v: Value) bool {
    return v.tag() == .map or v.tag() == .hash_map;
}
fn isVector(v: Value) bool {
    return v.tag() == .vector;
}
fn isSeq(v: Value) bool {
    return v.tag() == .list or v.tag() == .cons or v.tag() == .lazy_seq or v.tag() == .chunked_cons;
}
fn isFn(v: Value) bool {
    return v.tag() == .fn_val or v.tag() == .builtin_fn;
}
fn isSet(v: Value) bool {
    return v.tag() == .set;
}
fn isColl(v: Value) bool {
    return v.tag() == .list or v.tag() == .vector or v.tag() == .map or v.tag() == .hash_map or v.tag() == .set or
        v.tag() == .cons or v.tag() == .lazy_seq or v.tag() == .chunked_cons;
}
fn isList(v: Value) bool {
    return v.tag() == .list;
}
fn isChar(v: Value) bool {
    return v.tag() == .char;
}
fn isSequential(v: Value) bool {
    return v.tag() == .list or v.tag() == .vector or v.tag() == .cons or v.tag() == .lazy_seq or v.tag() == .chunked_cons;
}
fn isAssociative(v: Value) bool {
    return v.tag() == .map or v.tag() == .hash_map or v.tag() == .vector;
}
fn isIFn(v: Value) bool {
    return v.tag() == .fn_val or v.tag() == .builtin_fn or v.tag() == .keyword or v.tag() == .map or v.tag() == .hash_map or v.tag() == .set or v.tag() == .vector or v.tag() == .symbol;
}

// Builtin wrappers (matching BuiltinFn signature)

pub fn nilPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNil);
}
pub fn booleanPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isBoolean);
}
pub fn numberPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNumber);
}
pub fn integerPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isInteger);
}
pub fn floatPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isFloat);
}
pub fn stringPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isString);
}
pub fn keywordPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isKeyword);
}
pub fn symbolPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSymbol);
}
pub fn mapPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isMap);
}
pub fn vectorPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isVector);
}
pub fn seqPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSeq);
}
pub fn fnPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isFn);
}
pub fn setPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSet);
}
pub fn collPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isColl);
}
pub fn listPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isList);
}
pub fn intPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isInteger);
}
pub fn charPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isChar);
}
pub fn sequentialPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSequential);
}
pub fn associativePred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isAssociative);
}
pub fn ifnPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isIFn);
}

// Numeric predicates
fn isZero(v: Value) bool {
    return switch (v.tag()) {
        .integer => v.asInteger() == 0,
        .float => v.asFloat() == 0.0,
        .big_int => v.asBigInt().managed.toConst().eqlZero(),
        .big_decimal => v.asBigDecimal().toF64() == 0.0,
        .ratio => v.asRatio().numerator.managed.toConst().eqlZero(),
        else => false,
    };
}
fn isPos(v: Value) bool {
    return switch (v.tag()) {
        .integer => v.asInteger() > 0,
        .float => v.asFloat() > 0.0,
        .big_int => v.asBigInt().managed.isPositive() and !v.asBigInt().managed.toConst().eqlZero(),
        .big_decimal => v.asBigDecimal().toF64() > 0.0,
        .ratio => v.asRatio().numerator.managed.isPositive() and !v.asRatio().numerator.managed.toConst().eqlZero(),
        else => false,
    };
}
fn isNeg(v: Value) bool {
    return switch (v.tag()) {
        .integer => v.asInteger() < 0,
        .float => v.asFloat() < 0.0,
        .big_int => !v.asBigInt().managed.isPositive() and !v.asBigInt().managed.toConst().eqlZero(),
        .big_decimal => v.asBigDecimal().toF64() < 0.0,
        .ratio => !v.asRatio().numerator.managed.isPositive() and !v.asRatio().numerator.managed.toConst().eqlZero(),
        else => false,
    };
}
fn isEven(v: Value) bool {
    return switch (v.tag()) {
        .integer => @mod(v.asInteger(), 2) == 0,
        .big_int => v.asBigInt().managed.toConst().isEven(),
        else => false,
    };
}
fn isOdd(v: Value) bool {
    return switch (v.tag()) {
        .integer => @mod(v.asInteger(), 2) != 0,
        .big_int => v.asBigInt().managed.toConst().isOdd(),
        else => false,
    };
}

pub fn zeroPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isZero);
}
pub fn posPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isPos);
}
pub fn negPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNeg);
}
pub fn evenPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isEven);
}
pub fn oddPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isOdd);
}

// not is not a type predicate but a core function
pub fn notFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to not", .{args.len});
    return Value.initBoolean(!args[0].isTruthy());
}

/// (type x) — returns a keyword indicating the runtime type of x.
pub fn typeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to type", .{args.len});
    const name: []const u8 = switch (args[0].tag()) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .char => "char",
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => blk: {
            // Check for class instance (map with :__reify_type)
            const entries = args[0].asMap().entries;
            var idx: usize = 0;
            while (idx + 1 < entries.len) : (idx += 2) {
                if (@import("collections.zig").isReifyTypeKey(entries[idx])) {
                    if (entries[idx + 1].tag() == .string) {
                        break :blk entries[idx + 1].asString();
                    }
                }
            }
            break :blk "map";
        },
        .hash_map => "map",
        .set => "set",
        .fn_val, .builtin_fn => "function",
        .atom => "atom",
        .volatile_ref => "volatile",
        .regex => "regex",
        .protocol => "protocol",
        .protocol_fn => "protocol-fn",
        .multi_fn => "multi-fn",
        .lazy_seq => "lazy-seq",
        .cons => "cons",
        .var_ref => "var",
        .delay => "delay",
        .future => "future",
        .promise => "promise",
        .agent => "agent",
        .reduced => "reduced",
        .transient_vector => "transient-vector",
        .transient_map => "transient-map",
        .transient_set => "transient-set",
        .chunked_cons => "chunked-cons",
        .chunk_buffer => "chunk-buffer",
        .array_chunk => "array-chunk",
        .wasm_module => "wasm-module",
        .wasm_fn => "wasm-fn",
        .matcher => "matcher",
        .array => "array",
        .big_int => "big-int",
        .ratio => "ratio",
        .big_decimal => "big-decimal",
    };
    return Value.initKeyword(allocator, .{ .ns = null, .name = name });
}

/// (bound? & vars) — true if all vars have any bound value (root or thread-local).
/// Takes var refs (#'x). Also accepts symbols for backward compat (defonce).
pub fn boundPred(_: Allocator, args: []const Value) anyerror!Value {
    for (args) |arg| {
        if (arg.tag() == .var_ref) {
            // JVM-compatible: check if var has a root binding.
            // In our implementation intern+bindRoot are always paired,
            // so existing var_ref generally means bound.
            const v = arg.asVarRef();
            if (v.root.tag() == .nil and !v.dynamic) return Value.false_val;
        } else if (arg.tag() == .symbol) {
            // Backward compat: resolve symbol in current namespace.
            const sym_name = arg.asSymbol().name;
            const env = current_env orelse return Value.false_val;
            const ns = env.current_ns orelse return Value.false_val;
            _ = ns.resolve(sym_name) orelse return Value.false_val;
        } else {
            return err.setErrorFmt(.eval, .type_error, .{}, "bound? expects a Var or symbol, got {s}", .{@tagName(arg.tag())});
        }
    }
    return Value.true_val;
}

/// (__delay? x) — true if x is a Delay value.
pub fn delayPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __delay?", .{args.len});
    return Value.initBoolean(args[0].tag() == .delay);
}

/// (__delay-realized? x) — true if delay has been realized.
pub fn delayRealizedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __delay-realized?", .{args.len});
    if (args[0].tag() != .delay) return Value.false_val;
    return Value.initBoolean(args[0].asDelay().realized);
}

/// (__lazy-seq-realized? x) — true if lazy-seq has been realized.
pub fn lazySeqRealizedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __lazy-seq-realized?", .{args.len});
    if (args[0].tag() != .lazy_seq) return Value.false_val;
    return Value.initBoolean(args[0].asLazySeq().realized != null);
}

/// (__promise-realized? x) — true if promise has been delivered.
pub fn promiseRealizedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __promise-realized?", .{args.len});
    if (args[0].tag() != .promise) return Value.false_val;
    const thread_pool = @import("../runtime/thread_pool.zig");
    const p = args[0].asPromise();
    const sync: *thread_pool.FutureResult = @ptrCast(@alignCast(p.sync));
    return Value.initBoolean(sync.isDone());
}

/// (var? x) — true if x is a Var reference.
pub fn varPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to var?", .{args.len});
    return Value.initBoolean(args[0].tag() == .var_ref);
}

/// (var-get v) — returns the value of the Var.
pub fn varGetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to var-get", .{args.len});
    if (args[0].tag() != .var_ref) return err.setErrorFmt(.eval, .type_error, .{}, "var-get expects a Var, got {s}", .{@tagName(args[0].tag())});
    return args[0].asVarRef().deref();
}

/// (var-set v val) — sets the thread-local binding of the Var. Returns val.
/// Requires an active thread binding (via push-thread-bindings / binding).
pub fn varSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to var-set", .{args.len});
    if (args[0].tag() != .var_ref) return err.setErrorFmt(.eval, .type_error, .{}, "var-set expects a Var, got {s}", .{@tagName(args[0].tag())});
    try var_mod.setThreadBinding(args[0].asVarRef(), args[1]);
    return args[1];
}

/// (satisfies? protocol x) — true if x's type has an impl for the protocol.
pub fn satisfiesPred(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to satisfies?", .{args.len});
    if (args[0].tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "satisfies? expects a protocol, got {s}", .{@tagName(args[0].tag())});
    const protocol = args[0].asProtocol();
    const TreeWalk = @import("../evaluator/tree_walk.zig").TreeWalk;
    const type_key = Value.initString(allocator, TreeWalk.valueTypeKey(args[1]));
    return Value.initBoolean(protocol.impls.get(type_key) != null);
}

/// Map a symbol name (e.g. "String", "Integer") to its protocol type key.
fn mapSymbolToTypeKey(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "String")) return "string";
    if (std.mem.eql(u8, name, "Integer") or std.mem.eql(u8, name, "Long")) return "integer";
    if (std.mem.eql(u8, name, "Double") or std.mem.eql(u8, name, "Float")) return "float";
    if (std.mem.eql(u8, name, "Boolean")) return "boolean";
    if (std.mem.eql(u8, name, "nil")) return "nil";
    if (std.mem.eql(u8, name, "Keyword")) return "keyword";
    if (std.mem.eql(u8, name, "Symbol")) return "symbol";
    if (std.mem.eql(u8, name, "PersistentList") or std.mem.eql(u8, name, "List")) return "list";
    if (std.mem.eql(u8, name, "PersistentVector") or std.mem.eql(u8, name, "Vector")) return "vector";
    if (std.mem.eql(u8, name, "PersistentArrayMap") or std.mem.eql(u8, name, "Map")) return "map";
    if (std.mem.eql(u8, name, "PersistentHashSet") or std.mem.eql(u8, name, "Set")) return "set";
    if (std.mem.eql(u8, name, "Atom")) return "atom";
    if (std.mem.eql(u8, name, "Volatile")) return "volatile";
    if (std.mem.eql(u8, name, "Pattern")) return "regex";
    if (std.mem.eql(u8, name, "Character")) return "char";
    return name;
}

/// Map a Value's runtime type to its protocol type key string.
const valueTypeKey = @import("../evaluator/tree_walk.zig").TreeWalk.valueTypeKey;

/// (extenders protocol) — Returns a collection of types explicitly extended to protocol.
fn extendersFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to extenders", .{args.len});
    if (args[0].tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "extenders expects a protocol, got {s}", .{@tagName(args[0].tag())});
    const protocol = args[0].asProtocol();
    const impls = protocol.impls;
    if (impls.entries.len == 0) return Value.nil_val;
    // Return list of type keys (even indices)
    const count = impls.entries.len / 2;
    const vec = try allocator.create(value_mod.PersistentVector);
    const items = try allocator.alloc(Value, count);
    for (0..count) |i| {
        items[i] = impls.entries[i * 2];
    }
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (extends? protocol atype) — Returns true if atype has been extended to protocol.
fn extendsPred(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to extends?", .{args.len});
    if (args[0].tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "extends? expects a protocol as first arg, got {s}", .{@tagName(args[0].tag())});
    const protocol = args[0].asProtocol();
    // atype can be a symbol (e.g. String) or string (type key)
    const type_key = if (args[1].tag() == .symbol)
        mapSymbolToTypeKey(args[1].asSymbol().name)
    else if (args[1].tag() == .string)
        mapSymbolToTypeKey(args[1].asString())
    else
        return err.setErrorFmt(.eval, .type_error, .{}, "extends? expects a type (symbol or string), got {s}", .{@tagName(args[1].tag())});
    return Value.initBoolean(protocol.impls.getByStringKey(type_key) != null);
}

/// (find-protocol-impl protocol x) — Returns the method map for x's type, or nil.
fn findProtocolImplFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-protocol-impl", .{args.len});
    if (args[0].tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "find-protocol-impl expects a protocol, got {s}", .{@tagName(args[0].tag())});
    const protocol = args[0].asProtocol();
    const type_key = valueTypeKey(args[1]);
    return protocol.impls.getByStringKey(type_key) orelse Value.nil_val;
}

/// (find-protocol-method protocol method-keyword x) — Returns the method fn for x's type, or nil.
fn findProtocolMethodFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-protocol-method", .{args.len});
    if (args[0].tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "find-protocol-method expects a protocol, got {s}", .{@tagName(args[0].tag())});
    const protocol = args[0].asProtocol();
    const type_key = valueTypeKey(args[2]);
    const method_map_val = protocol.impls.getByStringKey(type_key) orelse return Value.nil_val;
    if (method_map_val.tag() != .map) return Value.nil_val;
    // Method key can be keyword or string
    const method_name = if (args[1].tag() == .keyword)
        args[1].asKeyword().name
    else if (args[1].tag() == .string)
        args[1].asString()
    else
        return err.setErrorFmt(.eval, .type_error, .{}, "find-protocol-method expects a keyword or string method name, got {s}", .{@tagName(args[1].tag())});
    return method_map_val.asMap().getByStringKey(method_name) orelse Value.nil_val;
}

/// (extend atype & proto+mmaps) — Extends protocol with implementations for atype.
/// Usage: (extend String IGreet {:greet (fn [s] (str "hi " s))} IFoo {:bar (fn [s] ...)})
fn extendFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to extend", .{args.len});
    if ((args.len - 1) % 2 != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "extend expects type followed by protocol/method-map pairs", .{});
    // First arg: type name (symbol or string)
    const type_key = if (args[0].tag() == .symbol)
        mapSymbolToTypeKey(args[0].asSymbol().name)
    else if (args[0].tag() == .string)
        mapSymbolToTypeKey(args[0].asString())
    else
        return err.setErrorFmt(.eval, .type_error, .{}, "extend expects a type name (symbol), got {s}", .{@tagName(args[0].tag())});

    // Process protocol/method-map pairs
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const proto_val = args[i];
        const mmap_val = args[i + 1];
        if (proto_val.tag() != .protocol) return err.setErrorFmt(.eval, .type_error, .{}, "extend expects a protocol, got {s}", .{@tagName(proto_val.tag())});
        if (mmap_val.tag() != .map and mmap_val.tag() != .hash_map)
            return err.setErrorFmt(.eval, .type_error, .{}, "extend expects a method map, got {s}", .{@tagName(mmap_val.tag())});

        const protocol = proto_val.asProtocol();

        // Convert keyword keys to string keys (protocol dispatch uses string method names)
        const src_entries = if (mmap_val.tag() == .map) mmap_val.asMap().entries else blk: {
            break :blk try mmap_val.asHashMap().toEntries(allocator);
        };
        const method_count = src_entries.len / 2;
        const new_entries = try allocator.alloc(Value, method_count * 2);
        for (0..method_count) |j| {
            const key = src_entries[j * 2];
            // Convert keyword :foo to string "foo"
            new_entries[j * 2] = if (key.tag() == .keyword)
                Value.initString(allocator, key.asKeyword().name)
            else if (key.tag() == .string)
                key
            else
                return err.setErrorFmt(.eval, .type_error, .{}, "extend method-map keys must be keywords or strings, got {s}", .{@tagName(key.tag())});
            new_entries[j * 2 + 1] = src_entries[j * 2 + 1];
        }
        const method_map = try allocator.create(value_mod.PersistentArrayMap);
        method_map.* = .{ .entries = new_entries };

        // Add method_map to protocol.impls for this type_key
        const type_key_val = Value.initString(allocator, type_key);
        const existing = protocol.impls.get(type_key_val);
        if (existing) |ex_val| {
            // Merge into existing method map
            const old_entries = if (ex_val.tag() == .map) ex_val.asMap().entries else &[_]Value{};
            // Build merged entries: old entries + new entries (new overrides old)
            var merged = std.ArrayList(Value).empty;
            // Add old entries not overridden by new
            var k: usize = 0;
            while (k < old_entries.len) : (k += 2) {
                var overridden = false;
                for (0..method_count) |j| {
                    if (old_entries[k].eql(new_entries[j * 2])) {
                        overridden = true;
                        break;
                    }
                }
                if (!overridden) {
                    try merged.append(allocator, old_entries[k]);
                    try merged.append(allocator, old_entries[k + 1]);
                }
            }
            // Add all new entries
            try merged.appendSlice(allocator, new_entries);
            const merged_map = try allocator.create(value_mod.PersistentArrayMap);
            merged_map.* = .{ .entries = merged.items };
            // Update in-place
            const impls = protocol.impls;
            k = 0;
            while (k < impls.entries.len) : (k += 2) {
                if (impls.entries[k].eql(type_key_val)) {
                    @constCast(impls.entries)[k + 1] = Value.initMap(merged_map);
                    break;
                }
            }
        } else {
            // New type — add to impls
            const old_impls = protocol.impls;
            const new_impls_entries = try allocator.alloc(Value, old_impls.entries.len + 2);
            @memcpy(new_impls_entries[0..old_impls.entries.len], old_impls.entries);
            new_impls_entries[old_impls.entries.len] = type_key_val;
            new_impls_entries[old_impls.entries.len + 1] = Value.initMap(method_map);
            const new_impls = try allocator.create(value_mod.PersistentArrayMap);
            new_impls.* = .{ .entries = new_impls_entries };
            protocol.impls = new_impls;
        }
    }
    return Value.nil_val;
}

// ============================================================
// Hash & identity functions
// ============================================================

/// (hash x) — returns the hash code of x.
pub fn hashFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash", .{args.len});
    // For seqable types that computeHash can't handle (lazy-seq, cons with lazy rest),
    // realize and walk via seq operations
    const v = args[0];
    const tag = v.tag();
    if (tag == .lazy_seq or tag == .cons or tag == .chunked_cons) {
        const collections_mod = @import("collections.zig");
        var h: i32 = 1;
        var n: i32 = 0;
        var s = try collections_mod.seqFn(allocator, &.{v});
        while (!s.isNil()) {
            const first = try collections_mod.firstFn(allocator, &.{s});
            h = h *% 31 +% @as(i32, @truncate(computeHash(first)));
            n += 1;
            s = try collections_mod.restFn(allocator, &.{s});
            s = try collections_mod.seqFn(allocator, &.{s});
        }
        return Value.initInteger(@as(i64, misc_mod.mixCollHash(h, n)));
    }
    return Value.initInteger(computeHash(v));
}

pub fn computeHash(v: Value) i64 {
    return switch (v.tag()) {
        .nil => 0,
        .boolean => if (v.asBoolean()) @as(i64, 1231) else @as(i64, 1237),
        .integer => v.asInteger(),
        .float => @as(i64, @bitCast(@as(u64, @bitCast(v.asFloat())))),
        .big_int => blk: {
            const bi = v.asBigInt();
            // If fits in i64, use same hash as integer for consistency
            if (bi.toI64()) |i| break :blk i;
            // Otherwise hash the limbs
            var h: i64 = 0x9e3779b9;
            const c = bi.managed.toConst();
            for (c.limbs[0..c.limbs.len]) |limb| {
                h = h *% 31 +% @as(i64, @bitCast(limb));
            }
            if (!c.positive) h = ~h;
            break :blk h;
        },
        .big_decimal => @as(i64, @intFromFloat(v.asBigDecimal().toF64() * 1000003)),
        .char => @as(i64, @intCast(v.asChar())),
        .string => stringHash(v.asString()),
        .keyword => blk: {
            const kw = v.asKeyword();
            var h: i64 = 0x9e3779b9;
            if (kw.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(kw.name);
            break :blk h;
        },
        .symbol => blk: {
            const sym = v.asSymbol();
            var h: i64 = 0x517cc1b7;
            if (sym.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(sym.name);
            break :blk h;
        },
        .vector => blk: {
            const items = v.asVector().items;
            var h: i32 = 1;
            for (items) |item| {
                h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, misc_mod.mixCollHash(h, @intCast(items.len)));
        },
        .list => blk: {
            const items = v.asList().items;
            var h: i32 = 1;
            for (items) |item| {
                h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, misc_mod.mixCollHash(h, @intCast(items.len)));
        },
        .map => blk: {
            const entries = v.asMap().entries;
            var h: i32 = 0;
            var i: usize = 0;
            while (i + 1 < entries.len) : (i += 2) {
                // Each map entry hashes as (hash-combine (hash k) (hash v))
                const kh: i32 = @truncate(computeHash(entries[i]));
                const vh: i32 = @truncate(computeHash(entries[i + 1]));
                // Map entry hash: key ^ val (consistent with Clojure's MapEntry hash)
                h +%= kh ^ vh;
            }
            break :blk @as(i64, misc_mod.mixCollHash(h, @intCast(entries.len / 2)));
        },
        .set => blk: {
            const items = v.asSet().items;
            var h: i32 = 0;
            for (items) |item| {
                h +%= @as(i32, @truncate(computeHash(item)));
            }
            break :blk @as(i64, misc_mod.mixCollHash(h, @intCast(items.len)));
        },
        .cons => blk: {
            // Ordered hash: walk cons chain
            var h: i32 = 1;
            var n: i32 = 0;
            var cur = v;
            while (true) {
                const tag = cur.tag();
                if (tag == .cons) {
                    const cell = cur.asCons();
                    h = h *% 31 +% @as(i32, @truncate(computeHash(cell.first)));
                    n += 1;
                    cur = cell.rest;
                } else if (tag == .list) {
                    for (cur.asList().items) |item| {
                        h = h *% 31 +% @as(i32, @truncate(computeHash(item)));
                        n += 1;
                    }
                    break;
                } else if (tag == .nil) {
                    break;
                } else {
                    // Unknown rest — fallback
                    break;
                }
            }
            break :blk @as(i64, misc_mod.mixCollHash(h, n));
        },
        .lazy_seq => blk: {
            // If realized, hash the realized value; otherwise fallback
            const ls = v.asLazySeq();
            if (ls.realized) |realized| {
                break :blk computeHash(realized);
            }
            break :blk 42;
        },
        else => 42,
    };
}

fn stringHash(s: []const u8) i64 {
    var h: i64 = 0;
    for (s) |c| {
        h = h *% 31 +% @as(i64, c);
    }
    return h;
}

/// (identical? x y) — tests if x and y are the same object.
pub fn identicalPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to identical?", .{args.len});
    const a = args[0];
    const b = args[1];

    const a_tag = a.tag();
    const b_tag = b.tag();
    if (a_tag != b_tag) return Value.false_val;

    const result: bool = switch (a_tag) {
        .nil => true,
        .boolean => a.asBoolean() == b.asBoolean(),
        .integer => a.asInteger() == b.asInteger(),
        .float => a.asFloat() == b.asFloat(),
        .char => a.asChar() == b.asChar(),
        .string => a.asString().ptr == b.asString().ptr and a.asString().len == b.asString().len,
        .keyword => std.mem.eql(u8, a.asKeyword().name, b.asKeyword().name) and eqlOptNs(a.asKeyword().ns, b.asKeyword().ns),
        .symbol => std.mem.eql(u8, a.asSymbol().name, b.asSymbol().name) and eqlOptNs(a.asSymbol().ns, b.asSymbol().ns),
        .vector => a.asVector() == b.asVector(),
        .list => a.asList() == b.asList(),
        .map => a.asMap() == b.asMap(),
        .set => a.asSet() == b.asSet(),
        .fn_val => a.asFn() == b.asFn(),
        .builtin_fn => a.asBuiltinFn() == b.asBuiltinFn(),
        .atom => a.asAtom() == b.asAtom(),
        else => false,
    };
    return Value.initBoolean(result);
}

fn eqlOptNs(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// (== x y & more) — numeric equality. Returns true if all nums are numerically equal.
/// All arguments must be numbers; otherwise throws TypeError.
pub fn numericEqFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ==", .{args.len});
    if (args.len == 1) return Value.true_val;

    for (args) |a| {
        if (a.tag() != .integer and a.tag() != .float) return err.setErrorFmt(.eval, .type_error, .{}, "== expects a number, got {s}", .{@tagName(a.tag())});
    }

    const first: f64 = if (args[0].tag() == .integer) @floatFromInt(args[0].asInteger()) else args[0].asFloat();
    for (args[1..]) |b| {
        const fb: f64 = if (b.tag() == .integer) @floatFromInt(b.asInteger()) else b.asFloat();
        if (first != fb) return Value.false_val;
    }
    return Value.true_val;
}

// ============================================================
// Reduced functions (early termination for reduce)
// ============================================================

const Reduced = value_mod.Reduced;

/// (reduced x) — wraps x so that reduce will terminate with the value x.
pub fn reducedFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reduced", .{args.len});
    const r = try allocator.create(Reduced);
    r.* = .{ .value = args[0] };
    return Value.initReduced(r);
}

/// (reduced? x) — returns true if x is the result of a call to reduced.
pub fn isReducedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reduced?", .{args.len});
    return Value.initBoolean(args[0].tag() == .reduced);
}

/// (unreduced x) — if x is reduced, returns the value that was wrapped, else returns x.
pub fn unreducedFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unreduced", .{args.len});
    return switch (args[0].tag()) {
        .reduced => args[0].asReduced().value,
        else => args[0],
    };
}

/// (ensure-reduced x) — if x is already reduced, returns it, else wraps in reduced.
pub fn ensureReducedFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ensure-reduced", .{args.len});
    if (args[0].tag() == .reduced) return args[0];
    const r = try allocator.create(Reduced);
    r.* = .{ .value = args[0] };
    return Value.initReduced(r);
}

// ============================================================
// Collection type predicates
// ============================================================

/// (seqable? x) — Returns true if (seq x) would succeed.
fn seqablePred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to seqable?", .{args.len});
    return Value.initBoolean(switch (args[0].tag()) {
        .nil, .list, .vector, .map, .set, .string, .cons, .lazy_seq => true,
        else => false,
    });
}

/// (counted? x) — Returns true if (count x) is O(1).
fn countedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to counted?", .{args.len});
    return Value.initBoolean(switch (args[0].tag()) {
        .list, .vector, .map, .set, .string => true,
        else => false,
    });
}

/// (indexed? x) — Returns true if coll supports nth in O(1).
fn indexedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to indexed?", .{args.len});
    return Value.initBoolean(switch (args[0].tag()) {
        .vector, .string => true,
        else => false,
    });
}

/// (reversible? x) — Returns true if coll supports rseq.
fn reversiblePred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reversible?", .{args.len});
    return Value.initBoolean(args[0].tag() == .vector);
}

/// (sorted? x) — Returns true if coll implements Sorted.
fn sortedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to sorted?", .{args.len});
    return Value.initBoolean(switch (args[0].tag()) {
        .set => args[0].asSet().comparator != null,
        .map => args[0].asMap().comparator != null,
        else => false,
    });
}

/// (record? x) — Returns true if x is a record (map with :__reify_type key whose value is a string).
fn recordPred(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to record?", .{args.len});
    // CW records are maps with a :__reify_type string key (set by defrecord)
    const tag = args[0].tag();
    if (tag == .map) {
        const m = args[0].asMap();
        const key = Value.initKeyword(allocator, .{ .ns = null, .name = "__reify_type" });
        if (m.get(key)) |v| {
            return Value.initBoolean(v.tag() == .string);
        }
    } else if (tag == .hash_map) {
        const m = args[0].asHashMap();
        const key = Value.initKeyword(allocator, .{ .ns = null, .name = "__reify_type" });
        if (m.get(key)) |v| {
            return Value.initBoolean(v.tag() == .string);
        }
    }
    return Value.false_val;
}

/// (ratio? x) — Returns true if x is a Ratio.
fn ratioPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ratio?", .{args.len});
    return Value.initBoolean(args[0].tag() == .ratio);
}

/// (rational? x) — Returns true if x is a rational number.
fn rationalPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rational?", .{args.len});
    return Value.initBoolean(args[0].tag() == .integer or args[0].tag() == .big_int or args[0].tag() == .ratio);
}

/// (numerator r) — Returns the numerator part of a Ratio.
fn numeratorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to numerator", .{args.len});
    if (args[0].tag() != .ratio) return err.setErrorFmt(.eval, .type_error, .{}, "numerator requires a Ratio, got {s}", .{@tagName(args[0].tag())});
    const ratio = args[0].asRatio();
    if (ratio.numerator.toI64()) |i| return Value.initInteger(i);
    return Value.initBigInt(ratio.numerator);
}

/// (denominator r) — Returns the denominator part of a Ratio.
fn denominatorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to denominator", .{args.len});
    if (args[0].tag() != .ratio) return err.setErrorFmt(.eval, .type_error, .{}, "denominator requires a Ratio, got {s}", .{@tagName(args[0].tag())});
    const ratio = args[0].asRatio();
    if (ratio.denominator.toI64()) |i| return Value.initInteger(i);
    return Value.initBigInt(ratio.denominator);
}

/// (rationalize num) — Returns the rational value of num.
fn rationalizeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rationalize", .{args.len});
    return switch (args[0].tag()) {
        .integer, .big_int, .ratio => args[0],
        .float => blk: {
            const f = args[0].asFloat();
            if (std.math.isNan(f) or std.math.isInf(f))
                return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Cannot rationalize NaN or Infinity", .{});
            // Simple approach: if it's an exact integer, return integer
            const truncated = @trunc(f);
            if (f == truncated) {
                const i: i48 = @intFromFloat(truncated);
                break :blk Value.initInteger(i);
            }
            // For non-integer floats, return as-is (Java uses continued fractions
            // but Clojure's rationalize on a double returns the exact rational
            // representation — we simplify to return the float unchanged)
            break :blk args[0];
        },
        .big_decimal => blk: {
            // BigDecimal → exact rational: unscaled * 10^(-scale)
            const bd = args[0].asBigDecimal();
            if (bd.scale == 0) {
                if (bd.unscaled.toI64()) |i| break :blk Value.initInteger(i);
                break :blk Value.initBigInt(bd.unscaled);
            }
            // Return as BigDecimal for now (proper Ratio conversion would need
            // to compute unscaled / 10^scale as a Ratio)
            break :blk args[0];
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot rationalize {s}", .{@tagName(args[0].tag())}),
    };
}

/// (decimal? x) — Returns true if x is a BigDecimal.
fn decimalPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to decimal?", .{args.len});
    return Value.initBoolean(args[0].tag() == .big_decimal);
}

/// (uri? x) — Returns true if x is a java.net.URI.
fn uriPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to uri?", .{args.len});
    return Value.initBoolean(isClassInstance(args[0], "java.net.URI"));
}

/// (uuid? x) — Returns true if x is a java.util.UUID.
fn uuidPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to uuid?", .{args.len});
    // No UUID type in ClojureWasm
    return Value.false_val;
}

/// (bounded-count n coll) — If coll is counted? returns its count, else counts up to n.
fn boundedCountFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bounded-count", .{args.len});
    const limit = switch (args[0].tag()) {
        .integer => blk: {
            const i = args[0].asInteger();
            break :blk if (i >= 0) @as(usize, @intCast(i)) else return err.setErrorFmt(.eval, .arithmetic_error, .{}, "bounded-count limit must be non-negative, got {d}", .{i});
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "bounded-count expects integer limit, got {s}", .{@tagName(args[0].tag())}),
    };
    const coll = args[1];
    // Counted collections: return count directly
    const count: usize = switch (coll.tag()) {
        .nil => 0,
        .list => coll.asList().items.len,
        .vector => coll.asVector().items.len,
        .map => coll.asMap().entries.len / 2,
        .set => coll.asSet().items.len,
        .string => coll.asString().len,
        .cons => blk: {
            // Walk cons chain up to limit
            var n: usize = 0;
            var cur = coll;
            while (n < limit) : (n += 1) {
                switch (cur.tag()) {
                    .cons => cur = cur.asCons().rest,
                    .nil => break,
                    else => {
                        n += 1;
                        break;
                    },
                }
            }
            break :blk n;
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "bounded-count expects a collection, got {s}", .{@tagName(coll.tag())}),
    };
    return Value.initInteger(@intCast(@min(count, limit)));
}

/// (special-symbol? s) — Returns true if s names a special form.
fn specialSymbolPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to special-symbol?", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return Value.false_val,
    };
    const specials = [_][]const u8{
        "def",     "loop*",   "recur",     "if",        "case*",
        "let*",    "letfn*",  "do",        "fn*",       "quote",
        "var",     "import*", "set!",      "try",       "catch",
        "throw",   "finally", "deftype*",  "reify*",    "new",
        ".",       "&",       "defmacro",
    };
    for (&specials) |s| {
        if (std.mem.eql(u8, name, s)) return Value.true_val;
    }
    return Value.false_val;
}

/// (__instance? class-name-string value) — Java class compatibility layer.
/// Maps Java class names to CW type checks. Used by analyzer rewrite of (instance? Class x).
fn instanceCheckFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __instance?", .{args.len});
    const x = args[1];
    const tag = x.tag();

    // Keyword-based type check (CW-specific: (instance? :integer 42))
    if (args[0].tag() == .keyword) {
        const type_kw = args[0].asKeyword().name;
        const type_name: []const u8 = switch (tag) {
            .nil => "nil",
            .boolean => "boolean",
            .integer => "integer",
            .float => "float",
            .string => "string",
            .keyword => "keyword",
            .symbol => "symbol",
            .list => "list",
            .vector => "vector",
            .map, .hash_map => "map",
            .set => "set",
            .fn_val, .builtin_fn => "function",
            else => "",
        };
        return Value.initBoolean(std.mem.eql(u8, type_kw, type_name));
    }

    if (args[0].tag() != .string) return Value.false_val;
    const class_name = args[0].asString();

    // Match Java class names to CW type tags
    if (std.mem.eql(u8, class_name, "String") or std.mem.eql(u8, class_name, "java.lang.String"))
        return Value.initBoolean(tag == .string);
    if (std.mem.eql(u8, class_name, "Boolean") or std.mem.eql(u8, class_name, "java.lang.Boolean"))
        return Value.initBoolean(tag == .boolean);
    if (std.mem.eql(u8, class_name, "Number") or std.mem.eql(u8, class_name, "java.lang.Number"))
        return Value.initBoolean(tag == .integer or tag == .float or tag == .big_int or tag == .big_decimal or tag == .ratio);
    if (std.mem.eql(u8, class_name, "Long") or std.mem.eql(u8, class_name, "java.lang.Long") or
        std.mem.eql(u8, class_name, "Integer") or std.mem.eql(u8, class_name, "java.lang.Integer"))
        return Value.initBoolean(tag == .integer);
    if (std.mem.eql(u8, class_name, "Double") or std.mem.eql(u8, class_name, "java.lang.Double") or
        std.mem.eql(u8, class_name, "Float") or std.mem.eql(u8, class_name, "java.lang.Float"))
        return Value.initBoolean(tag == .float);
    if (std.mem.eql(u8, class_name, "Character") or std.mem.eql(u8, class_name, "java.lang.Character"))
        return Value.initBoolean(tag == .char);

    // Clojure lang types
    if (std.mem.eql(u8, class_name, "clojure.lang.Keyword"))
        return Value.initBoolean(tag == .keyword);
    if (std.mem.eql(u8, class_name, "clojure.lang.Symbol"))
        return Value.initBoolean(tag == .symbol);
    if (std.mem.eql(u8, class_name, "clojure.lang.IPersistentMap") or
        std.mem.eql(u8, class_name, "clojure.lang.PersistentHashMap") or
        std.mem.eql(u8, class_name, "clojure.lang.PersistentArrayMap"))
        return Value.initBoolean(tag == .map or tag == .hash_map);
    if (std.mem.eql(u8, class_name, "clojure.lang.IPersistentVector") or
        std.mem.eql(u8, class_name, "clojure.lang.PersistentVector"))
        return Value.initBoolean(tag == .vector);
    if (std.mem.eql(u8, class_name, "clojure.lang.IPersistentSet") or
        std.mem.eql(u8, class_name, "clojure.lang.PersistentHashSet"))
        return Value.initBoolean(tag == .set);
    if (std.mem.eql(u8, class_name, "clojure.lang.IPersistentList") or
        std.mem.eql(u8, class_name, "clojure.lang.PersistentList"))
        return Value.initBoolean(tag == .list);
    if (std.mem.eql(u8, class_name, "clojure.lang.ISeq"))
        return Value.initBoolean(tag == .list or tag == .cons or tag == .lazy_seq or tag == .chunked_cons);
    if (std.mem.eql(u8, class_name, "clojure.lang.IFn") or
        std.mem.eql(u8, class_name, "clojure.lang.Fn") or
        std.mem.eql(u8, class_name, "clojure.lang.AFn"))
        return Value.initBoolean(tag == .fn_val or tag == .builtin_fn);
    if (std.mem.eql(u8, class_name, "clojure.lang.Atom"))
        return Value.initBoolean(tag == .atom);
    if (std.mem.eql(u8, class_name, "clojure.lang.Var"))
        return Value.initBoolean(tag == .var_ref);
    if (std.mem.eql(u8, class_name, "clojure.lang.Delay"))
        return Value.initBoolean(tag == .delay);
    if (std.mem.eql(u8, class_name, "clojure.lang.MapEntry"))
        return Value.initBoolean(tag == .vector); // MapEntry is a vector in CW
    if (std.mem.eql(u8, class_name, "clojure.lang.IEditableCollection"))
        return Value.initBoolean(tag == .map or tag == .hash_map or tag == .vector or tag == .set);
    if (std.mem.eql(u8, class_name, "clojure.lang.ITransientCollection"))
        return Value.initBoolean(tag == .transient_map or tag == .transient_vector or tag == .transient_set);
    if (std.mem.eql(u8, class_name, "clojure.lang.PersistentQueue"))
        return Value.false_val; // Not implemented in CW
    if (std.mem.eql(u8, class_name, "clojure.lang.LazySeq"))
        return Value.initBoolean(tag == .lazy_seq);

    // Java exception types — CW exceptions are maps with :__ex_info key
    if (std.mem.eql(u8, class_name, "Throwable") or std.mem.eql(u8, class_name, "java.lang.Throwable") or
        std.mem.eql(u8, class_name, "Exception") or std.mem.eql(u8, class_name, "java.lang.Exception") or
        std.mem.eql(u8, class_name, "RuntimeException") or std.mem.eql(u8, class_name, "java.lang.RuntimeException"))
    {
        if (tag == .map) {
            const m = x.asMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_info" });
            return Value.initBoolean(m.get(key) != null);
        } else if (tag == .hash_map) {
            const m = x.asHashMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_info" });
            return Value.initBoolean(m.get(key) != null);
        }
        return Value.false_val;
    }

    // Java utility types
    if (std.mem.eql(u8, class_name, "java.util.regex.Pattern"))
        return Value.initBoolean(tag == .regex);
    if (std.mem.eql(u8, class_name, "java.util.UUID"))
        return Value.false_val; // UUID not a distinct type in CW

    // Unknown class: return false
    return Value.false_val;
}

/// Check if an exception value matches a catch class name.
/// Used by try/catch to determine if a catch clause should handle an exception.
/// Implements Java exception hierarchy: Throwable > Exception > RuntimeException > specific types.
pub fn exceptionMatchesClass(ex_val: Value, class_name: []const u8) bool {
    // Throwable/Exception/RuntimeException/Error: catch ALL thrown values (including non-map raw values).
    // CW has a flat exception hierarchy — Error is treated as catch-all like Throwable.
    if (std.mem.eql(u8, class_name, "Throwable") or
        std.mem.eql(u8, class_name, "java.lang.Throwable") or
        std.mem.eql(u8, class_name, "Exception") or
        std.mem.eql(u8, class_name, "java.lang.Exception") or
        std.mem.eql(u8, class_name, "RuntimeException") or
        std.mem.eql(u8, class_name, "java.lang.RuntimeException") or
        std.mem.eql(u8, class_name, "Error") or
        std.mem.eql(u8, class_name, "java.lang.Error") or
        std.mem.eql(u8, class_name, "AssertionError") or
        std.mem.eql(u8, class_name, "java.lang.AssertionError"))
        return true;

    // For specific exception types, value must be an exception map (with __ex_info key)
    const is_exception = switch (ex_val.tag()) {
        .map => blk: {
            const m = ex_val.asMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_info" });
            break :blk m.get(key) != null;
        },
        .hash_map => blk: {
            const m = ex_val.asHashMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_info" });
            break :blk m.get(key) != null;
        },
        else => false,
    };
    if (!is_exception) return false;

    // Get the __ex_type from the exception (set by runtime errors)
    const ex_type: ?[]const u8 = switch (ex_val.tag()) {
        .map => blk: {
            const m = ex_val.asMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_type" });
            const v = m.get(key) orelse break :blk null;
            break :blk if (v.tag() == .string) v.asString() else null;
        },
        .hash_map => blk: {
            const m = ex_val.asHashMap();
            const key = Value.initKeyword(std.heap.page_allocator, .{ .ns = null, .name = "__ex_type" });
            const v = m.get(key) orelse break :blk null;
            break :blk if (v.tag() == .string) v.asString() else null;
        },
        else => null,
    };

    // ExceptionInfo: matches ex-info exceptions (no __ex_type)
    if (std.mem.eql(u8, class_name, "ExceptionInfo") or
        std.mem.eql(u8, class_name, "clojure.lang.ExceptionInfo"))
        return ex_type == null;

    // Specific exception type: exact match against __ex_type
    if (ex_type) |et| {
        return std.mem.eql(u8, et, class_name);
    }

    // No __ex_type means ex-info — doesn't match specific exception classes
    return false;
}

// ============================================================
// Java interop utility functions
// ============================================================

fn doubleIsNanFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Double/isNaN", .{args.len});
    const t = args[0].tag();
    if (t != .float) return Value.false_val;
    return Value.initBoolean(std.math.isNan(args[0].asFloat()));
}

fn doubleIsInfiniteFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Double/isInfinite", .{args.len});
    const t = args[0].tag();
    if (t != .float) return Value.false_val;
    return Value.initBoolean(std.math.isInf(args[0].asFloat()));
}

fn charIsDigitFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Character/isDigit", .{args.len});
    if (args[0].tag() != .char) return Value.false_val;
    const cp = args[0].asChar();
    return Value.initBoolean(cp >= '0' and cp <= '9');
}

fn charIsLetterFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Character/isLetter", .{args.len});
    if (args[0].tag() != .char) return Value.false_val;
    const cp = args[0].asChar();
    return Value.initBoolean((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z'));
}

fn charIsWhitespaceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Character/isWhitespace", .{args.len});
    if (args[0].tag() != .char) return Value.false_val;
    const cp = args[0].asChar();
    return Value.initBoolean(cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0C);
}

fn charIsUpperCaseFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Character/isUpperCase", .{args.len});
    if (args[0].tag() != .char) return Value.false_val;
    const cp = args[0].asChar();
    return Value.initBoolean(cp >= 'A' and cp <= 'Z');
}

fn charIsLowerCaseFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Character/isLowerCase", .{args.len});
    if (args[0].tag() != .char) return Value.false_val;
    const cp = args[0].asChar();
    return Value.initBoolean(cp >= 'a' and cp <= 'z');
}

fn parseBooleanFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Boolean/parseBoolean", .{args.len});
    if (args[0].tag() != .string) return Value.false_val;
    return Value.initBoolean(std.mem.eql(u8, args[0].asString(), "true"));
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "nil?", .func = &nilPred, .doc = "Returns true if x is nil, false otherwise.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "boolean?", .func = &booleanPred, .doc = "Return true if x is a Boolean.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "number?", .func = &numberPred, .doc = "Returns true if x is a Number.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "integer?", .func = &integerPred, .doc = "Return true if n is an integer.", .arglists = "([n])", .added = "1.9" },
    .{ .name = "float?", .func = &floatPred, .doc = "Returns true if n is a floating point number.", .arglists = "([n])", .added = "1.9" },
    .{ .name = "string?", .func = &stringPred, .doc = "Return true if x is a String.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "keyword?", .func = &keywordPred, .doc = "Return true if x is a Keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "symbol?", .func = &symbolPred, .doc = "Return true if x is a Symbol.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "map?", .func = &mapPred, .doc = "Return true if x implements IPersistentMap.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "vector?", .func = &vectorPred, .doc = "Return true if x implements IPersistentVector.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "seq?", .func = &seqPred, .doc = "Return true if x implements ISeq.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "fn?", .func = &fnPred, .doc = "Return true if x is a function.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "set?", .func = &setPred, .doc = "Returns true if x implements IPersistentSet.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "coll?", .func = &collPred, .doc = "Returns true if x implements IPersistentCollection.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "list?", .func = &listPred, .doc = "Returns true if x implements IPersistentList.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "int?", .func = &intPred, .doc = "Return true if x is a fixed precision integer.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "char?", .func = &charPred, .doc = "Return true if x is a Character.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "sequential?", .func = &sequentialPred, .doc = "Return true if coll implements Sequential.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "associative?", .func = &associativePred, .doc = "Returns true if coll implements Associative.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "ifn?", .func = &ifnPred, .doc = "Returns true if x implements IFn. Note that many data structures (e.g. sets and maps) implement IFn.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "zero?", .func = &zeroPred, .doc = "Returns true if num is zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "pos?", .func = &posPred, .doc = "Returns true if num is greater than zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "neg?", .func = &negPred, .doc = "Returns true if num is less than zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "even?", .func = &evenPred, .doc = "Returns true if n is even, throws an exception if n is not an integer.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "odd?", .func = &oddPred, .doc = "Returns true if n is odd, throws an exception if n is not an integer.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "not", .func = &notFn, .doc = "Returns true if x is logical false, false otherwise.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "satisfies?", .func = &satisfiesPred, .doc = "Returns true if x satisfies the protocol.", .arglists = "([protocol x])", .added = "1.2" },
    .{ .name = "extends?", .func = &extendsPred, .doc = "Returns true if atype has been extended to protocol.", .arglists = "([protocol atype])", .added = "1.2" },
    .{ .name = "extenders", .func = &extendersFn, .doc = "Returns a collection of the types explicitly extending protocol.", .arglists = "([protocol])", .added = "1.2" },
    .{ .name = "extend", .func = &extendFn, .doc = "Implementations of protocol methods can be provided using the extend construct.", .arglists = "([atype & proto+mmaps])", .added = "1.2" },
    .{ .name = "find-protocol-impl", .func = &findProtocolImplFn, .doc = "Returns the method map for value's type, or nil.", .arglists = "([protocol x])", .added = "1.2" },
    .{ .name = "find-protocol-method", .func = &findProtocolMethodFn, .doc = "Returns the method fn for value's type and method keyword, or nil.", .arglists = "([protocol methodk x])", .added = "1.2" },
    .{ .name = "type", .func = &typeFn, .doc = "Returns the type of x as a keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "class", .func = &typeFn, .doc = "Returns the type of x as a keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "bound?", .func = &boundPred, .doc = "Returns true if all of the vars provided as arguments have any bound value, root or thread-local.", .arglists = "([& vars])", .added = "1.2" },
    .{ .name = "var?", .func = &varPred, .doc = "Returns true if v is of type clojure.lang.Var.", .arglists = "([v])", .added = "1.0" },
    .{ .name = "var-get", .func = &varGetFn, .doc = "Gets the value in the var object.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "var-set", .func = &varSetFn, .doc = "Sets the value in the var object to val.", .arglists = "([x val])", .added = "1.0" },
    .{ .name = "hash", .func = &hashFn, .doc = "Returns the hash code of its argument. Note this is the hash code consistent with =, and thus is different than .hashCode for Integer, Short, Byte and Clojure collections.", .arglists = "([x])", .added = "1.6" },
    .{ .name = "identical?", .func = &identicalPred, .doc = "Tests if 2 arguments are the same object.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "==", .func = &numericEqFn, .doc = "Returns non-nil if nums all have the equivalent value, otherwise false.", .arglists = "([x] [x y] [x y & more])", .added = "1.0" },
    .{ .name = "reduced", .func = &reducedFn, .doc = "Wraps x in a way such that a reduce will terminate with the value x.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "reduced?", .func = &isReducedPred, .doc = "Returns true if x is the result of a call to reduced.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "unreduced", .func = &unreducedFn, .doc = "If x is reduced?, returns (deref x), else returns x.", .arglists = "([x])", .added = "1.7" },
    .{ .name = "ensure-reduced", .func = &ensureReducedFn, .doc = "If x is already reduced?, returns it, else returns (reduced x).", .arglists = "([x])", .added = "1.7" },
    .{ .name = "seqable?", .func = &seqablePred, .doc = "Return true if the seq function is supported for x.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "counted?", .func = &countedPred, .doc = "Returns true if coll implements count in constant time.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "indexed?", .func = &indexedPred, .doc = "Return true if coll implements Indexed, indicating efficient lookup by index.", .arglists = "([coll])", .added = "1.9" },
    .{ .name = "reversible?", .func = &reversiblePred, .doc = "Returns true if coll implements Reversible.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "sorted?", .func = &sortedPred, .doc = "Returns true if coll implements Sorted.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "record?", .func = &recordPred, .doc = "Returns true if x is a record.", .arglists = "([x])", .added = "1.6" },
    .{ .name = "ratio?", .func = &ratioPred, .doc = "Returns true if n is a Ratio.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "rational?", .func = &rationalPred, .doc = "Returns true if n is a rational number.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "numerator", .func = &numeratorFn, .doc = "Returns the numerator part of a Ratio.", .arglists = "([r])", .added = "1.2" },
    .{ .name = "denominator", .func = &denominatorFn, .doc = "Returns the denominator part of a Ratio.", .arglists = "([r])", .added = "1.2" },
    .{ .name = "rationalize", .func = &rationalizeFn, .doc = "Returns the rational value of num.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "decimal?", .func = &decimalPred, .doc = "Returns true if n is a BigDecimal.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "uri?", .func = &uriPred, .doc = "Return true if x is a java.net.URI.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "uuid?", .func = &uuidPred, .doc = "Return true if x is a java.util.UUID.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "bounded-count", .func = &boundedCountFn, .doc = "If coll is counted? returns its count, else will count at most the first n elements of coll.", .arglists = "([n coll])", .added = "1.9" },
    .{ .name = "special-symbol?", .func = &specialSymbolPred, .doc = "Returns true if s names a special form.", .arglists = "([s])", .added = "1.5" },
    .{ .name = "__delay?", .func = &delayPred, .doc = "Returns true if x is a Delay.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "__delay-realized?", .func = &delayRealizedPred, .doc = "Returns true if a delay has been realized.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "__lazy-seq-realized?", .func = &lazySeqRealizedPred, .doc = "Returns true if a lazy-seq has been realized.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "__promise-realized?", .func = &promiseRealizedPred, .doc = "Returns true if a promise has been delivered.", .arglists = "([x])", .added = "1.1" },
    .{ .name = "__instance?", .func = &instanceCheckFn, .doc = "Check if x is an instance of the named class.", .arglists = "([class-name x])", .added = "1.0" },
    .{ .name = "__double-is-nan", .func = &doubleIsNanFn, .doc = "Returns true if the specified number is NaN.", .arglists = "([v])", .added = "1.0" },
    .{ .name = "__double-is-infinite", .func = &doubleIsInfiniteFn, .doc = "Returns true if the specified number is infinitely large.", .arglists = "([v])", .added = "1.0" },
    .{ .name = "__char-is-digit", .func = &charIsDigitFn, .doc = "Determines if the specified character is a digit.", .arglists = "([ch])", .added = "1.0" },
    .{ .name = "__char-is-letter", .func = &charIsLetterFn, .doc = "Determines if the specified character is a letter.", .arglists = "([ch])", .added = "1.0" },
    .{ .name = "__char-is-whitespace", .func = &charIsWhitespaceFn, .doc = "Determines if the specified character is white space.", .arglists = "([ch])", .added = "1.0" },
    .{ .name = "__char-is-upper-case", .func = &charIsUpperCaseFn, .doc = "Determines if the specified character is an uppercase character.", .arglists = "([ch])", .added = "1.0" },
    .{ .name = "__char-is-lower-case", .func = &charIsLowerCaseFn, .doc = "Determines if the specified character is a lowercase character.", .arglists = "([ch])", .added = "1.0" },
    .{ .name = "__parse-boolean", .func = &parseBooleanFn, .doc = "Parses the string argument as a boolean.", .arglists = "([s])", .added = "1.0" },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "nil? predicate" {
    try testing.expectEqual(Value.true_val, try nilPred(test_alloc, &.{Value.nil_val}));
    try testing.expectEqual(Value.false_val, try nilPred(test_alloc, &.{Value.initInteger(1)}));
}

test "number? predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.true_val, try numberPred(alloc, &.{Value.initInteger(42)}));
    try testing.expectEqual(Value.true_val, try numberPred(alloc, &.{Value.initFloat(3.14)}));
    try testing.expectEqual(Value.false_val, try numberPred(alloc, &.{Value.initString(alloc, "hello")}));
}

test "string? predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.true_val, try stringPred(alloc, &.{Value.initString(alloc, "hi")}));
    try testing.expectEqual(Value.false_val, try stringPred(alloc, &.{Value.initInteger(1)}));
}

test "keyword? predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.true_val, try keywordPred(alloc, &.{Value.initKeyword(alloc, .{ .name = "a", .ns = null })}));
    try testing.expectEqual(Value.false_val, try keywordPred(alloc, &.{Value.initString(alloc, "a")}));
}

test "coll? predicate" {
    const items = [_]Value{};
    var lst = value_mod.PersistentList{ .items = &items };
    var vec = value_mod.PersistentVector{ .items = &items };
    try testing.expectEqual(Value.true_val, try collPred(test_alloc, &.{Value.initList(&lst)}));
    try testing.expectEqual(Value.true_val, try collPred(test_alloc, &.{Value.initVector(&vec)}));
    try testing.expectEqual(Value.false_val, try collPred(test_alloc, &.{Value.initInteger(1)}));
}

test "not function" {
    try testing.expectEqual(Value.true_val, try notFn(test_alloc, &.{Value.nil_val}));
    try testing.expectEqual(Value.true_val, try notFn(test_alloc, &.{Value.false_val}));
    try testing.expectEqual(Value.false_val, try notFn(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.false_val, try notFn(test_alloc, &.{Value.true_val}));
}

test "fn? predicate" {
    const f = value_mod.Fn{ .proto = @as(*const anyopaque, @ptrFromInt(1)), .closure_bindings = null };
    try testing.expectEqual(Value.true_val, try fnPred(test_alloc, &.{Value.initFn(&f)}));
    try testing.expectEqual(Value.false_val, try fnPred(test_alloc, &.{Value.initInteger(1)}));
}

test "zero? predicate" {
    try testing.expectEqual(Value.true_val, try zeroPred(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectEqual(Value.true_val, try zeroPred(test_alloc, &.{Value.initFloat(0.0)}));
    try testing.expectEqual(Value.false_val, try zeroPred(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.false_val, try zeroPred(test_alloc, &.{Value.initFloat(-0.5)}));
}

test "pos? predicate" {
    try testing.expectEqual(Value.true_val, try posPred(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.false_val, try posPred(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectEqual(Value.false_val, try posPred(test_alloc, &.{Value.initInteger(-1)}));
    try testing.expectEqual(Value.true_val, try posPred(test_alloc, &.{Value.initFloat(0.1)}));
}

test "neg? predicate" {
    try testing.expectEqual(Value.true_val, try negPred(test_alloc, &.{Value.initInteger(-1)}));
    try testing.expectEqual(Value.false_val, try negPred(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectEqual(Value.false_val, try negPred(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.true_val, try negPred(test_alloc, &.{Value.initFloat(-0.1)}));
}

test "even? predicate" {
    try testing.expectEqual(Value.true_val, try evenPred(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectEqual(Value.true_val, try evenPred(test_alloc, &.{Value.initInteger(2)}));
    try testing.expectEqual(Value.false_val, try evenPred(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.true_val, try evenPred(test_alloc, &.{Value.initInteger(-4)}));
}

test "odd? predicate" {
    try testing.expectEqual(Value.true_val, try oddPred(test_alloc, &.{Value.initInteger(1)}));
    try testing.expectEqual(Value.true_val, try oddPred(test_alloc, &.{Value.initInteger(-3)}));
    try testing.expectEqual(Value.false_val, try oddPred(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectEqual(Value.false_val, try oddPred(test_alloc, &.{Value.initInteger(2)}));
}

// --- hash tests ---

test "hash of integer returns itself" {
    const result = try hashFn(test_alloc, &.{Value.initInteger(42)});
    try testing.expect(result.tag() == .integer);
    try testing.expectEqual(@as(i64, 42), result.asInteger());
}

test "hash of nil returns 0" {
    const result = try hashFn(test_alloc, &.{Value.nil_val});
    try testing.expect(result.tag() == .integer);
    try testing.expectEqual(@as(i64, 0), result.asInteger());
}

test "hash of boolean" {
    const t = try hashFn(test_alloc, &.{Value.true_val});
    const f = try hashFn(test_alloc, &.{Value.false_val});
    try testing.expect(t.asInteger() != f.asInteger());
}

test "hash of string is deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const h1 = try hashFn(alloc, &.{Value.initString(alloc, "hello")});
    const h2 = try hashFn(alloc, &.{Value.initString(alloc, "hello")});
    try testing.expectEqual(h1.asInteger(), h2.asInteger());
}

test "hash of different strings differ" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const h1 = try hashFn(alloc, &.{Value.initString(alloc, "hello")});
    const h2 = try hashFn(alloc, &.{Value.initString(alloc, "world")});
    try testing.expect(h1.asInteger() != h2.asInteger());
}

test "hash arity check" {
    try testing.expectError(error.ArityError, hashFn(test_alloc, &.{}));
    try testing.expectError(error.ArityError, hashFn(test_alloc, &.{ Value.nil_val, Value.nil_val }));
}

// --- identical? tests ---

test "identical? same integer" {
    const result = try identicalPred(test_alloc, &.{ Value.initInteger(42), Value.initInteger(42) });
    try testing.expectEqual(Value.true_val, result);
}

test "identical? different integers" {
    const result = try identicalPred(test_alloc, &.{ Value.initInteger(1), Value.initInteger(2) });
    try testing.expectEqual(Value.false_val, result);
}

test "identical? different types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try identicalPred(alloc, &.{ Value.initInteger(1), Value.initString(alloc, "1") });
    try testing.expectEqual(Value.false_val, result);
}

test "identical? nil" {
    const result = try identicalPred(test_alloc, &.{ Value.nil_val, Value.nil_val });
    try testing.expectEqual(Value.true_val, result);
}

test "identical? same keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try identicalPred(alloc, &.{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
    });
    try testing.expectEqual(Value.true_val, result);
}

// --- == tests ---

test "== numeric equality integers" {
    const result = try numericEqFn(test_alloc, &.{ Value.initInteger(3), Value.initInteger(3) });
    try testing.expectEqual(Value.true_val, result);
}

test "== numeric cross-type" {
    const result = try numericEqFn(test_alloc, &.{ Value.initInteger(1), Value.initFloat(1.0) });
    try testing.expectEqual(Value.true_val, result);
}

test "== numeric inequality" {
    const result = try numericEqFn(test_alloc, &.{ Value.initInteger(1), Value.initInteger(2) });
    try testing.expectEqual(Value.false_val, result);
}

test "== non-numeric is error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectError(error.TypeError, numericEqFn(alloc, &.{ Value.initString(alloc, "a"), Value.initString(alloc, "a") }));
}

// --- reduced tests ---

test "reduced wraps a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try reducedFn(arena.allocator(), &.{Value.initInteger(42)});
    try testing.expect(result.tag() == .reduced);
    try testing.expect(result.asReduced().value.eql(Value.initInteger(42)));
}

test "reduced? returns true for reduced values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value.initInteger(1)});
    const result = try isReducedPred(test_alloc, &.{r});
    try testing.expectEqual(Value.true_val, result);
}

test "reduced? returns false for normal values" {
    const result = try isReducedPred(test_alloc, &.{Value.initInteger(1)});
    try testing.expectEqual(Value.false_val, result);
}

test "unreduced unwraps reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value.initInteger(42)});
    const result = try unreducedFn(test_alloc, &.{r});
    try testing.expect(result.eql(Value.initInteger(42)));
}

test "unreduced passes through normal values" {
    const result = try unreducedFn(test_alloc, &.{Value.initInteger(42)});
    try testing.expect(result.eql(Value.initInteger(42)));
}

test "ensure-reduced wraps non-reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ensureReducedFn(arena.allocator(), &.{Value.initInteger(42)});
    try testing.expect(result.tag() == .reduced);
    try testing.expect(result.asReduced().value.eql(Value.initInteger(42)));
}

test "ensure-reduced passes through reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value.initInteger(42)});
    const result = try ensureReducedFn(arena.allocator(), &.{r});
    try testing.expect(result.tag() == .reduced);
    try testing.expect(result.asReduced().value.eql(Value.initInteger(42)));
}

test "builtins table has 74 entries" {
    // 65 + 1 (__instance?) + 8 Java interop (isNaN, isInfinite, char predicates, parseBoolean)
    try testing.expectEqual(74, builtins.len);
}

test "builtins all have func" {
    for (builtins) |b| {
        try testing.expect(b.func != null);
    }
}
