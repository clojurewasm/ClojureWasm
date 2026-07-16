// SPDX-License-Identifier: EPL-2.0
//! Java static surface for `java.math.BigInteger` — the constructor + `valueOf`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/bigint
//!
//! A `java.math.BigInteger` value IS cljw's native `.big_int` (F-005 numeric
//! tower), so this surface only constructs one: `(BigInteger. s)` parses a
//! base-10 string (like `bigint`), `(BigInteger. byte[])` reads a big-endian
//! two's-complement byte array, and `(BigInteger/valueOf n)` boxes a long. The
//! arithmetic / `.signum` / `.gcd` / `.modPow` / `.toBigInteger` instance methods
//! live on the `.big_int` descriptor (`runtime/bigint_methods.zig`). The radix
//! string ctor + the (signum, magnitude) byte form are not yet wired (D-532).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const big_int = @import("../../numeric/big_int.zig");
const string_collection = @import("../../collection/string.zig");
const java_array = @import("../../collection/java_array.zig");

/// `(java.math.BigInteger. s)` / `(... byte[])` — construct a BigInteger (a cljw
/// `.big_int`). A base-10 string parses like `bigint`; a byte array is read as a
/// big-endian two's-complement integer (high bit of byte[0] = sign), matching
/// `java.math.BigInteger(byte[])`. JVM ref: java.math.BigInteger#<init>.
fn initBigInteger(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len != 1)
        // The (String, radix) and (signum, magnitude) ctor forms are not yet
        // wired (D-532); only the base-10 String and byte[] forms ship.
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "java.math.BigInteger. (only the 1-arg String / byte[] forms are supported)" });
    const a = args[0];
    if (a.tag() == .string) {
        var m = big_int.parseBase10(rt, string_collection.asString(a)) catch
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "java.math.BigInteger.", .text = string_collection.asString(a) });
        defer m.deinit();
        return big_int.allocFromManaged(rt, &m, .bigint);
    }
    if (java_array.isArray(a)) {
        const arr = java_array.asArray(a);
        const n = arr.len;
        if (n == 0)
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "java.math.BigInteger.", .text = "" });
        const bytes = try rt.gpa.alloc(u8, n);
        defer rt.gpa.free(bytes);
        for (arr.items(), 0..) |item, i| {
            if (item.tag() != .integer)
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.math.BigInteger.", .expected = "byte array", .actual = @tagName(item.tag()) });
            bytes[i] = @intCast(item.asInteger() & 0xFF);
        }
        const bit_count = n * 8;
        var m = try std.math.big.int.Managed.init(rt.gc.infra);
        defer m.deinit();
        try m.ensureCapacity(std.math.big.int.calcTwosCompLimbCount(bit_count));
        var mut = m.toMutable();
        mut.readTwosComplement(bytes, bit_count, .big, .signed);
        m.setMetadata(mut.positive, mut.len);
        return big_int.allocFromManaged(rt, &m, .bigint);
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.math.BigInteger.", .expected = "string or byte array", .actual = @tagName(a.tag()) });
}

/// `(java.math.BigInteger/valueOf n)` — box a long as a BigInteger.
/// JVM reference: java.math.BigInteger#valueOf.
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.math.BigInteger/valueOf", args, 1, loc);
    const n = try error_catalog.expectI64(args[0], "java.math.BigInteger/valueOf", loc);
    return big_int.allocFromI64(rt, n, .bigint);
}

fn initStatic(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "valueOf", &valueOf },
        .{ "<init>", &initBigInteger },
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
    .cljw_ns = "cljw.java.math.BigInteger",
    .descriptor = &descriptor,
    .init = &initStatic,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.math.BigInteger",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
