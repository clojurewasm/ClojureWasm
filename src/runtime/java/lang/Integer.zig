// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Integer` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/parse-long
//!
//! Thin wrapper over the neutral `runtime/numeric/parse.zig` leaf
//! (shared with `clojure.core/parse-long`, F-011 DRY) + Zig `std.fmt`
//! radix formatting, plus the bit-twiddling statics (`bitCount` /
//! `numberOfLeadingZeros` / `numberOfTrailingZeros` / `highestOneBit` /
//! `reverse`) over Zig bit builtins. Static methods reach these as
//! `(Integer/parseInt …)` after the `java.lang.*` auto-import in
//! `resolveJavaSurface`.
//!
//! cljw has no boxed `Integer` type (single `.integer` tag, F-005); a
//! parsed value is returned as a Long, and `(class Integer/MAX_VALUE)`
//! differs from clj's `java.lang.Integer` (no-JVM rule). `parseInt`
//! parses in the i32 range so an out-of-int-range string throws
//! NumberFormatException exactly as real clj does. Failure raises a
//! `number_error`-Kind Code → NumberFormatException (ADR-0060).

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

/// Parse `s` as an i32 in `radix`; on failure raise NumberFormatException.
/// Shared by `parseInt` and the string arm of `valueOf`.
fn parseI32(s: []const u8, radix: u8, fn_name: []const u8, loc: SourceLocation) anyerror!Value {
    const v = parse.parseSigned(i32, s, radix) catch
        return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = fn_name, .text = s });
    return Value.initInteger(@as(i64, v));
}

/// Implements `(Integer/parseInt s)` and `(Integer/parseInt s radix)`.
/// Spec: parse a 32-bit int; out-of-int-range or malformed ⇒
/// NumberFormatException. Radix defaults to 10, must be in 2..36.
/// JVM reference: java.lang.Integer#parseInt.
/// cw v1 tier: A (§A26 clj differential sweep).
fn parseInt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Integer/parseInt", .got = args.len, .min = 1, .max = 2 });
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Integer/parseInt", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Integer/parseInt", loc);
        if (r < 2 or r > 36)
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Integer/parseInt", .text = s });
        radix = @intCast(r);
    }
    return parseI32(s, radix, "Integer/parseInt", loc);
}

/// Implements `(Integer/valueOf x)`. Spec: a String parses (like
/// parseInt base-10); a number is returned as-is (cljw has no boxed
/// Integer, F-005). JVM reference: java.lang.Integer#valueOf.
/// cw v1 tier: A (§A26 clj differential sweep).
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Integer/valueOf", args, 1, loc);
    return switch (args[0].tag()) {
        .string => parseI32(string_mod.asString(args[0]), 10, "Integer/valueOf", loc),
        .integer => args[0],
        else => error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "Integer/valueOf", .actual = @tagName(args[0].tag()) }),
    };
}

/// `Integer/toBinaryString` / `toHexString` / `toOctalString` share one
/// shape: take an int, view its low 32 bits as a two's-complement u32
/// (Java's `int` width), and format it in the radix with no leading
/// zeros. The comptime spec parameter selects the Zig format verb.
fn RadixString(comptime verb: []const u8, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity("Integer/" ++ name, args, 1, loc);
            const n = try error_catalog.expectInteger(args[0], "Integer/" ++ name, loc);
            // expectInteger yields i48; widen (sign-extend) to i64 then view
            // the low 32 bits as two's-complement, matching Java's int width.
            const wide: i64 = n;
            const u: u32 = @truncate(@as(u64, @bitCast(wide)));
            // u32 needs ≤ 32 binary digits — the 40-byte buffer can't overflow.
            var buf: [40]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{" ++ verb ++ "}", .{u}) catch unreachable;
            return string_mod.alloc(rt, out);
        }
    };
}

/// `(Integer/toString n)` / `(Integer/toString n radix)` — the SIGNED int
/// value in `radix` (default 10; a radix outside 2..36 silently falls back to
/// 10, per Java). Distinct from `toHexString` etc. (unsigned bit pattern):
/// `(Integer/toString -255 16)` is `"-ff"`. Truncated to 32-bit int width,
/// matching the `RadixString` arm. JVM reference: java.lang.Integer#toString.
/// cw v1 tier: A (§A26 sweep).
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Integer/toString", .got = args.len, .min = 1, .max = 2 });
    const n = try error_catalog.expectInteger(args[0], "Integer/toString", loc);
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Integer/toString", loc);
        if (r >= 2 and r <= 36) radix = @intCast(r);
    }
    const v: i32 = @truncate(@as(i64, n));
    var buf: [40]u8 = undefined;
    const len = std.fmt.printInt(&buf, v, radix, .lower, .{});
    return string_mod.alloc(rt, buf[0..len]);
}

/// The five bit-twiddling statics, identified by the Zig builtin each one
/// reduces to at 32-bit (`int`) width.
const BitMethod = enum { bit_count, leading_zeros, trailing_zeros, highest_one_bit, reverse, lowest_one_bit, reverse_bytes, signum };

/// `Integer/bitCount` / `numberOfLeadingZeros` / `numberOfTrailingZeros` /
/// `highestOneBit` / `reverse`: view the value's low 32 bits as Java's `int`
/// width, apply the bit op, and return the result as a Long. Every result
/// fits i48 — counts are 0-32, and the full-width ops (`highestOneBit` /
/// `reverse`) sign-extend an i32 (e.g. `(Integer/reverse 1)` =
/// Integer.MIN_VALUE = -2147483648) — so `Value.initInteger` is exact here.
/// The comptime `op` selects the builtin.
fn BitOp(comptime op: BitMethod, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Integer/" ++ name, args, 1, loc);
            const n = try error_catalog.expectInteger(args[0], "Integer/" ++ name, loc);
            const wide: i64 = n; // expectInteger yields i48; view low 32 bits
            const u: u32 = @truncate(@as(u64, @bitCast(wide)));
            const result: i64 = switch (op) {
                .bit_count => @as(i64, @popCount(u)),
                .leading_zeros => @as(i64, @clz(u)),
                .trailing_zeros => @as(i64, @ctz(u)),
                .highest_one_bit => blk: {
                    if (u == 0) break :blk @as(i64, 0);
                    const shift: u5 = @intCast(31 - @clz(u));
                    break :blk @as(i64, @as(i32, @bitCast(@as(u32, 1) << shift)));
                },
                .reverse => @as(i64, @as(i32, @bitCast(@bitReverse(u)))),
                // D-173: `n & -n` isolates the lowest set bit (sign-extended
                // from i32); `@byteSwap` reverses the 4 bytes; `signum` is the
                // i32 sign (-1/0/1).
                .lowest_one_bit => @as(i64, @as(i32, @bitCast(u & (0 -% u)))),
                .reverse_bytes => @as(i64, @as(i32, @bitCast(@byteSwap(u)))),
                .signum => blk: {
                    const iv: i32 = @bitCast(u);
                    break :blk if (iv > 0) @as(i64, 1) else if (iv < 0) @as(i64, -1) else @as(i64, 0);
                },
            };
            return Value.initInteger(result);
        }
    };
}

/// D-173: `Integer/rotateLeft` / `rotateRight` — arity-2 `(value, distance)`.
/// Java rotates by `distance` bits at 32-bit width (only the low 5 bits of
/// `distance` matter). Result sign-extends the rotated i32.
fn RotateOp(comptime left: bool, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Integer/" ++ name, args, 2, loc);
            const n = try error_catalog.expectInteger(args[0], "Integer/" ++ name, loc);
            const d = try error_catalog.expectInteger(args[1], "Integer/" ++ name, loc);
            const u: u32 = @truncate(@as(u64, @bitCast(@as(i64, n))));
            const dist: u5 = @truncate(@as(u64, @bitCast(@as(i64, d))));
            const r = if (left) std.math.rotl(u32, u, dist) else std.math.rotr(u32, u, dist);
            return Value.initInteger(@as(i64, @as(i32, @bitCast(r))));
        }
    };
}

/// `Integer/compare` / `max` / `min`: two-int statics. compare → the sign
/// of `a - b` (-1/0/1); max/min → the larger/smaller. JVM ref:
/// java.lang.Integer#compare/max/min (Math.max/min for the latter two).
const Binop = enum { compare, max, min };
fn BinOp2(comptime op: Binop, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Integer/" ++ name, args, 2, loc);
            const a = try error_catalog.expectInteger(args[0], "Integer/" ++ name, loc);
            const b = try error_catalog.expectInteger(args[1], "Integer/" ++ name, loc);
            return Value.initInteger(switch (op) {
                .compare => @as(i64, if (a < b) -1 else if (a > b) 1 else 0),
                .max => @max(a, b),
                .min => @min(a, b),
            });
        }
    };
}

/// `(Integer/parseUnsignedInt s)` / `(… s radix)` — parse the FULL unsigned
/// 32-bit range, so `"4294967295"` (u32 max) yields the int `-1` (its
/// two's-complement bit pattern, matching JVM). Malformed / out-of-range ⇒
/// NumberFormatException. Radix defaults to 10, must be 2..36.
fn parseUnsignedInt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Integer/parseUnsignedInt", .got = args.len, .min = 1, .max = 2 });
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Integer/parseUnsignedInt", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Integer/parseUnsignedInt", loc);
        if (r < 2 or r > 36)
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Integer/parseUnsignedInt", .text = s });
        radix = @intCast(r);
    }
    const u = parse.parseUnsigned(u32, s, radix) catch
        return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Integer/parseUnsignedInt", .text = s });
    return Value.initInteger(@as(i64, @as(i32, @bitCast(u))));
}

/// `(Integer/sum a b)` — `a + b` at `int` width, WRAPPING on overflow (two's
/// complement), unlike cljw's `+` (F-005). JVM reference: java.lang.Integer#sum.
fn sum(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Integer/sum", args, 2, loc);
    const a: i32 = @truncate(try error_catalog.expectInteger(args[0], "Integer/sum", loc));
    const b: i32 = @truncate(try error_catalog.expectInteger(args[1], "Integer/sum", loc));
    return Value.initInteger(@as(i64, a +% b));
}

/// `Integer/divideUnsigned` / `remainderUnsigned` — both operands viewed as
/// unsigned 32-bit; divide-by-zero throws. JVM ref: java.lang.Integer.
fn UnsignedDiv(comptime is_rem: bool, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Integer/" ++ name, args, 2, loc);
            const a: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Integer/" ++ name, loc)))));
            const b: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[1], "Integer/" ++ name, loc)))));
            if (b == 0) return error_catalog.raise(.divide_by_zero, loc, .{});
            const r = if (is_rem) a % b else a / b;
            return Value.initInteger(@as(i64, @as(i32, @bitCast(r))));
        }
    };
}

/// `(Integer/compareUnsigned a b)` — the sign of an UNSIGNED 32-bit comparison
/// (-1/0/1). JVM reference: java.lang.Integer#compareUnsigned.
fn compareUnsigned(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Integer/compareUnsigned", args, 2, loc);
    const a: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Integer/compareUnsigned", loc)))));
    const b: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[1], "Integer/compareUnsigned", loc)))));
    return Value.initInteger(if (a < b) -1 else if (a > b) 1 else 0);
}

/// `(Integer/toUnsignedLong n)` — the int's low 32 bits as an UNSIGNED `long`,
/// so `(Integer/toUnsignedLong -1)` is 4294967295. JVM ref: java.lang.Integer.
fn toUnsignedLong(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Integer/toUnsignedLong", args, 1, loc);
    const u: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Integer/toUnsignedLong", loc)))));
    return Value.initInteger(@as(i64, u));
}

/// `(Integer/toUnsignedString n)` / `(… n radix)` — render the int's low 32
/// bits as an UNSIGNED integer in `radix` (default 10; a radix outside 2..36
/// falls back to 10). JVM reference: java.lang.Integer#toUnsignedString.
fn toUnsignedString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "Integer/toUnsignedString", .got = args.len, .min = 1, .max = 2 });
    const u: u32 = @truncate(@as(u64, @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Integer/toUnsignedString", loc)))));
    var radix: u8 = 10;
    if (args.len == 2) {
        const r = try error_catalog.expectInteger(args[1], "Integer/toUnsignedString", loc);
        if (r >= 2 and r <= 36) radix = @intCast(r);
    }
    var buf: [40]u8 = undefined;
    const len = std.fmt.printInt(&buf, u, radix, .lower, .{});
    return string_mod.alloc(rt, buf[0..len]);
}

/// `(Integer/hashCode v)` — Java returns the int value itself. JVM ref:
/// java.lang.Integer#hashCode.
fn hashCode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Integer/hashCode", args, 1, loc);
    const v: i32 = @truncate(try error_catalog.expectInteger(args[0], "Integer/hashCode", loc));
    return Value.initInteger(@as(i64, v));
}

fn initInteger(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseInt", &parseInt },
        .{ "parseUnsignedInt", &parseUnsignedInt },
        .{ "sum", &sum },
        .{ "divideUnsigned", &UnsignedDiv(false, "divideUnsigned").call },
        .{ "remainderUnsigned", &UnsignedDiv(true, "remainderUnsigned").call },
        .{ "compareUnsigned", &compareUnsigned },
        .{ "toUnsignedLong", &toUnsignedLong },
        .{ "toUnsignedString", &toUnsignedString },
        .{ "hashCode", &hashCode },
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
    .cljw_ns = "cljw.java.lang.Integer",
    .descriptor = &descriptor,
    .init = &initInteger,
};

// Static fields (ADR-0061) — comptime-const, set directly in the
// descriptor literal (no init/deinit). Both fit i48 → clean Long.
const integer_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = 2147483647 } },
    .{ .name = "MIN_VALUE", .value = .{ .int = -2147483648 } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Integer",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &integer_static_fields,
    .parent = null,
    .meta = .nil_val,
};
