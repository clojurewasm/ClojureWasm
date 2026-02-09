// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Arithmetic builtin definitions — BuiltinDef metadata for +, -, *, /, etc.
//
// Comptime table of BuiltinDef entries for arithmetic and comparison
// operations. These are vm_intrinsic kind — the Compiler emits direct
// opcodes for them. Each also has a runtime fallback function (func) so
// they can be used as first-class values (e.g., (reduce + ...)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../runtime/value.zig").Value;
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
