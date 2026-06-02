// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Long` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/parse-long
//!
//! Thin wrapper over the shared `runtime/numeric/parse.zig` leaf (same
//! acceptance as `Integer/parseInt` / `clojure.core/parse-long`, F-011
//! DRY) at i64 width + Zig `std.fmt` radix formatting, plus the
//! bit-twiddling statics (`bitCount` / `numberOfLeadingZeros` /
//! `numberOfTrailingZeros` / `highestOneBit` / `reverse`) over Zig bit
//! builtins. parseLong wraps through `promote.wrapI64`, matching
//! parse-long: a value beyond the i48 NaN-box payload stays exact as a
//! BigInt rather than a lossy Float. That makes
//! `(Long/parseLong "999999999999999")` print
//! `…N` (BigInt) where JVM keeps a primitive Long — a recorded
//! representation divergence (D-165, F-004 NaN-box i48 boundary); the
//! value is exact. Parse failure raises a `number_error`-Kind Code →
//! NumberFormatException (ADR-0060).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const parse = @import("../../numeric/parse.zig");
const promote = @import("../../numeric/promote.zig");
const string_mod = @import("../../collection/string.zig");

/// Parse `s` as an i64 in `radix`, wrapping through `promote.wrapI64`
/// (collapses to a Long in i48 range, BigInt beyond — D-165). On failure
/// raise NumberFormatException. Shared by `parseLong` and `valueOf`.
fn parseI64(rt: *Runtime, s: []const u8, radix: u8, fn_name: []const u8, loc: SourceLocation) anyerror!Value {
    const v = parse.parseSigned(i64, s, radix) catch
        return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = fn_name, .text = s });
    return promote.wrapI64(rt, v);
}

/// Implements `(Long/parseLong s)` and `(Long/parseLong s radix)`.
/// Spec: parse a 64-bit long; malformed ⇒ NumberFormatException. Radix
/// defaults to 10, must be in 2..36.
/// JVM reference: java.lang.Long#parseLong.
/// cw v1 tier: A (§A26 clj differential sweep).
fn parseLong(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Long/parseLong", .got = args.len, .min = 1, .max = 2 });
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Long/parseLong", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Long/parseLong", loc);
        if (r < 2 or r > 36)
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Long/parseLong", .text = s });
        radix = @intCast(r);
    }
    return parseI64(rt, s, radix, "Long/parseLong", loc);
}

/// Implements `(Long/valueOf x)`. Spec: a String parses (like parseLong
/// base-10); a number is returned as-is.
/// JVM reference: java.lang.Long#valueOf.
/// cw v1 tier: A (§A26 clj differential sweep).
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Long/valueOf", args, 1, loc);
    return switch (args[0].tag()) {
        .string => parseI64(rt, string_mod.asString(args[0]), 10, "Long/valueOf", loc),
        .integer => args[0],
        else => error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "Long/valueOf", .actual = @tagName(args[0].tag()) }),
    };
}

/// `Long/toBinaryString` / `toHexString` / `toOctalString`: view the
/// value's full 64 bits as two's-complement u64 (Java long width) and
/// format in the radix with no leading zeros. Mirrors Integer.zig's
/// factory at 64-bit width (the only difference; per ADR-0029 R4 the two
/// surfaces cannot share a factory across the java/ tree, and the body
/// is a thin `std.fmt` call with no Java-specific normalisation to hoist).
fn RadixString(comptime verb: []const u8, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Long/" ++ name, args, 1, loc);
            const wide = try error_catalog.expectI64(args[0], "Long/" ++ name, loc);
            const u: u64 = @bitCast(wide);
            // u64 needs ≤ 64 binary digits — the 70-byte buffer can't overflow.
            var buf: [70]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{" ++ verb ++ "}", .{u}) catch unreachable;
            return string_mod.alloc(rt, out);
        }
    };
}

/// `(Long/toString n)` / `(Long/toString n radix)` — the SIGNED value in
/// `radix` (default 10; a radix outside 2..36 silently falls back to 10, per
/// Java, NOT an error). Distinct from `toHexString`/`toBinaryString` etc.,
/// which render the UNSIGNED two's-complement bit pattern: `(Long/toString -255
/// 16)` is `"-ff"`, whereas `(Long/toHexString -255)` is the full 64-bit word.
/// JVM reference: java.lang.Long#toString. cw v1 tier: A (§A26 sweep).
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Long/toString", .got = args.len, .min = 1, .max = 2 });
    const n = try error_catalog.expectI64(args[0], "Long/toString", loc);
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Long/toString", loc);
        if (r >= 2 and r <= 36) radix = @intCast(r);
    }
    var buf: [70]u8 = undefined;
    const len = std.fmt.printInt(&buf, @as(i64, n), radix, .lower, .{});
    return string_mod.alloc(rt, buf[0..len]);
}

/// The five bit-twiddling statics, identified by the Zig builtin each one
/// reduces to at 64-bit (`long`) width.
const BitMethod = enum { bit_count, leading_zeros, trailing_zeros, highest_one_bit, reverse, lowest_one_bit, reverse_bytes, signum };

/// `Long/bitCount` / `numberOfLeadingZeros` / `numberOfTrailingZeros` /
/// `highestOneBit` / `reverse`: view the value's full 64 bits as Java's
/// `long` width, apply the bit op, and wrap the i64 result through
/// `promote.wrapI64`. The count ops yield a small Long; `highestOneBit` /
/// `reverse` can exceed i48 (e.g. `(Long/reverse 1)` = Long.MIN_VALUE) and
/// then print as BigInt `…N` (D-165) — exact value, divergent print from
/// JVM's primitive long. Mirrors Integer.zig's factory at 64-bit width
/// (per ADR-0029 R4 the two surfaces cannot share a factory across the
/// java/ tree). The comptime `op` selects the builtin.
fn BitOp(comptime op: BitMethod, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Long/" ++ name, args, 1, loc);
            const wide = try error_catalog.expectI64(args[0], "Long/" ++ name, loc);
            const u: u64 = @bitCast(wide);
            const result: i64 = switch (op) {
                .bit_count => @as(i64, @popCount(u)),
                .leading_zeros => @as(i64, @clz(u)),
                .trailing_zeros => @as(i64, @ctz(u)),
                .highest_one_bit => blk: {
                    if (u == 0) break :blk @as(i64, 0);
                    const shift: u6 = @intCast(63 - @clz(u));
                    break :blk @as(i64, @bitCast(@as(u64, 1) << shift));
                },
                .reverse => @as(i64, @bitCast(@bitReverse(u))),
                // D-173: `n & -n` isolates the lowest set bit; `@byteSwap`
                // reverses byte order; `signum` is the i64 sign (-1/0/1).
                .lowest_one_bit => @as(i64, @bitCast(u & (0 -% u))),
                .reverse_bytes => @as(i64, @bitCast(@byteSwap(u))),
                .signum => if (wide > 0) @as(i64, 1) else if (wide < 0) @as(i64, -1) else @as(i64, 0),
            };
            return promote.wrapI64(rt, result);
        }
    };
}

/// D-173: `Long/rotateLeft` / `rotateRight` — arity-2 `(value, distance)`.
/// Java rotates by `distance` bits at 64-bit width (only the low 6 bits of
/// `distance` matter — `rotl`/`rotr` are equivalent under a 64-bit modulus).
fn RotateOp(comptime left: bool, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Long/" ++ name, args, 2, loc);
            const n = try error_catalog.expectI64(args[0], "Long/" ++ name, loc);
            const d = try error_catalog.expectI64(args[1], "Long/" ++ name, loc);
            const u: u64 = @bitCast(n);
            const dist: u6 = @truncate(@as(u64, @bitCast(d)));
            const r = if (left) std.math.rotl(u64, u, dist) else std.math.rotr(u64, u, dist);
            return promote.wrapI64(rt, @as(i64, @bitCast(r)));
        }
    };
}

/// `Long/compare` / `max` / `min`: two-long statics. compare → the sign of
/// `a - b` (-1/0/1); max/min → the larger/smaller. JVM ref:
/// java.lang.Long#compare/max/min.
const Binop = enum { compare, max, min };
fn BinOp2(comptime op: Binop, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Long/" ++ name, args, 2, loc);
            const a = try error_catalog.expectI64(args[0], "Long/" ++ name, loc);
            const b = try error_catalog.expectI64(args[1], "Long/" ++ name, loc);
            // compare → a small -1/0/1; max/min → a full Long, so wrapI64
            // keeps a result past i48 a heap Long (D-165 / D-214).
            return switch (op) {
                .compare => Value.initInteger(if (a < b) -1 else if (a > b) 1 else 0),
                .max => promote.wrapI64(rt, @max(a, b)),
                .min => promote.wrapI64(rt, @min(a, b)),
            };
        }
    };
}

fn initLong(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseLong", &parseLong },
        .{ "compare", &BinOp2(.compare, "compare").call },
        .{ "max", &BinOp2(.max, "max").call },
        .{ "min", &BinOp2(.min, "min").call },
        .{ "valueOf", &valueOf },
        .{ "toString", &toString },
        .{ "toBinaryString", &RadixString("b", "toBinaryString").call },
        .{ "toHexString", &RadixString("x", "toHexString").call },
        .{ "toOctalString", &RadixString("o", "toOctalString").call },
        .{ "bitCount", &BitOp(.bit_count, "bitCount").call },
        .{ "numberOfLeadingZeros", &BitOp(.leading_zeros, "numberOfLeadingZeros").call },
        .{ "numberOfTrailingZeros", &BitOp(.trailing_zeros, "numberOfTrailingZeros").call },
        .{ "highestOneBit", &BitOp(.highest_one_bit, "highestOneBit").call },
        .{ "reverse", &BitOp(.reverse, "reverse").call },
        .{ "lowestOneBit", &BitOp(.lowest_one_bit, "lowestOneBit").call },
        .{ "reverseBytes", &BitOp(.reverse_bytes, "reverseBytes").call },
        .{ "signum", &BitOp(.signum, "signum").call },
        .{ "rotateLeft", &RotateOp(true, "rotateLeft").call },
        .{ "rotateRight", &RotateOp(false, "rotateRight").call },
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
    .cljw_ns = "cljw.java.lang.Long",
    .descriptor = &descriptor,
    .init = &initLong,
};

// Static fields (ADR-0061) — comptime-const. Both exceed i48 → BigInt
// (`…N`), exact value but diverges from JVM's bare-Long print (D-165).
const long_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = std.math.maxInt(i64) } },
    .{ .name = "MIN_VALUE", .value = .{ .int = std.math.minInt(i64) } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.Long",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &long_static_fields,
    .parent = null,
    .meta = .nil_val,
};
