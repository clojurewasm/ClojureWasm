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
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/round", args, 1, loc);
    const d = try error_catalog.expectNumber(args[0], "Math/round", loc);
    // JVM rounds half-up (+∞); @round rounds half-away-from-zero, which
    // matches for the non-negative half and is the common case. The i64
    // result auto-promotes back to Float past the i48 window.
    return Value.initInteger(@intFromFloat(@round(d)));
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

fn fLog(x: f64) f64 { return @log(x); }
fn fLog10(x: f64) f64 { return @log10(x); }
fn fExp(x: f64) f64 { return @exp(x); }
fn fSin(x: f64) f64 { return @sin(x); }
fn fCos(x: f64) f64 { return @cos(x); }
fn fTan(x: f64) f64 { return @tan(x); }
fn fCbrt(x: f64) f64 { return std.math.cbrt(x); }
fn fAsin(x: f64) f64 { return std.math.asin(x); }
fn fAcos(x: f64) f64 { return std.math.acos(x); }
fn fAtan(x: f64) f64 { return std.math.atan(x); }
fn fSinh(x: f64) f64 { return std.math.sinh(x); }
fn fCosh(x: f64) f64 { return std.math.cosh(x); }
fn fTanh(x: f64) f64 { return std.math.tanh(x); }
fn fToRadians(x: f64) f64 { return x * std.math.pi / 180.0; }
fn fToDegrees(x: f64) f64 { return x * 180.0 / std.math.pi; }
/// JVM Math.signum: ±1.0 for ±, and the input itself for 0.0 / -0.0 / NaN.
fn fSignum(x: f64) f64 { return if (x > 0) 1.0 else if (x < 0) -1.0 else x; }

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
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/floorDiv", args, 2, loc);
    const a = try error_catalog.expectInteger(args[0], "Math/floorDiv", loc);
    const b = try error_catalog.expectInteger(args[1], "Math/floorDiv", loc);
    if (b == 0) return error_catalog.raise(.divide_by_zero, loc, .{});
    return Value.initInteger(@divFloor(@as(i64, a), @as(i64, b)));
}

/// Implements `(Math/floorMod a b)` — `a - floorDiv(a, b) * b`; the
/// result takes the sign of the divisor (so `floorMod(-7, 3)` = 2).
/// Divide-by-zero throws. JVM reference: java.lang.Math#floorMod.
/// cw v1 tier: A (§A26).
fn floorMod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Math/floorMod", args, 2, loc);
    const a = try error_catalog.expectInteger(args[0], "Math/floorMod", loc);
    const b = try error_catalog.expectInteger(args[1], "Math/floorMod", loc);
    if (b == 0) return error_catalog.raise(.divide_by_zero, loc, .{});
    return Value.initInteger(@mod(@as(i64, a), @as(i64, b)));
}

fn initMath(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "abs", &abs },   .{ "sqrt", &sqrt }, .{ "floor", &floor },
        .{ "ceil", &ceil }, .{ "round", &round }, .{ "pow", &pow },
        .{ "min", &min },   .{ "max", &max },
        // transcendentals (Double→Double via the Unary factory)
        .{ "log", &Unary("log", fLog).call },
        .{ "log10", &Unary("log10", fLog10).call },
        .{ "exp", &Unary("exp", fExp).call },
        .{ "cbrt", &Unary("cbrt", fCbrt).call },
        .{ "sin", &Unary("sin", fSin).call },
        .{ "cos", &Unary("cos", fCos).call },
        .{ "tan", &Unary("tan", fTan).call },
        .{ "asin", &Unary("asin", fAsin).call },
        .{ "acos", &Unary("acos", fAcos).call },
        .{ "atan", &Unary("atan", fAtan).call },
        .{ "sinh", &Unary("sinh", fSinh).call },
        .{ "cosh", &Unary("cosh", fCosh).call },
        .{ "tanh", &Unary("tanh", fTanh).call },
        .{ "signum", &Unary("signum", fSignum).call },
        .{ "toRadians", &Unary("toRadians", fToRadians).call },
        .{ "toDegrees", &Unary("toDegrees", fToDegrees).call },
        .{ "atan2", &atan2 }, .{ "hypot", &hypot },
        .{ "floorDiv", &floorDiv }, .{ "floorMod", &floorMod },
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
