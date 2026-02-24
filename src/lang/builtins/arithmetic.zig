// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Arithmetic builtin definitions — BuiltinDef metadata for +, -, *, /, etc.
//!
//! Comptime table of BuiltinDef entries for arithmetic and comparison
//! operations. These are vm_intrinsic kind — the Compiler emits direct
//! opcodes for them. Each also has a runtime fallback function (func) so
//! they can be used as first-class values (e.g., (reduce + ...)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const collections = @import("../../runtime/collections.zig");
const BigInt = collections.BigInt;
const BigDecimal = collections.BigDecimal;
const Ratio = collections.Ratio;
const err = @import("../../runtime/error.zig");

// Core arithmetic ops live in runtime/ (D109). Re-export for lang/ consumers.
const runtime_arith = @import("../../runtime/arithmetic.zig");
pub const I48_MIN = runtime_arith.I48_MIN;
pub const I48_MAX = runtime_arith.I48_MAX;
pub const ArithOp = runtime_arith.ArithOp;
pub const CompareOp = runtime_arith.CompareOp;
pub const binaryArith = runtime_arith.binaryArith;
pub const binaryArithPromote = runtime_arith.binaryArithPromote;
pub const bigIntArith = runtime_arith.bigIntArith;
pub const binaryDiv = runtime_arith.binaryDiv;
pub const binaryMod = runtime_arith.binaryMod;
pub const binaryRem = runtime_arith.binaryRem;
pub const compareFn = runtime_arith.compareFn;
pub const toFloat = runtime_arith.toFloat;
const valueToBigInt = runtime_arith.valueToBigInt;

/// Arithmetic and comparison intrinsics registered in clojure.core.
pub const builtins = [_]BuiltinDef{
    .{
        .name = "+",
        .func = &addFn,
        .doc = "Returns the sum of nums. (+) returns 0. Does not auto-promote longs, will throw on overflow.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "-",
        .func = &subFn,
        .doc = "If no ys are supplied, returns the negation of x, else subtracts the ys from x and returns the result.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "*",
        .func = &mulFn,
        .doc = "Returns the product of nums. (*) returns 1. Does not auto-promote longs, will throw on overflow.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "/",
        .func = &divFn,
        .doc = "If no denominators are supplied, returns 1/numerator, else returns numerator divided by all of the denominators.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "mod",
        .func = &modFn,
        .doc = "Modulus of num and div. Truncates toward negative infinity.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "rem",
        .func = &remFn,
        .doc = "Remainder of dividing numerator by denominator.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "=",
        .func = &eqFn,
        .doc = "Equality. Returns true if x equals y, false if not.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "not=",
        .func = &neqFn,
        .doc = "Same as (not (= obj1 obj2)).",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "<",
        .func = &ltFn,
        .doc = "Returns non-nil if nums are in monotonically increasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = ">",
        .func = &gtFn,
        .doc = "Returns non-nil if nums are in monotonically decreasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "<=",
        .func = &leFn,
        .doc = "Returns non-nil if nums are in monotonically non-decreasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = ">=",
        .func = &geFn,
        .doc = "Returns non-nil if nums are in monotonically non-increasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "+'",
        .func = &addPFn,
        .doc = "Returns the sum of nums. (+') returns 0. Supports arbitrary precision. See also: +",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "-'",
        .func = &subPFn,
        .doc = "If no ys are supplied, returns the negation of x, else subtracts the ys from x and returns the result. Supports arbitrary precision. See also: -",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "*'",
        .func = &mulPFn,
        .doc = "Returns the product of nums. (*') returns 1. Supports arbitrary precision. See also: *",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
};

// --- Builtin wrapper functions for first-class usage ---

fn addPFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initInteger(0);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArithPromote(result, arg, .add);
    return result;
}

fn subPFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to -'", .{args.len});
    if (args.len == 1) return binaryArithPromote(Value.initInteger(0), args[0], .sub);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArithPromote(result, arg, .sub);
    return result;
}

fn mulPFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initInteger(1);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArithPromote(result, arg, .mul);
    return result;
}

fn addFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initInteger(0);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .add);
    return result;
}

fn subFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to -", .{args.len});
    if (args.len == 1) return binaryArith(Value.initInteger(0), args[0], .sub);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .sub);
    return result;
}

fn mulFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initInteger(1);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .mul);
    return result;
}

fn divFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to /", .{args.len});
    if (args.len == 1) return binaryDiv(Value.initInteger(1), args[0]);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryDiv(result, arg);
    return result;
}

fn modFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to mod", .{args.len});
    return binaryMod(args[0], args[1]);
}

fn remFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rem", .{args.len});
    return binaryRem(args[0], args[1]);
}

fn eqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) return Value.true_val;
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to =", .{args.len});
    // Use eqlAlloc to realize nested lazy-seqs during comparison
    for (args[1..]) |arg| {
        if (!args[0].eqlAlloc(arg, allocator)) return Value.false_val;
    }
    return Value.true_val;
}

fn neqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) return Value.false_val;
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to not=", .{args.len});
    return Value.initBoolean(!args[0].eqlAlloc(args[1], allocator));
}

fn makeCompareFn(comptime op: CompareOp) fn (Allocator, []const Value) anyerror!Value {
    const op_name = comptime switch (op) {
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
    };
    return struct {
        fn func(_: Allocator, args: []const Value) anyerror!Value {
            if (args.len == 1) return Value.true_val;
            if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to " ++ op_name, .{args.len});
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!try compareFn(a, b, op)) return Value.false_val;
            }
            return Value.true_val;
        }
    }.func;
}

const ltFn = makeCompareFn(.lt);
const gtFn = makeCompareFn(.gt);
const leFn = makeCompareFn(.le);
const geFn = makeCompareFn(.ge);

// === Tests ===

test "arithmetic builtins table has 15 entries" {
    try std.testing.expectEqual(15, builtins.len);
}

test "arithmetic builtins all have func" {
    for (builtins) |b| {
        try std.testing.expect(b.func != null);
    }
}

test "arithmetic builtins have doc and arglists" {
    for (builtins) |b| {
        try std.testing.expect(b.doc != null);
        try std.testing.expect(b.arglists != null);
        try std.testing.expect(b.added != null);
    }
}

test "arithmetic builtins comptime name lookup" {
    const found = comptime blk: {
        for (&builtins) |b| {
            if (std.mem.eql(u8, b.name, "+")) break :blk b;
        }
        @compileError("+ not found");
    };
    try std.testing.expectEqualStrings("+", found.name);
    try std.testing.expect(found.func != null);
}

test "arithmetic builtins no duplicate names" {
    comptime {
        for (builtins, 0..) |a, i| {
            for (builtins[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError("duplicate arithmetic builtin: " ++ a.name);
                }
            }
        }
    }
}


// ============================================================
// Numeric builtins (abs, max, min, quot, bit-*, parse-*, etc.)
// ============================================================


// ============================================================
// Implementations
// ============================================================

/// (abs n) — returns the absolute value of n.
pub fn absFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to abs", .{args.len});
    return switch (args[0].tag()) {
        .integer => Value.initInteger(if (args[0].asInteger() < 0) -args[0].asInteger() else args[0].asInteger()),
        .float => Value.initFloat(@abs(args[0].asFloat())),
        .big_int => blk: {
            const bi = args[0].asBigInt();
            if (bi.managed.isPositive() or bi.managed.toConst().eqlZero()) break :blk args[0];
            const alloc = std.heap.page_allocator;
            const result = alloc.create(collections.BigInt) catch return error.OutOfMemory;
            result.managed = bi.managed; // copy
            result.managed.negate();
            break :blk Value.initBigInt(result);
        },
        .big_decimal => Value.initFloat(@abs(args[0].asBigDecimal().toF64())),
        .ratio => blk: {
            const r = args[0].asRatio();
            if (r.numerator.managed.isPositive() or r.numerator.managed.toConst().eqlZero()) break :blk args[0];
            // Negate numerator to get absolute value
            const alloc = std.heap.page_allocator;
            const new_ratio = alloc.create(collections.Ratio) catch return error.OutOfMemory;
            const neg_num = alloc.create(collections.BigInt) catch return error.OutOfMemory;
            neg_num.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
            neg_num.managed.copy(r.numerator.managed.toConst()) catch return error.OutOfMemory;
            neg_num.managed.negate();
            new_ratio.* = .{ .kind = .ratio, .numerator = neg_num, .denominator = r.denominator };
            break :blk Value.initRatio(new_ratio);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0].tag())}),
    };
}

/// (max x y & more) — returns the greatest of the nums.
pub fn maxFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to max", .{args.len});
    var best = args[0];
    for (args[1..]) |a| {
        if (try compareNum(a, best) > 0) {
            best = a;
        }
    }
    return best;
}

/// (min x y & more) — returns the least of the nums.
pub fn minFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to min", .{args.len});
    var best = args[0];
    for (args[1..]) |a| {
        if (try compareNum(a, best) < 0) {
            best = a;
        }
    }
    return best;
}

/// (quot num div) — returns the quotient of dividing num by div (truncated).
pub fn quotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to quot", .{args.len});
    const a = args[0];
    const b = args[1];
    // Ratio quot → convert to float, truncate
    if (a.tag() == .ratio or b.tag() == .ratio) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
        const result = @trunc(fa / fb);
        const i: i48 = @intFromFloat(result);
        return Value.initInteger(i);
    }
    // BigDecimal quot → float
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
        return Value.initFloat(@trunc(fa / fb));
    }
    // BigInt quot
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
            return Value.initFloat(@trunc(fa / fb));
        }
        const alloc = std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        if (bb.managed.toConst().eqlZero()) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
        const quotient = alloc.create(collections.BigInt) catch return error.OutOfMemory;
        quotient.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        const remainder = alloc.create(collections.BigInt) catch return error.OutOfMemory;
        remainder.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        quotient.managed.divTrunc(&remainder.managed, &ba.managed, &bb.managed) catch return error.OutOfMemory;
        return Value.initBigInt(quotient);
    }
    return switch (a.tag()) {
        .integer => switch (b.tag()) {
            .integer => blk: {
                if (b.asInteger() == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                break :blk Value.initInteger(@divTrunc(a.asInteger(), b.asInteger()));
            },
            .float => blk: {
                if (b.asFloat() == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                const fa: f64 = @floatFromInt(a.asInteger());
                break :blk Value.initFloat(@trunc(fa / b.asFloat()));
            },
            else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(b.tag())}),
        },
        .float => switch (b.tag()) {
            .integer => blk: {
                if (b.asInteger() == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                const fb: f64 = @floatFromInt(b.asInteger());
                break :blk Value.initFloat(@trunc(a.asFloat() / fb));
            },
            .float => blk: {
                if (b.asFloat() == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                break :blk Value.initFloat(@trunc(a.asFloat() / b.asFloat()));
            },
            else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(b.tag())}),
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(a.tag())}),
    };
}

// PRNG state for rand/rand-int (module-level, deterministic seed for testing)
// Protected by mutex for thread-safe access.
var prng = std.Random.DefaultPrng.init(0);
var prng_mutex: std.Thread.Mutex = .{};

/// Set PRNG seed (for testing reproducibility).
pub fn setSeed(seed: u64) void {
    prng_mutex.lock();
    defer prng_mutex.unlock();
    prng = std.Random.DefaultPrng.init(seed);
}

/// (rand) — returns a random float between 0 (inclusive) and 1 (exclusive).
pub fn randFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rand", .{args.len});
    prng_mutex.lock();
    defer prng_mutex.unlock();
    const f = prng.random().float(f64);
    return Value.initFloat(f);
}

/// (rand-int n) — returns a random integer between 0 (inclusive) and n (exclusive).
pub fn randIntFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rand-int", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(args[0].tag())}),
    };
    if (n <= 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "rand-int argument must be positive, got {d}", .{n});
    const un: u64 = @intCast(n);
    prng_mutex.lock();
    defer prng_mutex.unlock();
    const result = prng.random().intRangeLessThan(u64, 0, un);
    return Value.initInteger(@intCast(result));
}

fn compareNum(a: Value, b: Value) !i2 {
    // Ratio comparison → convert to float
    if (a.tag() == .ratio or b.tag() == .ratio) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fa < fb) return -1;
        if (fa > fb) return 1;
        return 0;
    }
    // BigDecimal comparison → convert to float
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fa < fb) return -1;
        if (fa > fb) return 1;
        return 0;
    }
    // BigInt comparison
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            // Mixed BigInt/float: compare as f64
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fa < fb) return -1;
            if (fa > fb) return 1;
            return 0;
        }
        // Both integer-like: compare as BigInt
        const alloc = std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        return switch (ba.managed.toConst().order(bb.managed.toConst())) {
            .lt => @as(i2, -1),
            .gt => @as(i2, 1),
            .eq => @as(i2, 0),
        };
    }
    const fa = switch (a.tag()) {
        .integer => @as(f64, @floatFromInt(a.asInteger())),
        .float => a.asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(a.tag())}),
    };
    const fb = switch (b.tag()) {
        .integer => @as(f64, @floatFromInt(b.asInteger())),
        .float => b.asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(b.tag())}),
    };
    if (fa < fb) return -1;
    if (fa > fb) return 1;
    return 0;
}

// ============================================================
// Bitwise operations
// ============================================================

fn requireInt(v: Value) !i64 {
    return switch (v.tag()) {
        .integer => v.asInteger(),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(v.tag())}),
    };
}

/// (bit-and x y) — bitwise AND
pub fn bitAndFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-and", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value.initInteger(a & b);
}

/// (bit-or x y) — bitwise OR
pub fn bitOrFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-or", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value.initInteger(a | b);
}

/// (bit-xor x y) — bitwise XOR
pub fn bitXorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-xor", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value.initInteger(a ^ b);
}

/// (bit-and-not x y) — bitwise AND with complement of y
pub fn bitAndNotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-and-not", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value.initInteger(a & ~b);
}

/// (bit-not x) — bitwise complement
pub fn bitNotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-not", .{args.len});
    const a = try requireInt(args[0]);
    return Value.initInteger(~a);
}

/// (bit-shift-left x n) — left shift
pub fn bitShiftLeftFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-shift-left", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    return Value.initInteger(x << shift);
}

/// (bit-shift-right x n) — arithmetic right shift
pub fn bitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-shift-right", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    return Value.initInteger(x >> shift);
}

/// (unsigned-bit-shift-right x n) — logical (unsigned) right shift
pub fn unsignedBitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unsigned-bit-shift-right", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    const ux: u64 = @bitCast(x);
    return Value.initInteger(@bitCast(ux >> shift));
}

/// (bit-set x n) — set bit n
pub fn bitSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-set", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value.initInteger(x | (@as(i64, 1) << shift));
}

/// (bit-clear x n) — clear bit n
pub fn bitClearFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-clear", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value.initInteger(x & ~(@as(i64, 1) << shift));
}

/// (bit-flip x n) — flip bit n
pub fn bitFlipFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-flip", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value.initInteger(x ^ (@as(i64, 1) << shift));
}

/// (bit-test x n) — test bit n, returns boolean
pub fn bitTestFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-test", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value.initBoolean((x & (@as(i64, 1) << shift)) != 0);
}

// ============================================================
// Numeric coercion functions
// ============================================================

/// (int x) — Coerce to integer (truncate float). Chars return their codepoint.
fn intCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to int", .{args.len});
    return switch (args[0].tag()) {
        .integer => args[0],
        .char => Value.initInteger(@intCast(args[0].asChar())),
        .float => Value.initInteger(@intFromFloat(args[0].asFloat())),
        .ratio => Value.initInteger(@intFromFloat(args[0].asRatio().toF64())),
        .big_int => blk: {
            const bi = args[0].asBigInt();
            const i = bi.managed.toInt(i48) catch
                return err.setErrorFmt(.eval, .type_error, .{}, "Value out of range for int", .{});
            break :blk Value.initInteger(i);
        },
        .big_decimal => Value.initInteger(@intFromFloat(args[0].asBigDecimal().toF64())),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(args[0].tag())}),
    };
}

/// (float x) — Coerce to float.
fn floatCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to float", .{args.len});
    return switch (args[0].tag()) {
        .float => args[0],
        .integer => Value.initFloat(@floatFromInt(args[0].asInteger())),
        .ratio => Value.initFloat(args[0].asRatio().toF64()),
        .big_int => Value.initFloat(args[0].asBigInt().toF64()),
        .big_decimal => Value.initFloat(args[0].asBigDecimal().toF64()),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to float", .{@tagName(args[0].tag())}),
    };
}

/// (num x) — Coerce to Number (identity for numbers).
fn numFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to num", .{args.len});
    return switch (args[0].tag()) {
        .integer, .float, .ratio, .big_int, .big_decimal => args[0],
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0].tag())}),
    };
}

/// (char x) — Coerce to character. JVM: int→Character, char→identity.
fn charFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char", .{args.len});
    const code: u21 = switch (args[0].tag()) {
        .char => return args[0], // identity for char input
        .integer => if (args[0].asInteger() >= 0 and args[0].asInteger() <= 0x10FFFF)
            @intCast(args[0].asInteger())
        else
            return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Value {d} out of Unicode range", .{args[0].asInteger()}),
        .string => blk: {
            const s = args[0].asString();
            if (s.len == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Cannot convert empty string to char", .{});
            const view = std.unicode.Utf8View.initUnchecked(s);
            var it = view.iterator();
            break :blk it.nextCodepoint() orelse return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Cannot convert string to char", .{});
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to char", .{@tagName(args[0].tag())}),
    };
    _ = allocator;
    return Value.initChar(code);
}

/// (parse-long s) — Parses string to integer, returns nil if not valid.
fn parseLongFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-long", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-long expects a string argument", .{}),
    };
    const val = std.fmt.parseInt(i64, s, 10) catch return Value.nil_val;
    return Value.initInteger(val);
}

/// (parse-double s) — Parses string to double, returns nil if not valid.
fn parseDoubleFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-double", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-double expects a string argument", .{}),
    };
    const val = std.fmt.parseFloat(f64, s) catch return Value.nil_val;
    return Value.initFloat(val);
}

/// (parse-uuid s) — Parses string as UUID, returns a UUID instance if valid, nil if not.
/// Throws on non-string input. UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
fn parseUuidFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-uuid", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-uuid expects a string argument", .{}),
    };
    if (isValidUuid(s)) {
        const uuid_class = @import("../interop/classes/uuid.zig");
        return uuid_class.constructFromString(allocator, s);
    }
    return Value.nil_val;
}

/// Validate UUID format: 8-4-4-4-12 hex digits with dashes.
fn isValidUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    // Check dash positions: 8, 13, 18, 23
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return false;
    // Check all other positions are hex digits
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!isHexDigit(c)) return false;
    }
    return true;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// (__pow base exp) — returns base raised to the power of exp (as double).
pub fn powFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __pow", .{args.len});
    const base = switch (args[0].tag()) {
        .integer => @as(f64, @floatFromInt(args[0].asInteger())),
        .float => args[0].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__pow expects a number", .{}),
    };
    const exp = switch (args[1].tag()) {
        .integer => @as(f64, @floatFromInt(args[1].asInteger())),
        .float => args[1].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__pow expects a number", .{}),
    };
    return Value.initFloat(std.math.pow(f64, base, exp));
}

/// (__sqrt n) — returns the square root of n (as double).
pub fn sqrtFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __sqrt", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => @as(f64, @floatFromInt(args[0].asInteger())),
        .float => args[0].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__sqrt expects a number", .{}),
    };
    return Value.initFloat(@sqrt(n));
}

/// (__round n) — returns the closest long to n.
pub fn roundFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __round", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => return args[0],
        .float => args[0].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__round expects a number", .{}),
    };
    return Value.initInteger(@intFromFloat(@round(n)));
}

/// (__ceil n) — returns the smallest integer >= n (as double).
pub fn ceilFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __ceil", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => @as(f64, @floatFromInt(args[0].asInteger())),
        .float => args[0].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__ceil expects a number", .{}),
    };
    return Value.initFloat(@ceil(n));
}

/// (__floor n) — returns the largest integer <= n (as double).
pub fn floorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __floor", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => @as(f64, @floatFromInt(args[0].asInteger())),
        .float => args[0].asFloat(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__floor expects a number", .{}),
    };
    return Value.initFloat(@floor(n));
}

// ============================================================
// Integer string conversion (Java Integer.toBinaryString etc.)
// ============================================================

fn intToBinaryStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Integer/toBinaryString", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i48, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toBinaryString expects a number", .{}),
    };
    // Java uses unsigned 32-bit representation for negative numbers
    const unsigned: u32 = @bitCast(@as(i32, @truncate(n)));
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{b}", .{unsigned}) catch return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toBinaryString format error", .{});
    const owned = allocator.dupe(u8, s) catch return err.setErrorFmt(.eval, .type_error, .{}, "OOM", .{});
    return Value.initString(allocator, owned);
}

fn intToHexStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Integer/toHexString", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i48, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toHexString expects a number", .{}),
    };
    const unsigned: u32 = @bitCast(@as(i32, @truncate(n)));
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{x}", .{unsigned}) catch return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toHexString format error", .{});
    const owned = allocator.dupe(u8, s) catch return err.setErrorFmt(.eval, .type_error, .{}, "OOM", .{});
    return Value.initString(allocator, owned);
}

fn intToOctalStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Integer/toOctalString", .{args.len});
    const n = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i48, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toOctalString expects a number", .{}),
    };
    const unsigned: u32 = @bitCast(@as(i32, @truncate(n)));
    var buf: [11]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{o}", .{unsigned}) catch return err.setErrorFmt(.eval, .type_error, .{}, "Integer/toOctalString format error", .{});
    const owned = allocator.dupe(u8, s) catch return err.setErrorFmt(.eval, .type_error, .{}, "OOM", .{});
    return Value.initString(allocator, owned);
}

// ============================================================
// BigInt constructors
// ============================================================

/// (bigint x) — Coerce to arbitrary-precision integer.
fn bigintFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bigint", .{args.len});
    return toBigInt(allocator, args[0]);
}

/// (biginteger x) — Coerce to arbitrary-precision integer (same as bigint).
fn bigintegerFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to biginteger", .{args.len});
    return toBigInt(allocator, args[0]);
}

fn toBigInt(allocator: Allocator, v: Value) anyerror!Value {
    return switch (v.tag()) {
        .big_int => v,
        .integer => Value.initBigInt(collections.BigInt.initFromI64(allocator, v.asInteger()) catch return error.OutOfMemory),
        .float => blk: {
            const f = v.asFloat();
            if (std.math.isNan(f) or std.math.isInf(f))
                return err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert {s} to BigInt", .{if (std.math.isNan(f)) "NaN" else "Infinity"});
            const i: i64 = @intFromFloat(f);
            break :blk Value.initBigInt(collections.BigInt.initFromI64(allocator, i) catch return error.OutOfMemory);
        },
        .big_decimal => blk: {
            // Convert BigDecimal to BigInt by truncating (scale=0 → use unscaled directly)
            const bd = v.asBigDecimal();
            if (bd.scale == 0) break :blk Value.initBigInt(bd.unscaled);
            // Non-zero scale: divide unscaled by 10^scale to get integer part
            const alloc = allocator;
            const ten_pow = alloc.create(collections.BigInt) catch return error.OutOfMemory;
            ten_pow.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
            try ten_pow.managed.set(1);
            var i: i32 = 0;
            while (i < bd.scale) : (i += 1) {
                const ten = alloc.create(collections.BigInt) catch return error.OutOfMemory;
                ten.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
                try ten.managed.set(10);
                try ten_pow.managed.mul(&ten_pow.managed, &ten.managed);
            }
            const result = alloc.create(collections.BigInt) catch return error.OutOfMemory;
            result.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
            var remainder = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
            result.managed.divTrunc(&remainder, &bd.unscaled.managed, &ten_pow.managed) catch return error.OutOfMemory;
            break :blk Value.initBigInt(result);
        },
        .ratio => blk: {
            // Truncate towards zero: numerator / denominator
            const r = v.asRatio();
            const result = allocator.create(collections.BigInt) catch return error.OutOfMemory;
            result.managed = std.math.big.int.Managed.init(allocator) catch return error.OutOfMemory;
            var remainder = std.math.big.int.Managed.init(allocator) catch return error.OutOfMemory;
            result.managed.divTrunc(&remainder, &r.numerator.managed, &r.denominator.managed) catch return error.OutOfMemory;
            break :blk Value.initBigInt(result);
        },
        .string => blk: {
            const s = v.asString();
            // Try integer parse first
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                break :blk Value.initBigInt(collections.BigInt.initFromI64(allocator, i) catch return error.OutOfMemory);
            } else |_| {
                // Try BigInt parse for large numbers
                break :blk Value.initBigInt(collections.BigInt.initFromString(allocator, s) catch
                    return err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert string to BigInt: {s}", .{s}));
            }
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert {s} to BigInt", .{@tagName(v.tag())}),
    };
}

/// (bigdec x) — Coerce to BigDecimal.
fn bigdecFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bigdec", .{args.len});
    return toBigDec(allocator, args[0]);
}

fn toBigDec(allocator: Allocator, v: Value) anyerror!Value {
    return switch (v.tag()) {
        .big_decimal => v,
        .integer => Value.initBigDecimal(collections.BigDecimal.initFromI64(allocator, v.asInteger()) catch return error.OutOfMemory),
        .float => blk: {
            const f = v.asFloat();
            if (std.math.isNan(f) or std.math.isInf(f))
                return err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert {s} to BigDecimal", .{if (std.math.isNan(f)) "NaN" else "Infinity"});
            // Format float to string, then parse as BigDecimal
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.OutOfMemory;
            break :blk Value.initBigDecimal(collections.BigDecimal.initFromString(allocator, s) catch return error.OutOfMemory);
        },
        .big_int => blk: {
            const bi = v.asBigInt();
            const s = bi.toStringAlloc(allocator) catch return error.OutOfMemory;
            break :blk Value.initBigDecimal(collections.BigDecimal.initFromString(allocator, s) catch return error.OutOfMemory);
        },
        .string => blk: {
            const s = v.asString();
            break :blk Value.initBigDecimal(collections.BigDecimal.initFromString(allocator, s) catch
                return err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert string to BigDecimal: {s}", .{s}));
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot convert {s} to BigDecimal", .{@tagName(v.tag())}),
    };
}

// ============================================================
// Phase A.2: Unchecked arithmetic, inc'/dec', rand-nth
// ============================================================

const predicates_mod = @import("predicates.zig");
const builtins_collections = @import("collections.zig");

fn incPrimeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to inc'", .{args.len});
    // inc' = (+' x 1) — auto-promoting
    return addPFn(undefined, &.{ args[0], Value.initInteger(1) });
}

fn decPrimeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to dec'", .{args.len});
    // dec' = (-' x 1) — auto-promoting
    return subPFn(undefined, &.{ args[0], Value.initInteger(1) });
}

fn uncheckedByteFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unchecked-byte", .{args.len});
    const v = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i64, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "unchecked-byte expects a number", .{}),
    };
    const masked = v & 0xFF;
    return Value.initInteger(if (masked > 127) masked - 256 else masked);
}

fn uncheckedShortFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unchecked-short", .{args.len});
    const v = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i64, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "unchecked-short expects a number", .{}),
    };
    const masked = v & 0xFFFF;
    return Value.initInteger(if (masked > 32767) masked - 65536 else masked);
}

fn uncheckedCharFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unchecked-char", .{args.len});
    _ = allocator;
    const v = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i64, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "unchecked-char expects a number", .{}),
    };
    return Value.initChar(@intCast(v & 0xFFFF));
}

fn uncheckedIntFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unchecked-int", .{args.len});
    const v = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        .float => @as(i64, @intFromFloat(args[0].asFloat())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "unchecked-int expects a number", .{}),
    };
    const masked = v & 0xFFFFFFFF;
    return Value.initInteger(if (masked > 2147483647) masked - 4294967296 else masked);
}

fn randNthFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rand-nth", .{args.len});
    // rand-nth = (nth coll (rand-int (count coll)))
    const cnt = try builtins_collections.countFn(allocator, args);
    const idx = try randIntFn(allocator, &.{cnt});
    return builtins_collections.nthFn(allocator, &.{ args[0], idx });
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const numeric_builtins = [_]BuiltinDef{
    .{
        .name = "abs",
        .func = &absFn,
        .doc = "Returns the absolute value of a.",
        .arglists = "([a])",
        .added = "1.0",
    },
    .{
        .name = "max",
        .func = &maxFn,
        .doc = "Returns the greatest of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "min",
        .func = &minFn,
        .doc = "Returns the least of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "quot",
        .func = &quotFn,
        .doc = "quot[ient] of dividing numerator by denominator.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "rand",
        .func = &randFn,
        .doc = "Returns a random floating point number between 0 (inclusive) and 1 (exclusive).",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "rand-int",
        .func = &randIntFn,
        .doc = "Returns a random integer between 0 (inclusive) and n (exclusive).",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "bit-and",
        .func = &bitAndFn,
        .doc = "Bitwise and.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-or",
        .func = &bitOrFn,
        .doc = "Bitwise or.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-xor",
        .func = &bitXorFn,
        .doc = "Bitwise exclusive or.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-not",
        .func = &bitNotFn,
        .doc = "Bitwise complement.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "bit-shift-left",
        .func = &bitShiftLeftFn,
        .doc = "Bitwise shift left.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-shift-right",
        .func = &bitShiftRightFn,
        .doc = "Bitwise shift right.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "unsigned-bit-shift-right",
        .func = &unsignedBitShiftRightFn,
        .doc = "Bitwise shift right, without sign-extension.",
        .arglists = "([x n])",
        .added = "1.6",
    },
    .{
        .name = "bit-set",
        .func = &bitSetFn,
        .doc = "Set bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-clear",
        .func = &bitClearFn,
        .doc = "Clear bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-flip",
        .func = &bitFlipFn,
        .doc = "Flip bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-test",
        .func = &bitTestFn,
        .doc = "Test bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-and-not",
        .func = &bitAndNotFn,
        .doc = "Bitwise and with complement.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "int",
        .func = &intCoerceFn,
        .doc = "Coerce to int",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "long",
        .func = &intCoerceFn,
        .doc = "Coerce to long",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "short",
        .func = &intCoerceFn,
        .doc = "Coerce to short",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "byte",
        .func = &intCoerceFn,
        .doc = "Coerce to byte",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "float",
        .func = &floatCoerceFn,
        .doc = "Coerce to float",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "double",
        .func = &floatCoerceFn,
        .doc = "Coerce to double",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "num",
        .func = &numFn,
        .doc = "Coerce to Number",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "char",
        .func = &charFn,
        .doc = "Coerce to char",
        .arglists = "([x])",
        .added = "1.1",
    },
    .{
        .name = "parse-long",
        .func = &parseLongFn,
        .doc = "Parses the string argument as a signed decimal integer, returning nil if not valid.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "parse-double",
        .func = &parseDoubleFn,
        .doc = "Parses the string argument as a double, returning nil if not valid.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "parse-uuid",
        .func = &parseUuidFn,
        .doc = "Parses the string argument as a UUID. Returns the UUID if valid, nil if not.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "bigint",
        .func = &bigintFn,
        .doc = "Coerce to BigInt.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "biginteger",
        .func = &bigintegerFn,
        .doc = "Coerce to BigInteger.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "bigdec",
        .func = &bigdecFn,
        .doc = "Coerce to BigDecimal.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "__pow",
        .func = &powFn,
        .doc = "Returns base raised to the power of exp.",
        .arglists = "([base exp])",
        .added = "1.0",
    },
    .{
        .name = "__sqrt",
        .func = &sqrtFn,
        .doc = "Returns the square root of n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__round",
        .func = &roundFn,
        .doc = "Returns the closest long to n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__ceil",
        .func = &ceilFn,
        .doc = "Returns the smallest integer value >= n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__floor",
        .func = &floorFn,
        .doc = "Returns the largest integer value <= n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__int-to-binary-string",
        .func = &intToBinaryStringFn,
        .doc = "Returns a string representation of the integer argument as an unsigned integer in base 2.",
        .arglists = "([i])",
        .added = "1.0",
    },
    .{
        .name = "__int-to-hex-string",
        .func = &intToHexStringFn,
        .doc = "Returns a string representation of the integer argument as an unsigned integer in base 16.",
        .arglists = "([i])",
        .added = "1.0",
    },
    .{
        .name = "__int-to-octal-string",
        .func = &intToOctalStringFn,
        .doc = "Returns a string representation of the integer argument as an unsigned integer in base 8.",
        .arglists = "([i])",
        .added = "1.0",
    },
    // Phase A.2: unchecked arithmetic (delegate to checked — CW has no auto-promotion)
    .{ .name = "unchecked-inc", .func = &predicates_mod.incFn, .doc = "Returns a number one greater than x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-dec", .func = &predicates_mod.decFn, .doc = "Returns a number one less than x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-inc-int", .func = &predicates_mod.incFn, .doc = "Returns a number one greater than x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-dec-int", .func = &predicates_mod.decFn, .doc = "Returns a number one less than x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-negate", .func = &subFn, .doc = "Returns the negation of x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-negate-int", .func = &subFn, .doc = "Returns the negation of x.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "unchecked-add", .func = &addFn, .doc = "Returns the sum of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-add-int", .func = &addFn, .doc = "Returns the sum of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-subtract", .func = &subFn, .doc = "Returns the difference of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-subtract-int", .func = &subFn, .doc = "Returns the difference of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-multiply", .func = &mulFn, .doc = "Returns the product of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-multiply-int", .func = &mulFn, .doc = "Returns the product of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-divide-int", .func = &quotFn, .doc = "Returns the integer division of x and y.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "unchecked-remainder-int", .func = &remFn, .doc = "Returns the remainder of dividing x by y.", .arglists = "([x y])", .added = "1.0" },
    // unchecked type coercions
    .{ .name = "unchecked-byte", .func = &uncheckedByteFn, .doc = "Coerce to byte.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-short", .func = &uncheckedShortFn, .doc = "Coerce to short.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-char", .func = &uncheckedCharFn, .doc = "Coerce to char.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-int", .func = &uncheckedIntFn, .doc = "Coerce to int.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-long", .func = &intCoerceFn, .doc = "Coerce to long.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-float", .func = &floatCoerceFn, .doc = "Coerce to float.", .arglists = "([x])", .added = "1.3" },
    .{ .name = "unchecked-double", .func = &floatCoerceFn, .doc = "Coerce to double.", .arglists = "([x])", .added = "1.3" },
    // auto-promoting inc'/dec'
    .{ .name = "inc'", .func = &incPrimeFn, .doc = "Returns a number one greater than num. Supports arbitrary precision.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "dec'", .func = &decPrimeFn, .doc = "Returns a number one less than num. Supports arbitrary precision.", .arglists = "([x])", .added = "1.0" },
    // rand-nth
    .{ .name = "rand-nth", .func = &randNthFn, .doc = "Return a random element of the (sequential) collection.", .arglists = "([coll])", .added = "1.2" },
};

// === Tests ===


// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;


// --- numeric tests ---

test "abs on positive integer" {
    try testing.expectEqual(Value.initInteger(5), try absFn(test_alloc, &.{Value.initInteger(5)}));
}

test "abs on negative integer" {
    try testing.expectEqual(Value.initInteger(5), try absFn(test_alloc, &.{Value.initInteger(-5)}));
}

test "abs on float" {
    try testing.expectEqual(Value.initFloat(3.14), try absFn(test_alloc, &.{Value.initFloat(-3.14)}));
}

test "max with two integers" {
    try testing.expectEqual(Value.initInteger(10), try maxFn(test_alloc, &.{ Value.initInteger(3), Value.initInteger(10) }));
}

test "max with three values" {
    try testing.expectEqual(Value.initInteger(10), try maxFn(test_alloc, &.{
        Value.initInteger(3),
        Value.initInteger(10),
        Value.initInteger(7),
    }));
}

test "max single arg" {
    try testing.expectEqual(Value.initInteger(42), try maxFn(test_alloc, &.{Value.initInteger(42)}));
}

test "min with two integers" {
    try testing.expectEqual(Value.initInteger(3), try minFn(test_alloc, &.{ Value.initInteger(3), Value.initInteger(10) }));
}

test "min with mixed types" {
    try testing.expectEqual(Value.initInteger(1), try minFn(test_alloc, &.{
        Value.initFloat(2.5),
        Value.initInteger(1),
    }));
}

test "quot integer division" {
    try testing.expectEqual(Value.initInteger(3), try quotFn(test_alloc, &.{ Value.initInteger(10), Value.initInteger(3) }));
}

test "quot negative truncates toward zero" {
    try testing.expectEqual(Value.initInteger(-3), try quotFn(test_alloc, &.{ Value.initInteger(-10), Value.initInteger(3) }));
}

test "quot division by zero" {
    try testing.expectError(error.ArithmeticError, quotFn(test_alloc, &.{ Value.initInteger(10), Value.initInteger(0) }));
}

test "bit-and" {
    try testing.expectEqual(Value.initInteger(0b1000), try bitAndFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(0b1100) }));
}

test "bit-or" {
    try testing.expectEqual(Value.initInteger(0b1110), try bitOrFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(0b1100) }));
}

test "bit-xor" {
    try testing.expectEqual(Value.initInteger(0b0110), try bitXorFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(0b1100) }));
}

test "bit-not" {
    const result = try bitNotFn(test_alloc, &.{Value.initInteger(0)});
    try testing.expectEqual(Value.initInteger(-1), result);
}

test "bit-shift-left" {
    try testing.expectEqual(Value.initInteger(8), try bitShiftLeftFn(test_alloc, &.{ Value.initInteger(1), Value.initInteger(3) }));
}

test "bit-shift-right" {
    try testing.expectEqual(Value.initInteger(2), try bitShiftRightFn(test_alloc, &.{ Value.initInteger(8), Value.initInteger(2) }));
}

test "unsigned-bit-shift-right" {
    // -1 is all 1s, unsigned shift fills with 0s
    const result = try unsignedBitShiftRightFn(test_alloc, &.{ Value.initInteger(-1), Value.initInteger(1) });
    try testing.expectEqual(Value.initInteger(std.math.maxInt(i64)), result);
}

test "bit-set" {
    try testing.expectEqual(Value.initInteger(0b1010), try bitSetFn(test_alloc, &.{ Value.initInteger(0b1000), Value.initInteger(1) }));
}

test "bit-clear" {
    try testing.expectEqual(Value.initInteger(0b1000), try bitClearFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(1) }));
}

test "bit-flip" {
    try testing.expectEqual(Value.initInteger(0b1110), try bitFlipFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(2) }));
}

test "bit-test" {
    try testing.expectEqual(Value.true_val, try bitTestFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(1) }));
    try testing.expectEqual(Value.false_val, try bitTestFn(test_alloc, &.{ Value.initInteger(0b1010), Value.initInteger(2) }));
}

test "rand returns float in [0, 1)" {
    setSeed(12345);
    const result = try randFn(test_alloc, &.{});
    try testing.expect(result.tag() == .float);
    try testing.expect(result.asFloat() >= 0.0 and result.asFloat() < 1.0);
}

test "rand-int returns integer in [0, n)" {
    setSeed(12345);
    const result = try randIntFn(test_alloc, &.{Value.initInteger(100)});
    try testing.expect(result.tag() == .integer);
    try testing.expect(result.asInteger() >= 0 and result.asInteger() < 100);
}

test "rand-int with non-positive n is error" {
    try testing.expectError(error.ArithmeticError, randIntFn(test_alloc, &.{Value.initInteger(0)}));
    try testing.expectError(error.ArithmeticError, randIntFn(test_alloc, &.{Value.initInteger(-5)}));
}

test "parse-long valid integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.initInteger(42), try parseLongFn(alloc, &.{Value.initString(alloc, "42")}));
}

test "parse-long negative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.initInteger(-7), try parseLongFn(alloc, &.{Value.initString(alloc, "-7")}));
}

test "parse-long invalid returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.nil_val, try parseLongFn(alloc, &.{Value.initString(alloc, "abc")}));
}

test "parse-long float string returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.nil_val, try parseLongFn(alloc, &.{Value.initString(alloc, "3.14")}));
}

test "parse-double valid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try parseDoubleFn(alloc, &.{Value.initString(alloc, "3.14")});
    try testing.expect(result.tag() == .float);
    try testing.expect(result.asFloat() == 3.14);
}

test "parse-double invalid returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(Value.nil_val, try parseDoubleFn(alloc, &.{Value.initString(alloc, "xyz")}));
}

test "parse-long non-string throws TypeError" {
    try testing.expectError(error.TypeError, parseLongFn(test_alloc, &.{Value.initInteger(42)}));
}

