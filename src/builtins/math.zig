// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// clojure.math namespace builtins.
//
// Wraps Zig std.math / @builtins to provide the clojure.math API.
// All functions accept numeric args (int or float), coerce to f64.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const err = @import("../runtime/error.zig");
const BuiltinDef = @import("../runtime/var.zig").BuiltinDef;
const numeric = @import("numeric.zig");

// --- Helpers ---

fn toDouble(v: Value) !f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @as(f64, @floatFromInt(v.asInteger())),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.math expects a numeric argument", .{}),
    };
}

fn toLong(v: Value) !i64 {
    return switch (v.tag()) {
        .integer => v.asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.math expects an integer argument", .{}),
    };
}

fn checkArity1(args: []const Value, name: []const u8) !f64 {
    if (args.len != 1) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/{s}", .{ args.len, name });
        return error.ArityError;
    }
    return toDouble(args[0]);
}

fn checkArity2(args: []const Value, name: []const u8) !struct { f64, f64 } {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/{s}", .{ args.len, name });
        return error.ArityError;
    }
    return .{ try toDouble(args[0]), try toDouble(args[1]) };
}

fn floatVal(v: f64) Value {
    return Value.initFloat(v);
}

fn intVal(v: i64) Value {
    return Value.initInteger(v);
}

// --- Trigonometric ---

fn sinFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@sin(try checkArity1(args, "sin")));
}

fn cosFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@cos(try checkArity1(args, "cos")));
}

fn tanFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@tan(try checkArity1(args, "tan")));
}

fn asinFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.asin(try checkArity1(args, "asin")));
}

fn acosFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.acos(try checkArity1(args, "acos")));
}

fn atanFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.atan(try checkArity1(args, "atan")));
}

fn atan2Fn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "atan2");
    return floatVal(std.math.atan2(ab[0], ab[1]));
}

// --- Hyperbolic ---

fn sinhFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.sinh(try checkArity1(args, "sinh")));
}

fn coshFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.cosh(try checkArity1(args, "cosh")));
}

fn tanhFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.tanh(try checkArity1(args, "tanh")));
}

// --- Exponential / Logarithmic ---

fn expFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@exp(try checkArity1(args, "exp")));
}

fn expm1Fn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.expm1(try checkArity1(args, "expm1")));
}

fn logFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@log(try checkArity1(args, "log")));
}

fn log10Fn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@log10(try checkArity1(args, "log10")));
}

fn log1pFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.log1p(try checkArity1(args, "log1p")));
}

// --- Power / Root ---

fn powFn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "pow");
    // Java Math.pow: if |base| == 1 and exponent is infinite, result is NaN (non-IEEE)
    if (@abs(ab[0]) == 1.0 and std.math.isInf(ab[1])) return floatVal(std.math.nan(f64));
    return floatVal(std.math.pow(f64, ab[0], ab[1]));
}

fn sqrtFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@sqrt(try checkArity1(args, "sqrt")));
}

fn cbrtFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(std.math.cbrt(try checkArity1(args, "cbrt")));
}

fn hypotFn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "hypot");
    return floatVal(std.math.hypot(ab[0], ab[1]));
}

// --- Rounding ---

fn ceilFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@ceil(try checkArity1(args, "ceil")));
}

fn floorMathFn(_: Allocator, args: []const Value) anyerror!Value {
    return floatVal(@floor(try checkArity1(args, "floor")));
}

fn rintFn(_: Allocator, args: []const Value) anyerror!Value {
    // rint rounds to nearest even (Java Math.rint semantics)
    const x = try checkArity1(args, "rint");
    return floatVal(@round(x)); // Zig @round = roundTiesToEven
}

fn roundFn(_: Allocator, args: []const Value) anyerror!Value {
    // Math.round: returns long, rounds half up
    const x = try checkArity1(args, "round");
    if (std.math.isNan(x)) return intVal(0);
    if (x == std.math.inf(f64)) return intVal(std.math.maxInt(i64));
    if (x == -std.math.inf(f64)) return intVal(std.math.minInt(i64));
    if (x >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return intVal(std.math.maxInt(i64));
    if (x <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return intVal(std.math.minInt(i64));
    // Java Math.round: floor(x + 0.5)
    return intVal(@as(i64, @intFromFloat(@floor(x + 0.5))));
}

// --- Sign / Magnitude ---

fn signumFn(_: Allocator, args: []const Value) anyerror!Value {
    const x = try checkArity1(args, "signum");
    if (std.math.isNan(x)) return floatVal(std.math.nan(f64));
    if (x > 0) return floatVal(1.0);
    if (x < 0) return floatVal(-1.0);
    return floatVal(x); // preserve +0.0 / -0.0
}

fn copySignFn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "copy-sign");
    return floatVal(std.math.copysign(ab[0], ab[1]));
}

// --- IEEE operations ---

fn ieeeRemainderFn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "IEEE-remainder");
    const x = ab[0];
    const y = ab[1];
    // IEEE 754 remainder
    if (std.math.isNan(x) or std.math.isNan(y)) return floatVal(std.math.nan(f64));
    if (std.math.isInf(x) or y == 0.0) return floatVal(std.math.nan(f64));
    if (std.math.isInf(y)) return floatVal(x);
    const n = @round(x / y);
    return floatVal(x - n * y);
}

fn ulpFn(_: Allocator, args: []const Value) anyerror!Value {
    const x = try checkArity1(args, "ulp");
    if (std.math.isNan(x)) return floatVal(std.math.nan(f64));
    if (std.math.isInf(x)) return floatVal(std.math.inf(f64));
    const ax = @abs(x);
    if (ax == std.math.floatMax(f64)) return floatVal(std.math.pow(f64, 2.0, 971.0));
    // nextAfter(ax, inf) - ax
    const next = std.math.nextAfter(f64,ax, std.math.inf(f64));
    return floatVal(next - ax);
}

fn getExponentFn(_: Allocator, args: []const Value) anyerror!Value {
    const x = try checkArity1(args, "get-exponent");
    if (std.math.isNan(x) or std.math.isInf(x)) return intVal(1024); // Double.MAX_EXPONENT + 1
    if (x == 0.0 or x == -0.0) return intVal(-1023); // Double.MIN_EXPONENT - 1
    const bits: u64 = @bitCast(x);
    const raw_exp: i64 = @intCast((bits >> 52) & 0x7FF);
    if (raw_exp == 0) {
        // subnormal: count leading zeros of mantissa
        const mantissa = bits & 0x000FFFFFFFFFFFFF;
        const clz: i64 = @intCast(@clz(mantissa));
        return intVal(-1023 + 1 - (clz - 12));
    }
    return intVal(raw_exp - 1023);
}

fn nextAfterFn(_: Allocator, args: []const Value) anyerror!Value {
    const ab = try checkArity2(args, "next-after");
    return floatVal(std.math.nextAfter(f64,ab[0], ab[1]));
}

fn nextUpFn(_: Allocator, args: []const Value) anyerror!Value {
    const x = try checkArity1(args, "next-up");
    return floatVal(std.math.nextAfter(f64,x, std.math.inf(f64)));
}

fn nextDownFn(_: Allocator, args: []const Value) anyerror!Value {
    const x = try checkArity1(args, "next-down");
    return floatVal(std.math.nextAfter(f64,x, -std.math.inf(f64)));
}

fn scalbFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/scalb", .{args.len});
        return error.ArityError;
    }
    const x = try toDouble(args[0]);
    const n = try toLong(args[1]);
    return floatVal(std.math.scalbn(x, @intCast(n)));
}

// --- Exact arithmetic ---

/// Check if an i64 value fits in the NaN-boxed i48 integer range.
fn fitsI48(v: i64) bool {
    return v >= -(1 << 47) and v <= (1 << 47) - 1;
}

fn addExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/add-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const b = try toLong(args[1]);
    const result = @addWithOverflow(a, b);
    if (result[1] != 0 or !fitsI48(result[0])) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(result[0]);
}

fn subtractExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/subtract-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const b = try toLong(args[1]);
    const result = @subWithOverflow(a, b);
    if (result[1] != 0 or !fitsI48(result[0])) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(result[0]);
}

fn multiplyExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/multiply-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const b = try toLong(args[1]);
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0 or !fitsI48(result[0])) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(result[0]);
}

fn incrementExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/increment-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const result = @addWithOverflow(a, @as(i64, 1));
    if (result[1] != 0 or !fitsI48(result[0])) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(result[0]);
}

fn decrementExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/decrement-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const result = @subWithOverflow(a, @as(i64, 1));
    if (result[1] != 0 or !fitsI48(result[0])) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(result[0]);
}

fn negateExactFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/negate-exact", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    if (!fitsI48(-a)) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "integer overflow", .{});
    return intVal(-a);
}

// --- Integer division ---

fn floorDivFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/floor-div", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const b = try toLong(args[1]);
    // Java Math.floorDiv: a/b rounded toward negative infinity
    if (b == -1) return intVal(if (a == std.math.minInt(i64)) std.math.minInt(i64) else -a);
    const q = @divTrunc(a, b);
    // If signs differ and there's a remainder, subtract 1
    if ((a ^ b) < 0 and q * b != a) return intVal(q - 1);
    return intVal(q);
}

fn floorModFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) {
        err.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.math/floor-mod", .{args.len});
        return error.ArityError;
    }
    const a = try toLong(args[0]);
    const b = try toLong(args[1]);
    // Java Math.floorMod: a - floorDiv(a,b) * b
    const r = @rem(a, b);
    if ((r != 0) and ((r ^ b) < 0)) return intVal(r + b);
    return intVal(r);
}

// --- Conversion ---

fn toRadiansFn(_: Allocator, args: []const Value) anyerror!Value {
    const d = try checkArity1(args, "to-radians");
    return floatVal(d * (std.math.pi / 180.0));
}

fn toDegreesFn(_: Allocator, args: []const Value) anyerror!Value {
    const r = try checkArity1(args, "to-degrees");
    return floatVal(r * (180.0 / std.math.pi));
}

// --- Builtin table ---

pub const builtins = [_]BuiltinDef{
    // Trigonometric
    .{ .name = "sin", .func = &sinFn, .doc = "Returns the sine of an angle.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "cos", .func = &cosFn, .doc = "Returns the cosine of an angle.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "tan", .func = &tanFn, .doc = "Returns the tangent of an angle.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "asin", .func = &asinFn, .doc = "Returns the arc sine of a value.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "acos", .func = &acosFn, .doc = "Returns the arc cosine of a value.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "atan", .func = &atanFn, .doc = "Returns the arc tangent of a value.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "atan2", .func = &atan2Fn, .doc = "Returns the angle theta from the conversion of rectangular coordinates (x, y) to polar coordinates (r, theta).", .arglists = "([y x])", .added = "1.11" },
    // Hyperbolic
    .{ .name = "sinh", .func = &sinhFn, .doc = "Returns the hyperbolic sine of a value.", .arglists = "([x])", .added = "1.11" },
    .{ .name = "cosh", .func = &coshFn, .doc = "Returns the hyperbolic cosine of a value.", .arglists = "([x])", .added = "1.11" },
    .{ .name = "tanh", .func = &tanhFn, .doc = "Returns the hyperbolic tangent of a value.", .arglists = "([x])", .added = "1.11" },
    // Exponential / Logarithmic
    .{ .name = "exp", .func = &expFn, .doc = "Returns Euler's number e raised to the power of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "expm1", .func = &expm1Fn, .doc = "Returns e^x - 1.", .arglists = "([x])", .added = "1.11" },
    .{ .name = "log", .func = &logFn, .doc = "Returns the natural logarithm (base e) of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "log10", .func = &log10Fn, .doc = "Returns the base 10 logarithm of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "log1p", .func = &log1pFn, .doc = "Returns ln(1+x).", .arglists = "([x])", .added = "1.11" },
    // Power / Root
    .{ .name = "pow", .func = &powFn, .doc = "Returns the value of a raised to the power of b.", .arglists = "([a b])", .added = "1.11" },
    .{ .name = "sqrt", .func = &sqrtFn, .doc = "Returns the positive square root of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "cbrt", .func = &cbrtFn, .doc = "Returns the cube root of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "hypot", .func = &hypotFn, .doc = "Returns sqrt(x^2 + y^2) without intermediate overflow or underflow.", .arglists = "([x y])", .added = "1.11" },
    // Rounding
    .{ .name = "ceil", .func = &ceilFn, .doc = "Returns the smallest double value >= a and is a mathematical integer.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "floor", .func = &floorMathFn, .doc = "Returns the largest double value <= a and is a mathematical integer.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "rint", .func = &rintFn, .doc = "Returns the closest double to a that is a mathematical integer.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "round", .func = &roundFn, .doc = "Returns the closest long to a, with ties rounding to positive infinity.", .arglists = "([a])", .added = "1.11" },
    // Sign / Magnitude
    .{ .name = "signum", .func = &signumFn, .doc = "Returns the signum function of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "copy-sign", .func = &copySignFn, .doc = "Returns a value with the magnitude of the first argument and the sign of the second.", .arglists = "([magnitude sign])", .added = "1.11" },
    // IEEE
    .{ .name = "IEEE-remainder", .func = &ieeeRemainderFn, .doc = "Returns the remainder operation on two arguments as prescribed by the IEEE 754 standard.", .arglists = "([dividend divisor])", .added = "1.11" },
    .{ .name = "ulp", .func = &ulpFn, .doc = "Returns the size of an ulp of a.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "get-exponent", .func = &getExponentFn, .doc = "Returns the unbiased exponent used in the representation of a double.", .arglists = "([d])", .added = "1.11" },
    .{ .name = "next-after", .func = &nextAfterFn, .doc = "Returns the adjacent floating-point value in the direction of the second argument.", .arglists = "([start direction])", .added = "1.11" },
    .{ .name = "next-up", .func = &nextUpFn, .doc = "Returns the adjacent floating-point value in the direction of positive infinity.", .arglists = "([d])", .added = "1.11" },
    .{ .name = "next-down", .func = &nextDownFn, .doc = "Returns the adjacent floating-point value in the direction of negative infinity.", .arglists = "([d])", .added = "1.11" },
    .{ .name = "scalb", .func = &scalbFn, .doc = "Returns d * 2^scaleFactor.", .arglists = "([d scaleFactor])", .added = "1.11" },
    // Exact arithmetic
    .{ .name = "add-exact", .func = &addExactFn, .doc = "Returns the sum of x and y, throws on overflow.", .arglists = "([x y])", .added = "1.11" },
    .{ .name = "subtract-exact", .func = &subtractExactFn, .doc = "Returns the difference of x and y, throws on overflow.", .arglists = "([x y])", .added = "1.11" },
    .{ .name = "multiply-exact", .func = &multiplyExactFn, .doc = "Returns the product of x and y, throws on overflow.", .arglists = "([x y])", .added = "1.11" },
    .{ .name = "increment-exact", .func = &incrementExactFn, .doc = "Returns a + 1, throws on overflow.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "decrement-exact", .func = &decrementExactFn, .doc = "Returns a - 1, throws on overflow.", .arglists = "([a])", .added = "1.11" },
    .{ .name = "negate-exact", .func = &negateExactFn, .doc = "Returns -a, throws on overflow.", .arglists = "([a])", .added = "1.11" },
    // Integer division
    .{ .name = "floor-div", .func = &floorDivFn, .doc = "Integer division that rounds to negative infinity.", .arglists = "([x y])", .added = "1.11" },
    .{ .name = "floor-mod", .func = &floorModFn, .doc = "Integer modulus, result has same sign as divisor.", .arglists = "([x y])", .added = "1.11" },
    // Conversion
    .{ .name = "to-radians", .func = &toRadiansFn, .doc = "Converts an angle measured in degrees to radians.", .arglists = "([deg])", .added = "1.11" },
    .{ .name = "to-degrees", .func = &toDegreesFn, .doc = "Converts an angle measured in radians to degrees.", .arglists = "([rad])", .added = "1.11" },
    // Random
    .{ .name = "random", .func = &numeric.randFn, .doc = "Returns a positive double between 0.0 and 1.0, chosen pseudorandomly.", .arglists = "([])", .added = "1.11" },
};

// --- Constants (registered separately in registry.zig) ---

pub const PI: f64 = std.math.pi;
pub const E: f64 = std.math.e;

// --- Tests ---

const testing = std.testing;
const test_alloc = testing.allocator;

test "sin" {
    const r = try sinFn(test_alloc, &.{floatVal(0.0)});
    try testing.expectEqual(@as(f64, 0.0), r.asFloat());
}

test "cos" {
    const r = try cosFn(test_alloc, &.{floatVal(0.0)});
    try testing.expectEqual(@as(f64, 1.0), r.asFloat());
}

test "sqrt" {
    const r = try sqrtFn(test_alloc, &.{floatVal(4.0)});
    try testing.expectEqual(@as(f64, 2.0), r.asFloat());
}

test "round NaN" {
    const r = try roundFn(test_alloc, &.{floatVal(std.math.nan(f64))});
    try testing.expectEqual(@as(i64, 0), r.asInteger());
}

test "round 3.5" {
    const r = try roundFn(test_alloc, &.{floatVal(3.5)});
    try testing.expectEqual(@as(i64, 4), r.asInteger());
}

test "add-exact overflow" {
    // NaN boxing: integer range is i48, so use i48 max for overflow test
    try testing.expectError(error.ArithmeticError, addExactFn(test_alloc, &.{intVal((1 << 47) - 1), intVal(1)}));
}

test "floor-div" {
    const r = try floorDivFn(test_alloc, &.{intVal(-2), intVal(5)});
    try testing.expectEqual(@as(i64, -1), r.asInteger());
}

test "floor-mod" {
    const r = try floorModFn(test_alloc, &.{intVal(-2), intVal(5)});
    try testing.expectEqual(@as(i64, 3), r.asInteger());
}

test "builtins table has 43 entries" {
    try testing.expectEqual(43, builtins.len);
}
