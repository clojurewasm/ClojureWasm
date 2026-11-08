// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.temporal.ChronoField` — the 30 enum constants
//! (NANO_OF_SECOND..OFFSET_SECONDS) as host-enum singletons + `.toString` (the
//! display name, "HourOfDay") / `.name` (the enum name, "HOUR_OF_DAY"). The
//! field argument of `DateTimeFormatterBuilder` (`appendValue`, `appendFraction`,
//! `parseDefaulting`) and of `Parsed.getLong` / `isSupported`.
//!
//! Backend: impl-only
//! Impl deps: host_enum
//! Clojure peer: none.
//!
//! Singletons + the ordinal↔name↔display mapping live in the neutral host-enum
//! registry `runtime/host_enum.zig`; the per-field ranges and the parse/format
//! semantics live in `runtime/time/date_time_format.zig::Field`, which mirrors
//! the registry order.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const host_instance = @import("../../../host_instance.zig");
const string_collection = @import("../../../collection/string.zig");
const host_enum = @import("../../../host_enum.zig");

/// `(str f)` / `(.toString f)` — the DISPLAY name ("HourOfDay").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.toStringOf(.chrono_field, ord));
}

/// `(.name f)` — the enum-constant name ("HOUR_OF_DAY").
fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.name(.chrono_field, ord));
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const statics = host_enum.Statics(.chrono_field);
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "toString", &toString },
        .{ "name", &nameFn },
        .{ "values", &statics.values },
        .{ "valueOf", &statics.valueOf },
    });
}

/// The 30 enum constants, generated from the canonical `host_enum` registry.
const static_fields = build: {
    var arr: [host_enum.count(.chrono_field)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.chrono_field, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.chrono_field), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.temporal.ChronoField",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.temporal.ChronoField",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
    .host_enum_idx = @intFromEnum(host_enum.Idx.chrono_field),
};
