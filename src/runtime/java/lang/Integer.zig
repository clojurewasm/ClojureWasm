// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Integer` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/parse-long
//!
//! Thin wrapper over the neutral `runtime/numeric/parse.zig` leaf
//! (shared with `clojure.core/parse-long`, F-011 DRY) + Zig `std.fmt`
//! radix formatting. Static methods reach these as `(Integer/parseInt …)`
//! after the `java.lang.*` auto-import in `resolveJavaSurface`.
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

fn initInteger(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseInt", &parseInt },
        .{ "valueOf", &valueOf },
        .{ "toBinaryString", &RadixString("b", "toBinaryString").call },
        .{ "toHexString", &RadixString("x", "toHexString").call },
        .{ "toOctalString", &RadixString("o", "toOctalString").call },
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

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.Integer",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
