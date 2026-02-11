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
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const collections = @import("../runtime/collections.zig");
const BigInt = collections.BigInt;
const BigDecimal = collections.BigDecimal;
const Ratio = collections.Ratio;
const err = @import("../runtime/error.zig");

// i48 range constants for NaN-boxed integers
pub const I48_MIN: i64 = -(1 << 47);
pub const I48_MAX: i64 = (1 << 47) - 1;

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

// --- Runtime fallback functions for first-class usage ---

pub fn toFloat(v: Value) !f64 {
    return switch (v.tag()) {
        .integer => @floatFromInt(v.asInteger()),
        .float => v.asFloat(),
        .big_int => v.asBigInt().toF64(),
        .big_decimal => v.asBigDecimal().toF64(),
        .ratio => v.asRatio().toF64(),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(v.tag())}),
    };
}

pub const ArithOp = enum { add, sub, mul };

pub fn binaryArith(a: Value, b: Value, comptime op: ArithOp) !Value {
    return binaryArithAlloc(null, a, b, op);
}

pub fn binaryArithAlloc(allocator: ?Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    // Ratio promotion: if either side is Ratio, do Ratio arithmetic
    if (a.tag() == .ratio or b.tag() == .ratio) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return ratioArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    // BigDecimal promotion: if either side is BigDecimal, do BigDecimal arithmetic
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return bigDecArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    // BigInt promotion: if either side is BigInt, do BigInt arithmetic
    if (a.tag() == .big_int or b.tag() == .big_int) {
        // If one side is float, convert to float arithmetic
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return bigIntArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    if (a.tag() == .integer and b.tag() == .integer) {
        const result = switch (op) {
            .add => @addWithOverflow(a.asInteger(), b.asInteger()),
            .sub => @subWithOverflow(a.asInteger(), b.asInteger()),
            .mul => @mulWithOverflow(a.asInteger(), b.asInteger()),
        };
        if (result[1] == 0) return Value.initInteger(result[0]);
        // Overflow: promote to float (matches Clojure auto-promotion)
        return Value.initFloat(switch (op) {
            .add => @as(f64, @floatFromInt(a.asInteger())) + @as(f64, @floatFromInt(b.asInteger())),
            .sub => @as(f64, @floatFromInt(a.asInteger())) - @as(f64, @floatFromInt(b.asInteger())),
            .mul => @as(f64, @floatFromInt(a.asInteger())) * @as(f64, @floatFromInt(b.asInteger())),
        });
    }
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    return Value.initFloat(switch (op) {
        .add => fa + fb,
        .sub => fa - fb,
        .mul => fa * fb,
    });
}

/// Ratio arithmetic: (a/b) op (c/d).
/// add: (ad + bc) / bd, sub: (ad - bc) / bd, mul: ac / bd.
/// Result auto-reduces via GCD. If result is integer, returns integer.
fn ratioArith(allocator: Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    const ra = try valueToRatio(allocator, a);
    const rb = try valueToRatio(allocator, b);

    const result_num = try allocator.create(BigInt);
    result_num.managed = try std.math.big.int.Managed.init(allocator);
    const result_den = try allocator.create(BigInt);
    result_den.managed = try std.math.big.int.Managed.init(allocator);

    switch (op) {
        .add, .sub => {
            // (a*d ± b*c) / (b*d)
            var ad = try std.math.big.int.Managed.init(allocator);
            try ad.mul(&ra.numerator.managed, &rb.denominator.managed);
            var bc = try std.math.big.int.Managed.init(allocator);
            try bc.mul(&rb.numerator.managed, &ra.denominator.managed);
            switch (op) {
                .add => try result_num.managed.add(&ad, &bc),
                .sub => try result_num.managed.sub(&ad, &bc),
                else => unreachable,
            }
            try result_den.managed.mul(&ra.denominator.managed, &rb.denominator.managed);
        },
        .mul => {
            // (a*c) / (b*d)
            try result_num.managed.mul(&ra.numerator.managed, &rb.numerator.managed);
            try result_den.managed.mul(&ra.denominator.managed, &rb.denominator.managed);
        },
    }

    // Reduce and return
    const maybe_ratio = try Ratio.initReduced(allocator, result_num, result_den);
    if (maybe_ratio) |ratio| return Value.initRatio(ratio);
    // Simplifies to integer: compute result_num / result_den
    const int_result = try allocator.create(BigInt);
    int_result.managed = try std.math.big.int.Managed.init(allocator);
    var _rem = try std.math.big.int.Managed.init(allocator);
    try int_result.managed.divTrunc(&_rem, &result_num.managed, &result_den.managed);
    if (int_result.toI64()) |i| return Value.initInteger(i);
    return Value.initBigInt(int_result);
}

fn valueToRatio(allocator: Allocator, v: Value) !*Ratio {
    return switch (v.tag()) {
        .ratio => v.asRatio(),
        .integer => blk: {
            const r = try allocator.create(Ratio);
            r.kind = .ratio;
            r.numerator = try BigInt.initFromI64(allocator, v.asInteger());
            r.denominator = try BigInt.initFromI64(allocator, 1);
            break :blk r;
        },
        .big_int => blk: {
            const r = try allocator.create(Ratio);
            r.kind = .ratio;
            r.numerator = v.asBigInt();
            r.denominator = try BigInt.initFromI64(allocator, 1);
            break :blk r;
        },
        else => unreachable,
    };
}

/// BigInt arithmetic: promotes both sides to BigInt, returns BigInt result.
/// If result fits in i64, still returns BigInt (sticky promotion).
pub fn bigIntArith(allocator: Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    const ba = try valueToBigInt(allocator, a);
    const bb = try valueToBigInt(allocator, b);

    const result = try allocator.create(BigInt);
    result.managed = try std.math.big.int.Managed.init(allocator);
    switch (op) {
        .add => try result.managed.add(&ba.managed, &bb.managed),
        .sub => try result.managed.sub(&ba.managed, &bb.managed),
        .mul => try result.managed.mul(&ba.managed, &bb.managed),
    }
    return Value.initBigInt(result);
}

/// BigDecimal arithmetic: promotes both sides to BigDecimal, returns BigDecimal result.
fn bigDecArith(allocator: Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    const da = try valueToBigDec(allocator, a);
    const db = try valueToBigDec(allocator, b);

    // Align scales: use the larger scale for add/sub, sum for mul
    const result = try allocator.create(BigDecimal);
    result.kind = .big_decimal;

    switch (op) {
        .add, .sub => {
            // Align to max scale
            const max_scale = @max(da.scale, db.scale);
            const ua = try scaleUnscaled(allocator, da, max_scale);
            const ub = try scaleUnscaled(allocator, db, max_scale);
            result.unscaled = try allocator.create(BigInt);
            result.unscaled.managed = try std.math.big.int.Managed.init(allocator);
            switch (op) {
                .add => try result.unscaled.managed.add(&ua.managed, &ub.managed),
                .sub => try result.unscaled.managed.sub(&ua.managed, &ub.managed),
                else => unreachable,
            }
            result.scale = max_scale;
        },
        .mul => {
            result.unscaled = try allocator.create(BigInt);
            result.unscaled.managed = try std.math.big.int.Managed.init(allocator);
            try result.unscaled.managed.mul(&da.unscaled.managed, &db.unscaled.managed);
            result.scale = da.scale + db.scale;
        },
    }
    return Value.initBigDecimal(result);
}

/// Scale a BigDecimal's unscaled value to a target scale by multiplying by 10^(target - current).
fn scaleUnscaled(allocator: Allocator, bd: *const BigDecimal, target_scale: i32) !*BigInt {
    const diff = target_scale - bd.scale;
    if (diff == 0) return bd.unscaled;
    if (diff < 0) return bd.unscaled; // should not happen in add/sub
    // Multiply unscaled by 10^diff
    const factor = try allocator.create(BigInt);
    factor.managed = try std.math.big.int.Managed.init(allocator);
    // Set factor to 10^diff
    try factor.managed.set(1);
    var i: i32 = 0;
    while (i < diff) : (i += 1) {
        const ten = try allocator.create(BigInt);
        ten.managed = try std.math.big.int.Managed.init(allocator);
        try ten.managed.set(10);
        try factor.managed.mul(&factor.managed, &ten.managed);
    }
    const scaled = try allocator.create(BigInt);
    scaled.managed = try std.math.big.int.Managed.init(allocator);
    try scaled.managed.mul(&bd.unscaled.managed, &factor.managed);
    return scaled;
}

fn valueToBigDec(allocator: Allocator, v: Value) !*BigDecimal {
    return switch (v.tag()) {
        .big_decimal => v.asBigDecimal(),
        .integer => BigDecimal.initFromI64(allocator, v.asInteger()),
        .big_int => blk: {
            const bi = v.asBigInt();
            const bd = try allocator.create(BigDecimal);
            bd.kind = .big_decimal;
            bd.unscaled = bi;
            bd.scale = 0;
            break :blk bd;
        },
        else => unreachable,
    };
}

pub fn valueToBigInt(allocator: std.mem.Allocator, v: Value) !*BigInt {
    return switch (v.tag()) {
        .big_int => v.asBigInt(),
        .integer => BigInt.initFromI64(allocator, v.asInteger()),
        else => unreachable,
    };
}

// --- Auto-promoting arithmetic: overflow → BigInt instead of float ---

pub fn binaryArithPromote(a: Value, b: Value, comptime op: ArithOp) !Value {
    return binaryArithPromoteAlloc(null, a, b, op);
}

pub fn binaryArithPromoteAlloc(allocator: ?Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    // Ratio promotion: same as regular arithmetic
    if (a.tag() == .ratio or b.tag() == .ratio) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return ratioArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    // BigDecimal promotion: same as regular arithmetic
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return bigDecArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    // BigInt promotion: same as regular arithmetic
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return Value.initFloat(switch (op) {
                .add => fa + fb,
                .sub => fa - fb,
                .mul => fa * fb,
            });
        }
        const alloc = allocator orelse std.heap.page_allocator;
        return bigIntArith(alloc, a, b, op) catch return error.OutOfMemory;
    }
    if (a.tag() == .integer and b.tag() == .integer) {
        const ai = a.asInteger();
        const bi = b.asInteger();
        const result = switch (op) {
            .add => @addWithOverflow(ai, bi),
            .sub => @subWithOverflow(ai, bi),
            .mul => @mulWithOverflow(ai, bi),
        };
        if (result[1] != 0) {
            // i64 overflow: promote to BigInt
            const alloc = allocator orelse std.heap.page_allocator;
            return bigIntArith(alloc, a, b, op) catch return error.OutOfMemory;
        }
        const r = result[0];
        if (r >= I48_MIN and r <= I48_MAX) return Value.initInteger(r);
        // Exceeds i48 range: promote to BigInt
        const alloc = allocator orelse std.heap.page_allocator;
        const bi_result = BigInt.initFromI64(alloc, r) catch return error.OutOfMemory;
        return Value.initBigInt(bi_result);
    }
    // Mixed float: same as regular (floats don't auto-promote)
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    return Value.initFloat(switch (op) {
        .add => fa + fb,
        .sub => fa - fb,
        .mul => fa * fb,
    });
}

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

pub fn binaryDiv(a: Value, b: Value) !Value {
    return binaryDivAlloc(null, a, b);
}

fn binaryDivAlloc(allocator: ?Allocator, a: Value, b: Value) !Value {
    // Ratio division: (a/b) / (c/d) = (a*d) / (b*c)
    if (a.tag() == .ratio or b.tag() == .ratio) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
            return Value.initFloat(fa / fb);
        }
        const alloc = allocator orelse std.heap.page_allocator;
        const ra = valueToRatio(alloc, a) catch return error.OutOfMemory;
        const rb = valueToRatio(alloc, b) catch return error.OutOfMemory;
        // Check for zero denominator
        if (rb.numerator.managed.toConst().eqlZero()) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        const num = try alloc.create(BigInt);
        num.managed = try std.math.big.int.Managed.init(alloc);
        try num.managed.mul(&ra.numerator.managed, &rb.denominator.managed);
        const den = try alloc.create(BigInt);
        den.managed = try std.math.big.int.Managed.init(alloc);
        try den.managed.mul(&ra.denominator.managed, &rb.numerator.managed);
        const maybe_ratio = Ratio.initReduced(alloc, num, den) catch return error.OutOfMemory;
        if (maybe_ratio) |ratio| return Value.initRatio(ratio);
        // Simplifies to integer: compute num / den
        const int_result = alloc.create(BigInt) catch return error.OutOfMemory;
        int_result.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        var _rem = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        int_result.managed.divTrunc(&_rem, &num.managed, &den.managed) catch return error.OutOfMemory;
        if (int_result.toI64()) |i| return Value.initInteger(i);
        return Value.initBigInt(int_result);
    }
    // BigDecimal division → convert to float (avoids Non-terminating decimal issues)
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initFloat(fa / fb);
    }
    // BigInt / BigInt → Ratio or BigInt
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
            return Value.initFloat(fa / fb);
        }
        const alloc = allocator orelse std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        if (bb.managed.toConst().eqlZero()) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        const maybe_ratio = Ratio.initReduced(alloc, ba, bb) catch return error.OutOfMemory;
        if (maybe_ratio) |ratio| return Value.initRatio(ratio);
        // Exact division
        const result = alloc.create(BigInt) catch return error.OutOfMemory;
        result.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        var remainder = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        result.managed.divTrunc(&remainder, &ba.managed, &bb.managed) catch return error.OutOfMemory;
        return Value.initBigInt(result);
    }
    // Integer / integer → Ratio or integer
    if (a.tag() == .integer and b.tag() == .integer) {
        const ai = a.asInteger();
        const bi = b.asInteger();
        if (bi == 0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        if (@rem(ai, bi) == 0) return Value.initInteger(@divTrunc(ai, bi));
        // Not evenly divisible → Ratio
        const alloc = allocator orelse std.heap.page_allocator;
        const maybe_ratio = Ratio.initFromI64(alloc, ai, bi) catch return error.OutOfMemory;
        if (maybe_ratio) |ratio| return Value.initRatio(ratio);
        return Value.initInteger(@divTrunc(ai, bi));
    }
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    if (std.math.isNan(fa) or std.math.isNan(fb)) return Value.initFloat(std.math.nan(f64));
    if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
    return Value.initFloat(fa / fb);
}

pub fn binaryMod(a: Value, b: Value) !Value {
    // Ratio: convert to float (mod/rem on rationals → float in Clojure)
    if (a.tag() == .ratio or b.tag() == .ratio) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initFloat(@mod(fa, fb));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initFloat(@mod(fa, fb));
    }
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
            return Value.initFloat(@mod(fa, fb));
        }
        const alloc = std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        if (bb.managed.toConst().eqlZero()) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        const quotient = alloc.create(BigInt) catch return error.OutOfMemory;
        quotient.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        const result = alloc.create(BigInt) catch return error.OutOfMemory;
        result.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        quotient.managed.divFloor(&result.managed, &ba.managed, &bb.managed) catch return error.OutOfMemory;
        return Value.initBigInt(result);
    }
    if (a.tag() == .integer and b.tag() == .integer) {
        if (b.asInteger() == 0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initInteger(@mod(a.asInteger(), b.asInteger()));
    }
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
    return Value.initFloat(@mod(fa, fb));
}

pub fn binaryRem(a: Value, b: Value) !Value {
    // Ratio: convert to float
    if (a.tag() == .ratio or b.tag() == .ratio) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initFloat(@rem(fa, fb));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initFloat(@rem(fa, fb));
    }
    if (a.tag() == .big_int or b.tag() == .big_int) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
            return Value.initFloat(@rem(fa, fb));
        }
        const alloc = std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        if (bb.managed.toConst().eqlZero()) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        const quotient = alloc.create(BigInt) catch return error.OutOfMemory;
        quotient.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        const result = alloc.create(BigInt) catch return error.OutOfMemory;
        result.managed = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        quotient.managed.divTrunc(&result.managed, &ba.managed, &bb.managed) catch return error.OutOfMemory;
        return Value.initBigInt(result);
    }
    if (a.tag() == .integer and b.tag() == .integer) {
        if (b.asInteger() == 0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
        return Value.initInteger(@rem(a.asInteger(), b.asInteger()));
    }
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    if (fb == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, err.getArgSource(1), "Divide by zero", .{});
    return Value.initFloat(@rem(fa, fb));
}

pub const CompareOp = enum { lt, le, gt, ge };

pub fn compareFn(a: Value, b: Value, comptime op: CompareOp) !bool {
    if (a.tag() == .integer and b.tag() == .integer) {
        return switch (op) {
            .lt => a.asInteger() < b.asInteger(),
            .le => a.asInteger() <= b.asInteger(),
            .gt => a.asInteger() > b.asInteger(),
            .ge => a.asInteger() >= b.asInteger(),
        };
    }
    // Ratio comparison: cross-multiply to avoid float precision loss
    if (a.tag() == .ratio or b.tag() == .ratio) {
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return switch (op) {
                .lt => fa < fb,
                .le => fa <= fb,
                .gt => fa > fb,
                .ge => fa >= fb,
            };
        }
        const alloc = std.heap.page_allocator;
        const ra = valueToRatio(alloc, a) catch return error.OutOfMemory;
        const rb = valueToRatio(alloc, b) catch return error.OutOfMemory;
        // Compare a/b vs c/d by comparing a*d vs c*b (denominators always positive)
        var lhs = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        lhs.mul(&ra.numerator.managed, &rb.denominator.managed) catch return error.OutOfMemory;
        var rhs = std.math.big.int.Managed.init(alloc) catch return error.OutOfMemory;
        rhs.mul(&rb.numerator.managed, &ra.denominator.managed) catch return error.OutOfMemory;
        const order = lhs.toConst().order(rhs.toConst());
        return switch (op) {
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
        };
    }
    // BigDecimal comparison → convert to float
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const fa = toFloat(a) catch unreachable;
        const fb = toFloat(b) catch unreachable;
        return switch (op) {
            .lt => fa < fb,
            .le => fa <= fb,
            .gt => fa > fb,
            .ge => fa >= fb,
        };
    }
    // BigInt comparison
    if (a.tag() == .big_int or b.tag() == .big_int) {
        // If one side is float, compare as floats
        if (a.tag() == .float or b.tag() == .float) {
            const fa = toFloat(a) catch unreachable;
            const fb = toFloat(b) catch unreachable;
            return switch (op) {
                .lt => fa < fb,
                .le => fa <= fb,
                .gt => fa > fb,
                .ge => fa >= fb,
            };
        }
        const alloc = std.heap.page_allocator;
        const ba = valueToBigInt(alloc, a) catch return error.OutOfMemory;
        const bb = valueToBigInt(alloc, b) catch return error.OutOfMemory;
        const ca = ba.managed.toConst();
        const cb = bb.managed.toConst();
        const order = ca.order(cb);
        return switch (op) {
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
        };
    }
    const fa = toFloat(a) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(a.tag())});
    };
    const fb = toFloat(b) catch {
        return err.setErrorFmt(.eval, .type_error, err.getArgSource(1), "Cannot cast {s} to number", .{@tagName(b.tag())});
    };
    return switch (op) {
        .lt => fa < fb,
        .le => fa <= fb,
        .gt => fa > fb,
        .ge => fa >= fb,
    };
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

/// (int x) — Coerce to integer (truncate float).
fn intCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to int", .{args.len});
    return switch (args[0].tag()) {
        .integer => args[0],
        .float => Value.initInteger(@intFromFloat(args[0].asFloat())),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(args[0].tag())}),
    };
}

/// (float x) — Coerce to float.
fn floatCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to float", .{args.len});
    return switch (args[0].tag()) {
        .float => args[0],
        .integer => Value.initFloat(@floatFromInt(args[0].asInteger())),
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to float", .{@tagName(args[0].tag())}),
    };
}

/// (num x) — Coerce to Number (identity for numbers).
fn numFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to num", .{args.len});
    return switch (args[0].tag()) {
        .integer, .float => args[0],
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0].tag())}),
    };
}

/// (char x) — Coerce int to character string.
fn charFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char", .{args.len});
    const code: u21 = switch (args[0].tag()) {
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
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &buf) catch return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Invalid Unicode codepoint", .{});
    const str = allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    return Value.initString(allocator, str);
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

/// (parse-uuid s) — Parses string as UUID, returns the UUID string if valid, nil if not.
/// Throws on non-string input. UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
fn parseUuidFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-uuid", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-uuid expects a string argument", .{}),
    };
    if (isValidUuid(s)) {
        return Value.initString(allocator, s);
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

