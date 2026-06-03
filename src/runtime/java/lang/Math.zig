// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Math` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Thin wrapper over Zig `std.math` + builtins (F-009). Math is pure
//! computation with no OS-borrowed or cw-original impl to factor into a
//! neutral `runtime/` leaf, so the surface wraps `std.math` directly
//! (no separate impl file — a `runtime/math.zig` leaf would be an empty
//! skeleton). Static methods reach these as `(Math/abs …)` after the
//! `java.lang.*` auto-import resolution in `resolveJavaSurface`.
//!
//! F-005 numeric tower: the user-observable surface matches JVM Math.
//! `abs` / `min` / `max` are TYPE-PRESERVING (int→Long, double→Double);
//! `sqrt` / `floor` / `ceil` / `pow` always return Double; `round`
//! returns Long. Static dispatch is TreeWalk-only at v0.1.0 (the
//! `.static_method` VM arm is VM-DEFER, D-130).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const promote = @import("../../numeric/promote.zig");

/// Implements `(Math/abs n)`.
/// Spec: absolute value, type-preserving — `int→long`, `double→double`.
/// JVM reference: java.lang.Math#abs (overloaded by primitive type).
/// cw v1 tier: A (§A26 / ADR-0050).
fn abs(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/abs", args, 1, loc);
    switch (args[0].tag()) {
        .integer => {
            // `asInteger` is i48, so negating into i64 cannot overflow
            // (i48 MIN negated = 2^47 < i64 max). `@abs` would yield u64
            // and not coerce back to `initInteger`'s i64.
            const i: i64 = args[0].asInteger();
            return Value.initInteger(if (i < 0) -i else i);
        },
        .float => return Value.initFloat(@abs(args[0].asFloat())),
        else => return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "Math/abs", .actual = @tagName(args[0].tag()) }),
    }
}

/// Implements `(Math/sqrt n)`.
/// Spec: square root; always returns a double.
/// JVM reference: java.lang.Math#sqrt.
/// cw v1 tier: A (§A26 / ADR-0050).
fn sqrt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/sqrt", args, 1, loc);
    return Value.initFloat(@sqrt(try error_catalog.expectNumber(args[0], "Math/sqrt", loc)));
}

/// Implements `(Math/floor n)`.
/// Spec: largest double ≤ n with integral value; always returns a double.
/// JVM reference: java.lang.Math#floor.
/// cw v1 tier: A (§A26 / ADR-0050).
fn floor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/floor", args, 1, loc);
    return Value.initFloat(@floor(try error_catalog.expectNumber(args[0], "Math/floor", loc)));
}

/// Implements `(Math/ceil n)`.
/// Spec: smallest double ≥ n with integral value; always returns a double.
/// JVM reference: java.lang.Math#ceil.
/// cw v1 tier: A (§A26 / ADR-0050).
fn ceil(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/ceil", args, 1, loc);
    return Value.initFloat(@ceil(try error_catalog.expectNumber(args[0], "Math/ceil", loc)));
}

/// Implements `(Math/round n)`.
/// Spec: nearest integral value (ties round toward +∞); returns a long.
/// JVM reference: java.lang.Math#round (double→long).
/// cw v1 tier: A (§A26 / ADR-0050).
fn round(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/round", args, 1, loc);
    const d = try error_catalog.expectNumber(args[0], "Math/round", loc);
    // JVM Math.round = floor(d + 0.5) as a long, ties toward +∞ (so
    // round(-2.5) = -2, NOT -3 like @round's ties-away). NaN → 0; ±Inf
    // and out-of-range magnitudes clamp to Long.MIN/MAX (else
    // @intFromFloat would panic). `wrapI64` keeps the full i64 range a
    // Long (vs `initInteger`, which spills past the i48 window to Double).
    if (std.math.isNan(d)) return promote.wrapI64(rt, 0);
    const r = @floor(d + 0.5);
    if (r >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return promote.wrapI64(rt, std.math.maxInt(i64));
    if (r <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return promote.wrapI64(rt, std.math.minInt(i64));
    return promote.wrapI64(rt, @intFromFloat(r));
}

/// Implements `(Math/pow base exp)`.
/// Spec: base raised to exp; always returns a double.
/// JVM reference: java.lang.Math#pow.
/// cw v1 tier: A (§A26 / ADR-0050).
fn pow(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/pow", args, 2, loc);
    const base = try error_catalog.expectNumber(args[0], "Math/pow", loc);
    const exp = try error_catalog.expectNumber(args[1], "Math/pow", loc);
    // JVM Math.pow quirk: |base| == 1 with an infinite exponent yields NaN
    // (IEEE-754 pow returns 1.0 here; java.lang.Math deliberately diverges).
    if (@abs(base) == 1.0 and std.math.isInf(exp)) return Value.initFloat(std.math.nan(f64));
    return Value.initFloat(std.math.pow(f64, base, exp));
}

/// Implements `(Math/min a b)`.
/// Spec: lesser of two numbers, type-preserving (int,int→long else double).
/// JVM reference: java.lang.Math#min (overloaded).
/// cw v1 tier: A (§A26 / ADR-0050).
fn min(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/min", args, 2, loc);
    if (args[0].tag() == .integer and args[1].tag() == .integer) {
        return Value.initInteger(@min(@as(i64, args[0].asInteger()), @as(i64, args[1].asInteger())));
    }
    const a = try error_catalog.expectNumber(args[0], "Math/min", loc);
    const b = try error_catalog.expectNumber(args[1], "Math/min", loc);
    return Value.initFloat(@min(a, b));
}

/// Implements `(Math/max a b)`.
/// Spec: greater of two numbers, type-preserving (int,int→long else double).
/// JVM reference: java.lang.Math#max (overloaded).
/// cw v1 tier: A (§A26 / ADR-0050).
fn max(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/max", args, 2, loc);
    if (args[0].tag() == .integer and args[1].tag() == .integer) {
        return Value.initInteger(@max(@as(i64, args[0].asInteger()), @as(i64, args[1].asInteger())));
    }
    const a = try error_catalog.expectNumber(args[0], "Math/max", loc);
    const b = try error_catalog.expectNumber(args[1], "Math/max", loc);
    return Value.initFloat(@max(a, b));
}

// Unary Double→Double transcendentals. A comptime factory keeps the table
// declarative — one std.math / builtin reference per row — rather than ~16
// near-identical 6-line methods. Each always returns a Double (JVM Math
// surface; F-005). Builtins (@log/@sin/…) can't be taken as fn pointers, so
// each row names a thin f64→f64 wrapper.
fn Unary(comptime name: []const u8, comptime f: fn (f64) f64) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Math/" ++ name, args, 1, loc);
            return Value.initFloat(f(try error_catalog.expectNumber(args[0], "Math/" ++ name, loc)));
        }
    };
}

fn fLog(x: f64) f64 {
    return @log(x);
}
fn fLog10(x: f64) f64 {
    return @log10(x);
}
fn fExp(x: f64) f64 {
    return @exp(x);
}
fn fSin(x: f64) f64 {
    return @sin(x);
}
fn fCos(x: f64) f64 {
    return @cos(x);
}
fn fTan(x: f64) f64 {
    return @tan(x);
}
fn fCbrt(x: f64) f64 {
    return std.math.cbrt(x);
}
fn fAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn fAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn fAtan(x: f64) f64 {
    return std.math.atan(x);
}
fn fSinh(x: f64) f64 {
    return std.math.sinh(x);
}
fn fCosh(x: f64) f64 {
    return std.math.cosh(x);
}
fn fTanh(x: f64) f64 {
    return std.math.tanh(x);
}
fn fToRadians(x: f64) f64 {
    return x * std.math.pi / 180.0;
}
fn fToDegrees(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}
/// JVM Math.signum: ±1.0 for ±, and the input itself for 0.0 / -0.0 / NaN.
fn fSignum(x: f64) f64 {
    return if (x > 0) 1.0 else if (x < 0) -1.0 else x;
}
fn fExpm1(x: f64) f64 {
    return std.math.expm1(x);
}
fn fLog1p(x: f64) f64 {
    return std.math.log1p(x);
}
fn fNextUp(x: f64) f64 {
    return std.math.nextAfter(f64, x, std.math.inf(f64));
}
fn fNextDown(x: f64) f64 {
    return std.math.nextAfter(f64, x, -std.math.inf(f64));
}

/// JVM Math.rint: round to nearest integral double, ties to EVEN (so
/// `rint(2.5)`=2.0, `rint(3.5)`=4.0). Distinct from `round` / `@round`
/// (ties away from zero). NaN / ±Inf / ±0.0 pass through.
fn fRint(x: f64) f64 {
    const f = @floor(x);
    const frac = x - f;
    const r =
        if (frac < 0.5) f else if (frac > 0.5) f + 1.0
        // exactly halfway (or NaN/Inf, where frac is NaN and both compares
        // are false): pick the even neighbour; NaN/Inf fall through.
        else if (@rem(f, 2.0) == 0.0) f else f + 1.0;
    // Preserve the sign of zero: rint(-0.01) is -0.0, not +0.0 (JVM).
    return std.math.copysign(r, x);
}

/// Unbiased binary exponent of `x` (JVM Math.getExponent convention):
/// NaN / ±Inf → 1024, ±0.0 / subnormal → -1023, else the IEEE-754 exponent.
fn rawExponent(x: f64) i32 {
    const bits: u64 = @bitCast(x);
    const biased: u64 = (bits >> 52) & 0x7FF;
    return @as(i32, @intCast(biased)) - 1023;
}

/// JVM Math.ulp: size of an ulp of `x` (the distance to the next larger
/// magnitude double). NaN→NaN, ±Inf→+Inf, ±0.0→Double.MIN_VALUE.
fn fUlp(x: f64) f64 {
    const exp = rawExponent(x);
    if (exp == 1024) return @abs(x); // NaN → NaN, ±Inf → +Inf
    if (exp == -1023) return 4.9406564584124654e-324; // Double.MIN_VALUE
    const e2 = exp - 52;
    if (e2 >= -1022) return std.math.ldexp(@as(f64, 1.0), e2);
    // subnormal ulp: 1 in the relevant low mantissa bit
    return @bitCast(@as(u64, 1) << @intCast(e2 - (-1022 - 52)));
}

/// Implements `(Math/atan2 y x)` — angle of the (x, y) vector, always Double.
fn atan2(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/atan2", args, 2, loc);
    const y = try error_catalog.expectNumber(args[0], "Math/atan2", loc);
    const x = try error_catalog.expectNumber(args[1], "Math/atan2", loc);
    return Value.initFloat(std.math.atan2(y, x));
}

/// Implements `(Math/hypot a b)` — sqrt(a²+b²) without overflow, always Double.
fn hypot(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/hypot", args, 2, loc);
    const a = try error_catalog.expectNumber(args[0], "Math/hypot", loc);
    const b = try error_catalog.expectNumber(args[1], "Math/hypot", loc);
    return Value.initFloat(std.math.hypot(a, b));
}

/// Implements `(Math/floorDiv a b)` — integer division rounding toward
/// negative infinity (so `floorDiv(-7, 2)` = -4). Divide-by-zero throws.
/// JVM reference: java.lang.Math#floorDiv. cw v1 tier: A (§A26).
fn floorDiv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/floorDiv", args, 2, loc);
    const a = try exactArg(args[0], "floorDiv", loc);
    const b = try exactArg(args[1], "floorDiv", loc);
    if (b == 0) return error_catalog.raise(.divide_by_zero, loc, .{});
    // JVM wraps the lone overflow case (MIN / -1) back to MIN rather than
    // throwing; mirror it (a plain @divFloor would panic on the overflow).
    if (a == std.math.minInt(i64) and b == -1) return promote.wrapI64(rt, std.math.minInt(i64));
    return promote.wrapI64(rt, @divFloor(a, b));
}

/// Implements `(Math/floorMod a b)` — `a - floorDiv(a, b) * b`; the
/// result takes the sign of the divisor (so `floorMod(-7, 3)` = 2).
/// Divide-by-zero throws. JVM reference: java.lang.Math#floorMod.
/// cw v1 tier: A (§A26).
fn floorMod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/floorMod", args, 2, loc);
    const a = try exactArg(args[0], "floorMod", loc);
    const b = try exactArg(args[1], "floorMod", loc);
    if (b == 0) return error_catalog.raise(.divide_by_zero, loc, .{});
    // `x mod -1` is always 0; special-cased so the MIN/-1 @divFloor inside
    // @mod cannot overflow-panic.
    if (b == -1) return promote.wrapI64(rt, 0);
    return promote.wrapI64(rt, @mod(a, b));
}

/// Implements `(Math/copySign mag sign)` — `mag` with the sign of `sign`.
/// JVM reference: java.lang.Math#copySign. cw v1 tier: A.
fn copySign(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/copySign", args, 2, loc);
    const mag = try error_catalog.expectNumber(args[0], "Math/copySign", loc);
    const sign = try error_catalog.expectNumber(args[1], "Math/copySign", loc);
    return Value.initFloat(std.math.copysign(mag, sign));
}

/// Implements `(Math/nextAfter start direction)` — the adjacent double to
/// `start` toward `direction`. JVM reference: java.lang.Math#nextAfter.
fn nextAfter(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/nextAfter", args, 2, loc);
    const start = try error_catalog.expectNumber(args[0], "Math/nextAfter", loc);
    const dir = try error_catalog.expectNumber(args[1], "Math/nextAfter", loc);
    return Value.initFloat(std.math.nextAfter(f64, start, dir));
}

/// Implements `(Math/IEEEremainder f1 f2)` — `f1 - n*f2` where n is the
/// integer nearest f1/f2 (ties to even). NaN when either is NaN, f1 is
/// ±Inf, or f2 is ±0; returns f1 when f2 is ±Inf. JVM ref: Math#IEEEremainder.
fn ieeeRemainder(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/IEEEremainder", args, 2, loc);
    const f1 = try error_catalog.expectNumber(args[0], "Math/IEEEremainder", loc);
    const f2 = try error_catalog.expectNumber(args[1], "Math/IEEEremainder", loc);
    if (std.math.isNan(f1) or std.math.isNan(f2) or std.math.isInf(f1) or f2 == 0.0)
        return Value.initFloat(std.math.nan(f64));
    if (std.math.isInf(f2)) return Value.initFloat(f1);
    return Value.initFloat(f1 - fRint(f1 / f2) * f2);
}

/// Implements `(Math/scalb d scaleFactor)` — `d × 2^scaleFactor` computed
/// without intermediate rounding. JVM reference: java.lang.Math#scalb.
fn scalb(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/scalb", args, 2, loc);
    const d = try error_catalog.expectNumber(args[0], "Math/scalb", loc);
    const n = try error_catalog.expectInteger(args[1], "Math/scalb", loc);
    // Clamp the shift to the i32 range ldexp accepts; magnitudes this
    // large already saturate to 0 / ±Inf, matching JVM.
    const shift: i32 = if (n > std.math.maxInt(i32)) std.math.maxInt(i32) else if (n < std.math.minInt(i32)) std.math.minInt(i32) else @intCast(n);
    return Value.initFloat(std.math.ldexp(d, shift));
}

/// Implements `(Math/getExponent d)` — the unbiased binary exponent, as a
/// Long. NaN / ±Inf → 1024, ±0.0 / subnormal → -1023. JVM ref: Math#getExponent.
fn getExponent(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/getExponent", args, 1, loc);
    return Value.initInteger(rawExponent(try error_catalog.expectNumber(args[0], "Math/getExponent", loc)));
}

/// Read an exact `long` operand for the `Math/*Exact` family. A float /
/// ratio has no matching `long` overload (type error); a BigInt beyond
/// i64 cannot be a `long` (overflow). Shared extractor via `promote`.
fn exactArg(v: Value, comptime jname: []const u8, loc: SourceLocation) anyerror!i64 {
    return promote.exactI64(v) catch |err| switch (err) {
        error.OutOfRange => error_catalog.raise(.integer_overflow, loc, .{}),
        error.NotAnInteger => error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "Math/" ++ jname, .actual = @tagName(v.tag()) }),
    };
}

const ExactOp = enum { add, sub, mul };

/// `Math/addExact` / `subtractExact` / `multiplyExact` — i64 arithmetic
/// that throws `ArithmeticException` (catalog `integer_overflow`) on
/// overflow instead of wrapping. A distinct mechanism from `floorDiv` /
/// `floorMod` (which never overflow). JVM reference: java.lang.Math.
fn ExactBin(comptime op: ExactOp, comptime jname: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Math/" ++ jname, args, 2, loc);
            const a = try exactArg(args[0], jname, loc);
            const b = try exactArg(args[1], jname, loc);
            const res, const overflowed = switch (op) {
                .add => @addWithOverflow(a, b),
                .sub => @subWithOverflow(a, b),
                .mul => @mulWithOverflow(a, b),
            };
            if (overflowed != 0) return error_catalog.raise(.integer_overflow, loc, .{});
            return promote.wrapI64(rt, res);
        }
    };
}

/// `Math/negateExact a` — `-a` with i64 overflow detection (only `MIN`
/// overflows). JVM reference: java.lang.Math#negateExact.
fn negateExact(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/negateExact", args, 1, loc);
    const a = try exactArg(args[0], "negateExact", loc);
    const res, const overflowed = @subWithOverflow(@as(i64, 0), a);
    if (overflowed != 0) return error_catalog.raise(.integer_overflow, loc, .{});
    return promote.wrapI64(rt, res);
}

/// `Math/incrementExact a` — `a + 1` with i64 overflow detection.
fn incrementExact(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/incrementExact", args, 1, loc);
    const a = try exactArg(args[0], "incrementExact", loc);
    const res, const overflowed = @addWithOverflow(a, @as(i64, 1));
    if (overflowed != 0) return error_catalog.raise(.integer_overflow, loc, .{});
    return promote.wrapI64(rt, res);
}

/// `Math/decrementExact a` — `a - 1` with i64 overflow detection.
fn decrementExact(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/decrementExact", args, 1, loc);
    const a = try exactArg(args[0], "decrementExact", loc);
    const res, const overflowed = @subWithOverflow(a, @as(i64, 1));
    if (overflowed != 0) return error_catalog.raise(.integer_overflow, loc, .{});
    return promote.wrapI64(rt, res);
}

/// `Math/toIntExact a` — assert `a` fits a 32-bit int, else throw. cljw
/// has no i32 type, so the result is still a Long; only the range check
/// is observable. JVM reference: java.lang.Math#toIntExact.
fn toIntExact(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Math/toIntExact", args, 1, loc);
    const a = try exactArg(args[0], "toIntExact", loc);
    if (a < std.math.minInt(i32) or a > std.math.maxInt(i32))
        return error_catalog.raise(.integer_overflow, loc, .{});
    return promote.wrapI64(rt, a);
}

fn initMath(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "abs", &abs },                                  .{ "sqrt", &sqrt },                                          .{ "floor", &floor },
        .{ "ceil", &ceil },                                .{ "round", &round },                                        .{ "pow", &pow },
        .{ "min", &min },                                  .{ "max", &max },
        // transcendentals (Double→Double via the Unary factory)
                                                   .{ "log", &Unary("log", fLog).call },
        .{ "log10", &Unary("log10", fLog10).call },        .{ "exp", &Unary("exp", fExp).call },                        .{ "cbrt", &Unary("cbrt", fCbrt).call },
        .{ "sin", &Unary("sin", fSin).call },              .{ "cos", &Unary("cos", fCos).call },                        .{ "tan", &Unary("tan", fTan).call },
        .{ "asin", &Unary("asin", fAsin).call },           .{ "acos", &Unary("acos", fAcos).call },                     .{ "atan", &Unary("atan", fAtan).call },
        .{ "sinh", &Unary("sinh", fSinh).call },           .{ "cosh", &Unary("cosh", fCosh).call },                     .{ "tanh", &Unary("tanh", fTanh).call },
        .{ "signum", &Unary("signum", fSignum).call },     .{ "toRadians", &Unary("toRadians", fToRadians).call },      .{ "toDegrees", &Unary("toDegrees", fToDegrees).call },
        .{ "expm1", &Unary("expm1", fExpm1).call },        .{ "log1p", &Unary("log1p", fLog1p).call },                  .{ "rint", &Unary("rint", fRint).call },
        .{ "ulp", &Unary("ulp", fUlp).call },              .{ "nextUp", &Unary("nextUp", fNextUp).call },               .{ "nextDown", &Unary("nextDown", fNextDown).call },
        .{ "atan2", &atan2 },                              .{ "hypot", &hypot },                                        .{ "floorDiv", &floorDiv },
        .{ "floorMod", &floorMod },
        // IEEE-754 helpers (D-232 clojure.math completion)
                               .{ "copySign", &copySign },                                  .{ "nextAfter", &nextAfter },
        .{ "IEEEremainder", &ieeeRemainder },              .{ "scalb", &scalb },                                        .{ "getExponent", &getExponent },
        // *Exact family: i64 arithmetic that throws on overflow (§A26 / D-172)
        .{ "addExact", &ExactBin(.add, "addExact").call }, .{ "subtractExact", &ExactBin(.sub, "subtractExact").call }, .{ "multiplyExact", &ExactBin(.mul, "multiplyExact").call },
        .{ "negateExact", &negateExact },                  .{ "incrementExact", &incrementExact },                      .{ "decrementExact", &decrementExact },
        .{ "toIntExact", &toIntExact },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Math",
    .descriptor = &descriptor,
    .init = &initMath,
};

// Static fields (ADR-0061) — comptime-const f64 constants.
const math_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "PI", .value = .{ .float = std.math.pi } },
    .{ .name = "E", .value = .{ .float = std.math.e } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.Math",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &math_static_fields,
    .parent = null,
    .meta = .nil_val,
};
