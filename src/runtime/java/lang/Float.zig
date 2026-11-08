// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Float` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/float
//!
//! Values are f64: cljw has no f32 representation, so every `Float/*`
//! method takes and returns the single-double tower exactly as
//! `clojure.core/float` does (AD-004). The static fields are Java's real
//! `float` constants widened to f64, and the three bit conversions narrow
//! to f32 because their contract is defined on the 32-bit pattern.
//! Parsing delegates to the shared `runtime/numeric/parse.zig` leaf, so
//! `Float/parseFloat` trims surrounding whitespace and rejects `_` exactly
//! as `Double/parseDouble` does; malformed input raises a `number_error`-Kind
//! Code → NumberFormatException (ADR-0060).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const parse = @import("../../numeric/parse.zig");
const string_mod = @import("../../collection/string.zig");
const print_mod = @import("../../print.zig");

/// Implements `(Float/parseFloat s)`. Spec: parse a float; malformed ⇒
/// NumberFormatException. Surrounding whitespace is trimmed (Java).
/// JVM reference: java.lang.Float#parseFloat.
/// cw v1 tier: A (§A26 clj differential sweep).
fn parseFloat(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/parseFloat", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Float/parseFloat", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    const f = parse.parseFloat(s) catch
        return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Float/parseFloat", .text = s });
    return Value.initFloat(f);
}

/// `Float/isNaN`, `isInfinite` and `isFinite` share one shape: widen the
/// number arg to f64 and apply the std.math predicate.
fn Predicate(comptime name: []const u8, comptime f: fn (f64) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Float/" ++ name, args, 1, loc);
            const x = try error_catalog.expectNumber(args[0], "Float/" ++ name, loc);
            return if (f(x)) .true_val else .false_val;
        }
    };
}

fn isNanF(x: f64) bool {
    return std.math.isNan(x);
}
fn isInfF(x: f64) bool {
    return std.math.isInf(x);
}
fn isFiniteF(x: f64) bool {
    return !std.math.isNan(x) and !std.math.isInf(x);
}

/// `(Float/toString f)` — the value's print form (same as `(str f)`).
/// JVM reference: java.lang.Float#toString.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Float/toString", args, 1, loc);
    const x = try error_catalog.expectNumber(args[0], "Float/toString", loc);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try print_mod.printFloat(&w, x);
    return string_mod.alloc(rt, w.buffered());
}

/// `(Float/valueOf x)` — a String parses (like parseFloat), a number widens.
/// JVM reference: java.lang.Float#valueOf.
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/valueOf", args, 1, loc);
    if (args[0].tag() == .string) {
        const s = string_mod.asString(args[0]);
        const f = parse.parseFloat(s) catch
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Float/valueOf", .text = s });
        return Value.initFloat(f);
    }
    return Value.initFloat(try error_catalog.expectNumber(args[0], "Float/valueOf", loc));
}

/// `(Float. x)` / `(new Float x)`: a String parses (NumberFormatException when
/// malformed), a float is itself (cljw has no separate float width, AD-004).
/// Answers the plain cljw value (ADR-0059). An integer matches no ctor, as in
/// clj. JVM reference: java.lang.Float#Float(float|double|String).
fn ctor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float.", args, 1, loc);
    return switch (args[0].tag()) {
        .string => blk: {
            const s = string_mod.asString(args[0]);
            const f = parse.parseFloat(s) catch
                return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Float.", .text = s });
            break :blk Value.initFloat(f);
        },
        .float => args[0],
        else => error_catalog.raise(.ctor_unmatched, loc, .{ .class = "java.lang.Float" }),
    };
}

/// JVM `Float.floatToIntBits` total order: all NaNs collapse to one canonical
/// bit pattern; -0.0 sorts below +0.0. Narrows to f32 first — the contract is
/// defined on the 32-bit pattern. Used by `compare` and `hashCode`.
fn floatToIntBits(x: f64) i32 {
    if (std.math.isNan(x)) return @bitCast(@as(u32, 0x7fc00000));
    return @bitCast(@as(f32, @floatCast(x)));
}

/// JVM `Float.compare`: the `floatToIntBits` total order, so -0.0 < +0.0 and
/// NaN is greatest. The raw `<`/`>` (which treats ±0.0 as equal and orders
/// NaN nowhere) only resolves the strict-inequality cases; the bit-order
/// tie-break covers ±0.0 and any-NaN.
fn fcompare(a: f64, b: f64) i64 {
    if (a < b) return -1;
    if (a > b) return 1;
    const ab = floatToIntBits(a);
    const bb = floatToIntBits(b);
    return if (ab == bb) 0 else if (ab < bb) -1 else 1;
}

/// `Float/compare` / `max` / `min` / `sum`: two-number statics.
/// JVM reference: java.lang.Float#compare/max/min/sum.
const FBinop = enum { compare, max, min, sum };
fn FBinOp2(comptime op: FBinop, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Float/" ++ name, args, 2, loc);
            const a = try error_catalog.expectNumber(args[0], "Float/" ++ name, loc);
            const b = try error_catalog.expectNumber(args[1], "Float/" ++ name, loc);
            return switch (op) {
                .compare => Value.initInteger(fcompare(a, b)),
                .max => Value.initFloat(@max(a, b)),
                .min => Value.initFloat(@min(a, b)),
                .sum => Value.initFloat(a + b),
            };
        }
    };
}

/// `(Float/floatToIntBits f)` — the IEEE-754 single-precision bit pattern as
/// an int, with every NaN collapsed to the canonical `0x7fc00000` (Java total
/// order). JVM reference: java.lang.Float#floatToIntBits.
fn floatToIntBitsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/floatToIntBits", args, 1, loc);
    const x = try error_catalog.expectNumber(args[0], "Float/floatToIntBits", loc);
    return Value.initInteger(@as(i64, floatToIntBits(x)));
}

/// `(Float/floatToRawIntBits f)` — the RAW single-precision bit pattern,
/// preserving a non-canonical NaN's bits (unlike floatToIntBits).
/// JVM reference: java.lang.Float#floatToRawIntBits.
fn floatToRawIntBitsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/floatToRawIntBits", args, 1, loc);
    const x = try error_catalog.expectNumber(args[0], "Float/floatToRawIntBits", loc);
    const bits: i32 = @bitCast(@as(f32, @floatCast(x)));
    return Value.initInteger(@as(i64, bits));
}

/// `(Float/intBitsToFloat bits)` — the float with the given IEEE-754
/// single-precision bit pattern, widened into the f64 tower.
/// JVM reference: java.lang.Float#intBitsToFloat.
fn intBitsToFloat(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/intBitsToFloat", args, 1, loc);
    const bits = try error_catalog.expectI64(args[0], "Float/intBitsToFloat", loc);
    const narrowed: i32 = @truncate(bits);
    const f: f32 = @bitCast(narrowed);
    return Value.initFloat(@as(f64, f));
}

/// `(Float/hashCode f)` — Java's `floatToIntBits`. JVM reference:
/// java.lang.Float#hashCode.
fn hashCode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Float/hashCode", args, 1, loc);
    const x = try error_catalog.expectNumber(args[0], "Float/hashCode", loc);
    return Value.initInteger(@as(i64, floatToIntBits(x)));
}

fn initFloat(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseFloat", &parseFloat },
        .{ "isNaN", &Predicate("isNaN", isNanF).call },
        .{ "isInfinite", &Predicate("isInfinite", isInfF).call },
        .{ "isFinite", &Predicate("isFinite", isFiniteF).call },
        .{ "toString", &toString },
        .{ "valueOf", &valueOf },
        .{ "<init>", &ctor },
        .{ "compare", &FBinOp2(.compare, "compare").call },
        .{ "max", &FBinOp2(.max, "max").call },
        .{ "min", &FBinOp2(.min, "min").call },
        .{ "sum", &FBinOp2(.sum, "sum").call },
        .{ "floatToIntBits", &floatToIntBitsFn },
        .{ "floatToRawIntBits", &floatToRawIntBitsFn },
        .{ "intBitsToFloat", &intBitsToFloat },
        .{ "hashCode", &hashCode },
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
    .cljw_ns = "cljw.java.lang.Float",
    .descriptor = &descriptor,
    .init = &initFloat,
};

// Static fields (ADR-0061) — comptime-const. Java Float.MAX_VALUE /
// MIN_VALUE = the largest finite float / smallest positive denormal, widened
// to f64 exactly (every f32 is an f64).
const float_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .float = std.math.floatMax(f32) } },
    .{ .name = "MIN_VALUE", .value = .{ .float = std.math.floatTrueMin(f32) } },
    // The special IEEE-754 values (Float.NaN / ±Infinity). Identical to the
    // f64 spellings — the collapse is exact for these three.
    .{ .name = "NaN", .value = .{ .float = std.math.nan(f64) } },
    .{ .name = "POSITIVE_INFINITY", .value = .{ .float = std.math.inf(f64) } },
    .{ .name = "NEGATIVE_INFINITY", .value = .{ .float = -std.math.inf(f64) } },
    // Unbiased binary exponent bounds of a normal float (int constants).
    .{ .name = "MAX_EXPONENT", .value = .{ .int = 127 } },
    .{ .name = "MIN_EXPONENT", .value = .{ .int = -126 } },
    .{ .name = "MIN_NORMAL", .value = .{ .float = std.math.floatMin(f32) } },
    .{ .name = "BYTES", .value = .{ .int = 4 } },
    .{ .name = "SIZE", .value = .{ .int = 32 } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Float",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &float_static_fields,
    .parent = null,
    .meta = .nil_val,
};
