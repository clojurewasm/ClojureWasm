// SPDX-License-Identifier: EPL-2.0
//! The `java.lang.Number` instance surface shared by every numeric value:
//! `.intValue` / `.longValue` / `.shortValue` / `.byteValue` /
//! `.doubleValue` / `.floatValue`, plus the per-class `.compareTo` /
//! `.equals` / `.hashCode` with their JVM (not clj `=`/`hash`) semantics, and
//! `.isNaN` / `.isInfinite` on a Double. One implementation serves the
//! `.integer` (Long), `.float` (Double), `.big_int` (BigInt, and a heap-boxed
//! Long past i48, D-165), `.ratio` (Ratio) and `.big_decimal` (BigDecimal)
//! native descriptors: this module installs the Long and Double tables,
//! `bigint_methods.zig` / `ratio_methods.zig` splice `specs` into theirs, and
//! `java/math/BigDecimal.zig` splices `value_specs` (it keeps its own
//! scale-aware `.compareTo` / `.equals`), so the five classes cannot drift
//! apart.
//!
//! Narrowing follows the JLS and the clj classes: a Long / BigInt narrows by
//! keeping the low bits; a BigDecimal truncates toward zero exactly and then
//! keeps the low bits (`toBigInteger().longValue()`); a Double truncates
//! toward zero and saturates to the target (`int` for int/short/byte, `long`
//! for long), NaN giving 0, then short/byte keep the low bits of that int; a
//! Ratio's int/short/byte go through its double (clj `Ratio.intValue`) while
//! `.longValue` truncates the exact quotient. Every `.doubleValue` is
//! `promote.toF64`, the one conversion `double` and float contagion also use.
//! `.floatValue` answers what `(float x)` does, the double itself: cljw has no
//! f32 value (AD-004), and narrowing here alone would make
//! `(= (float x) (.floatValue x))` false where clj has it true.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/int, clojure.core/long, clojure.core/double
//!   (checked coercions; these are the unchecked Number methods).

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const type_descriptor = @import("type_descriptor.zig");
const big_int = @import("numeric/big_int.zig");
const ratio_mod = @import("numeric/ratio.zig");
const big_decimal = @import("numeric/big_decimal.zig");
const promote = @import("numeric/promote.zig");
const Managed = std.math.big.int.Managed;
const Const = std.math.big.int.Const;
const Limb = std.math.big.Limb;

/// The JVM class a numeric receiver belongs to. A heap Long (`.big_int` with
/// `.long` origin) is a Long; `.equals` / `.compareTo` are class-gated on it.
const Class = enum { long, double, bigint, ratio, bigdecimal, other };

fn classOf(v: Value) Class {
    return switch (v.tag()) {
        .integer => .long,
        .float => .double,
        .big_int => if (big_int.originOf(v) == .long) .long else .bigint,
        .ratio => .ratio,
        .big_decimal => .bigdecimal,
        else => .other,
    };
}

/// The low 64 bits of an integer's two's-complement form (JLS narrowing).
fn lowI64(c: Const) i64 {
    var mag: u64 = 0;
    const per = @bitSizeOf(Limb);
    const n = @min(c.limbs.len, 64 / per);
    for (c.limbs[0..n], 0..) |limb, i| mag |= @as(u64, limb) << @intCast(i * per);
    const s: i64 = @bitCast(mag);
    return if (c.positive) s else 0 -% s;
}

/// A Ratio truncated toward zero, low 64 bits (clj `Ratio.longValue` is
/// `bigIntegerValue().longValue()`).
fn ratioTruncI64(rt: *Runtime, v: Value) !i64 {
    return switch (ratio_mod.parts(v)) {
        .small => |s| @divTrunc(s.n, s.d),
        .big => |b| blk: {
            var q = try Managed.init(rt.gc.infra);
            defer q.deinit();
            var r = try Managed.init(rt.gc.infra);
            defer r.deinit();
            try q.divTrunc(&r, b.n.m, b.d.m);
            break :blk lowI64(q.toConst());
        },
    };
}

/// A BigDecimal truncated toward zero, low 64 bits (JVM `BigDecimal.longValue`
/// is `toBigInteger().longValue()`; `.intValue` keeps the low 32 of it).
fn bigDecimalTruncI64(rt: *Runtime, v: Value) !i64 {
    const truncated = try big_decimal.truncate(rt, v);
    return lowI64(big_decimal.asUnscaled(truncated).m.toConst());
}

/// JLS d2i / d2l: truncate toward zero, saturate at the target's bounds, NaN
/// gives 0.
fn saturate(comptime T: type, d: f64) T {
    if (std.math.isNan(d)) return 0;
    if (d >= @as(f64, @floatFromInt(std.math.maxInt(T)))) return std.math.maxInt(T);
    if (d <= @as(f64, @floatFromInt(std.math.minInt(T)))) return std.math.minInt(T);
    return @intFromFloat(@trunc(d));
}

/// The receiver as a Java `int` (the basis short/byte narrow from).
fn intOf(rt: *Runtime, v: Value) !i32 {
    return switch (v.tag()) {
        .integer => @truncate(@as(i64, v.asInteger())),
        .big_int => @truncate(lowI64(big_int.asManaged(v).toConst())),
        .big_decimal => @truncate(try bigDecimalTruncI64(rt, v)),
        else => saturate(i32, try promote.toF64(v)), // float, ratio (clj Ratio.intValue)
    };
}

/// The receiver as a Java `long`.
fn longOf(rt: *Runtime, v: Value) !i64 {
    return switch (v.tag()) {
        .integer => v.asInteger(),
        .big_int => lowI64(big_int.asManaged(v).toConst()),
        .ratio => ratioTruncI64(rt, v),
        .big_decimal => bigDecimalTruncI64(rt, v),
        else => saturate(i64, try promote.toF64(v)),
    };
}

/// The primitive a Number method narrows to. There is no `float` width:
/// `.floatValue` shares `.doubleValue` (AD-004).
const Width = enum { int, long, short, byte, double };

fn ValueOf(comptime w: Width, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity(name, args, 1, loc);
            const v = args[0];
            return switch (w) {
                .int => Value.initInteger(try intOf(rt, v)),
                .short => Value.initInteger(@as(i16, @truncate(try intOf(rt, v)))),
                .byte => Value.initInteger(@as(i8, @truncate(try intOf(rt, v)))),
                .long => promote.wrapI64(rt, try longOf(rt, v)),
                .double => Value.initFloat(try promote.toF64(v)),
            };
        }
    };
}

/// JVM `Double.doubleToLongBits`: every NaN collapses to one pattern.
fn doubleBits(x: f64) u64 {
    if (std.math.isNan(x)) return 0x7ff8000000000000;
    return @bitCast(x);
}

fn foldLong(x: i64) i32 {
    const u: u64 = @bitCast(x);
    return @bitCast(@as(u32, @truncate(u ^ (u >> 32))));
}

/// JVM `BigInteger.hashCode`: `31*h + word` over the big-endian 32-bit words
/// of the magnitude, times the signum.
fn bigIntegerHash(c: Const) i32 {
    const words_per_limb = @bitSizeOf(Limb) / 32;
    var h: i32 = 0;
    var i: usize = c.limbs.len;
    var started = false;
    while (i > 0) {
        i -= 1;
        var k: usize = words_per_limb;
        while (k > 0) {
            k -= 1;
            const word: u32 = @truncate(@as(u64, c.limbs[i]) >> @intCast(k * 32));
            if (!started and word == 0) continue;
            started = true;
            h = h *% 31 +% @as(i32, @bitCast(word));
        }
    }
    if (!started) return 0;
    return if (c.positive) h else 0 -% h;
}

fn smallBigIntegerHash(x: i64) i32 {
    var m: [2]Limb = undefined;
    const mag: u64 = @abs(x);
    const c: Const = if (@bitSizeOf(Limb) == 64)
        .{ .limbs = blk: {
            m[0] = @intCast(mag);
            break :blk m[0..1];
        }, .positive = x >= 0 }
    else
        .{ .limbs = blk: {
            m[0] = @truncate(mag);
            m[1] = @truncate(mag >> 32);
            break :blk m[0..2];
        }, .positive = x >= 0 };
    return bigIntegerHash(c);
}

fn partHash(p: anytype) i32 {
    return switch (@TypeOf(p)) {
        i64 => smallBigIntegerHash(p),
        else => bigIntegerHash(p.m.toConst()),
    };
}

/// `(.hashCode n)`: the JVM class's own hashCode. Long folds its 64 bits,
/// Double folds its canonical bits, BigInt is a Long's hash when it fits a
/// long else BigInteger's, Ratio xors its numerator and denominator
/// BigInteger hashes. Distinct from clj `hash` (Murmur3).
fn hashCodeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("hashCode", args, 1, loc);
    const v = args[0];
    const h: i32 = switch (v.tag()) {
        .integer => foldLong(v.asInteger()),
        .float => foldLong(@bitCast(doubleBits(v.asFloat()))),
        .big_int => blk: {
            const c = big_int.asManaged(v).toConst();
            if (c.toInt(i64) catch null) |x| break :blk foldLong(x);
            break :blk bigIntegerHash(c);
        },
        .ratio => switch (ratio_mod.parts(v)) {
            .small => |s| partHash(s.n) ^ partHash(s.d),
            .big => |b| partHash(b.n) ^ partHash(b.d),
        },
        else => 0,
    };
    return Value.initInteger(h);
}

/// `(.equals a b)`: JVM equality, same class and then same value. A Double
/// compares canonical bits, so NaN equals NaN and 0.0 differs from -0.0.
fn equalsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("equals", args, 2, loc);
    const a = args[0];
    const b = args[1];
    const ca = classOf(a);
    if (ca != classOf(b)) return Value.false_val;
    if (ca == .double) return Value.initBoolean(doubleBits(a.asFloat()) == doubleBits(b.asFloat()));
    return Value.initBoolean((try promote.orderNumeric(rt, a, b)) == .eq);
}

/// `(.compareTo a b)`: -1/0/1 against a value of the SAME class (ClassCast
/// otherwise, as in clj). A Double uses the `Double.compare` total order
/// (-0.0 < 0.0, NaN greatest). A BigInt answers as `BigInteger.compareTo`
/// (clj's BigInt has none; cljw's `biginteger` yields a BigInt, AD-016), which
/// takes only another BigInteger.
fn compareToFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("compareTo", args, 2, loc);
    const a = args[0];
    const b = args[1];
    const ca = classOf(a);
    const cb = classOf(b);
    // Ratio.compareTo takes any Number (clj `Numbers.compare`); every other
    // class takes only its own.
    const ok = ca == cb or (ca == .ratio and cb != .other);
    if (!ok) return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "compareTo",
        .expected = "an argument of the receiver's class",
        .actual = @tagName(b.tag()),
    });
    const ord: std.math.Order = if (ca == .double) blk: {
        const x = a.asFloat();
        const y = b.asFloat();
        if (x < y) break :blk .lt;
        if (x > y) break :blk .gt;
        const xb: i64 = @bitCast(doubleBits(x));
        const yb: i64 = @bitCast(doubleBits(y));
        break :blk std.math.order(xb, yb);
    } else try promote.orderNumeric(rt, a, b);
    return Value.initInteger(switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

fn DoublePred(comptime name: []const u8, comptime inf: bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(name, args, 1, loc);
            const x = args[0].asFloat();
            return Value.initBoolean(if (inf) std.math.isInf(x) else std.math.isNan(x));
        }
    };
}

/// The `java.lang.Number` surface every numeric class carries, BigDecimal
/// included (`java/math/BigDecimal.zig` concatenates it onto its own specs).
pub const value_specs = .{
    .{ "intValue", &ValueOf(.int, "intValue").call },
    .{ "longValue", &ValueOf(.long, "longValue").call },
    .{ "shortValue", &ValueOf(.short, "shortValue").call },
    .{ "byteValue", &ValueOf(.byte, "byteValue").call },
    .{ "doubleValue", &ValueOf(.double, "doubleValue").call },
    .{ "floatValue", &ValueOf(.double, "floatValue").call },
};

/// The Number surface plus the class-gated `.compareTo` / `.equals` /
/// `.hashCode` of Long, Double, BigInt and Ratio. `bigint_methods.zig` and
/// `ratio_methods.zig` concatenate it onto their own specs.
pub const specs = value_specs ++ .{
    .{ "compareTo", &compareToFn },
    .{ "equals", &equalsFn },
    .{ "hashCode", &hashCodeFn },
};

/// Double-only instance predicates.
const double_specs = .{
    .{ "isNaN", &DoublePred("isNaN", false).call },
    .{ "isInfinite", &DoublePred("isInfinite", true).call },
};

/// Build a method table from a comptime spec tuple onto `td`. Idempotent.
pub fn installSpecs(rt: *Runtime, td: *type_descriptor.TypeDescriptor, comptime all: anytype) !void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, all.len);
    inline for (all, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

/// Install the Long (`.integer`) and Double (`.float`) instance tables.
/// Called at runtime init alongside the other native installers.
pub fn installNativeMethods(rt: *Runtime) !void {
    try installSpecs(rt, try rt.nativeDescriptor(.integer), specs);
    try installSpecs(rt, try rt.nativeDescriptor(.float), specs ++ double_specs);
}

test "lowI64 and the BigInteger hash" {
    try std.testing.expectEqual(@as(i32, 5), smallBigIntegerHash(5));
    try std.testing.expectEqual(@as(i32, -5), smallBigIntegerHash(-5));
    try std.testing.expectEqual(@as(i32, 0), foldLong(-1));
    try std.testing.expectEqual(@as(i32, 1), foldLong(4294967296));
    try std.testing.expectEqual(@as(i32, 2147483647), saturate(i32, 1e20));
    try std.testing.expectEqual(@as(i32, 0), saturate(i32, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturate(i64, -std.math.inf(f64)));
}
