// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Short` — `MIN_VALUE` / `MAX_VALUE` static fields
//! (ADR-0061) and the `(Short. x)` constructor. clojure.data.generators reads
//! `Short/MIN_VALUE` / `Short/MAX_VALUE` for its short range; cljw has no
//! `short` primitive type (F-005), so these are plain Long constants and the
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

/// `(Short. x)` / `(new Short x)`: a String parses as a short
/// (NumberFormatException when malformed or outside -32768..32767), an integer
/// within short range is itself, one outside it is IllegalArgumentException.
/// cljw has no short type (AD-069), so `(Short. (short 7))` and `(Short. 7)`
/// are the same call and both answer 7, where clj rejects the bare long
/// literal. Any other argument matches no ctor.
/// JVM reference: java.lang.Short#Short(short|String).
fn ctor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Short.", args, 1, loc);
    return switch (args[0].tag()) {
        .string => blk: {
            const s = string_mod.asString(args[0]);
            const v = parse.parseSigned(i16, s, 10) catch
                return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Short.", .text = s });
            break :blk Value.initInteger(@as(i64, v));
        },
        .integer => if (std.math.cast(i16, args[0].asInteger()) != null)
            args[0]
        else
            error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "Short.", .expected = "a value within short range", .actual = "out-of-range number" }),
        else => error_catalog.raise(.ctor_unmatched, loc, .{ .class = "java.lang.Short" }),
    };
}

fn initShort(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "<init>", &ctor },
    });
}

// Both fit i48 → clean Long (mirrors Integer.zig's static-field pattern).
const short_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = 32767 } },
    .{ .name = "MIN_VALUE", .value = .{ .int = -32768 } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Short",
    .descriptor = &descriptor,
    .init = &initShort,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Short",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &short_static_fields,
    .parent = null,
    .meta = .nil_val,
};
