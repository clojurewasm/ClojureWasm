// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Core arithmetic operations for CW value types.
//!
//! This module lives in Layer 0 (runtime/) and provides the binary arithmetic,
//! comparison, division, modulo, and remainder operations used by both the VM
//! and TreeWalk evaluators. Extracted from lang/builtins/arithmetic.zig (D109).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const collections = @import("collections.zig");
const BigInt = collections.BigInt;
const BigDecimal = collections.BigDecimal;
const Ratio = collections.Ratio;
const err = @import("error.zig");

// i48 range constants for NaN-boxed integers
pub const I48_MIN: i64 = -(1 << 47);
pub const I48_MAX: i64 = (1 << 47) - 1;

pub fn toFloat(v: Value) !f64 {
    return switch (v.tag()) {
        .integer => @as(f64, @floatFromInt(v.asInteger())),
        .float => v.asFloat(),
        .big_int => v.asBigInt().toF64(),
        .ratio => blk: {
            const r = v.asRatio();
            const num_f = r.numerator.toF64();
            const den_f = r.denominator.toF64();
            break :blk num_f / den_f;
        },
        .big_decimal => v.asBigDecimal().toF64(),
        else => err.setErrorFmt(.eval, .type_error, err.getArgSource(0), "Cannot cast {s} to number", .{@tagName(v.tag())}),
    };
}

pub const ArithOp = enum { add, sub, mul };

pub fn binaryArith(a: Value, b: Value, comptime op: ArithOp) !Value {
    return binaryArithAlloc(null, a, b, op);
}

fn binaryArithAlloc(allocator: ?Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    // Fast path: both integers
    if (a.tag() == .integer and b.tag() == .integer) {
        const ai = a.asInteger();
        const bi = b.asInteger();
        const result = switch (op) {
            .add => @as(i128, ai) + @as(i128, bi),
            .sub => @as(i128, ai) - @as(i128, bi),
            .mul => @as(i128, ai) * @as(i128, bi),
        };
        if (result >= I48_MIN and result <= I48_MAX) {
            return Value.initInteger(@as(i64, @intCast(result)));
        }
        // Overflow → error (Clojure throws on overflow for non-promoting ops)
        return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    }

    // Ratio arithmetic
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
        return ratioArith(alloc, a, b, op);
    }

    // BigDecimal arithmetic
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
        return bigDecArith(alloc, a, b, op);
    }

    // BigInt arithmetic (handles big_int + integer, big_int + big_int)
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
        return bigIntArith(alloc, a, b, op);
    }

    // Float path
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

pub fn valueToBigInt(alloc: Allocator, v: Value) !*BigInt {
    if (v.tag() == .big_int) return v.asBigInt();
    if (v.tag() == .integer) {
        const bi = try alloc.create(BigInt);
        bi.managed = try std.math.big.int.Managed.initSet(alloc, v.asInteger());
        return bi;
    }
    return error.TypeError;
}

pub fn binaryArithPromote(a: Value, b: Value, comptime op: ArithOp) !Value {
    return binaryArithPromoteAlloc(null, a, b, op);
}

fn binaryArithPromoteAlloc(allocator: ?Allocator, a: Value, b: Value, comptime op: ArithOp) !Value {
    // Fast path: both integers, auto-promote on overflow
    if (a.tag() == .integer and b.tag() == .integer) {
        const ai = a.asInteger();
        const bi = b.asInteger();
        const result = switch (op) {
            .add => @as(i128, ai) + @as(i128, bi),
            .sub => @as(i128, ai) - @as(i128, bi),
            .mul => @as(i128, ai) * @as(i128, bi),
        };
        if (result >= I48_MIN and result <= I48_MAX) {
            return Value.initInteger(@as(i64, @intCast(result)));
        }
        // Overflow → promote to BigInt
        const alloc = allocator orelse std.heap.page_allocator;
        return bigIntArith(alloc, a, b, op);
    }
    // Delegate to non-promoting path for non-integer types
    return binaryArithAlloc(allocator, a, b, op);
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
