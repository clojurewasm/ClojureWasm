// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Byte` — `MIN_VALUE` / `MAX_VALUE` static fields
//! (ADR-0061) and the `(Byte. x)` constructor. clojure.data.generators reads
//! `Byte/MIN_VALUE` / `Byte/MAX_VALUE` for its byte range; cljw has no `byte`
//! primitive type (F-005), so these are plain Long constants and the
//! constructor answers a Long.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none

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

/// `(Byte. x)` / `(new Byte x)`: a String parses as a byte
/// (NumberFormatException when malformed or outside -128..127), an integer
/// within byte range is itself, one outside it is IllegalArgumentException.
/// cljw has no byte type (AD-069), so `(Byte. (byte 7))` and `(Byte. 7)` are
/// the same call and both answer 7, where clj rejects the bare long literal.
/// Any other argument matches no ctor. JVM reference: java.lang.Byte#Byte(byte|String).
fn ctor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Byte.", args, 1, loc);
    return switch (args[0].tag()) {
        .string => blk: {
            const s = string_mod.asString(args[0]);
            const v = parse.parseSigned(i8, s, 10) catch
                return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Byte.", .text = s });
            break :blk Value.initInteger(@as(i64, v));
        },
        .integer => if (std.math.cast(i8, args[0].asInteger()) != null)
            args[0]
        else
            error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "Byte.", .expected = "a value within byte range", .actual = "out-of-range number" }),
        else => error_catalog.raise(.ctor_unmatched, loc, .{ .class = "java.lang.Byte" }),
    };
}

fn initByte(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "<init>", &ctor },
    });
}

const byte_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = 127 } },
    .{ .name = "MIN_VALUE", .value = .{ .int = -128 } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Byte",
    .descriptor = &descriptor,
    .init = &initByte,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Byte",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &byte_static_fields,
    .parent = null,
    .meta = .nil_val,
};
