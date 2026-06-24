// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.DayOfWeek` — the 7 ISO day-of-week enum constants
//! (MONDAY..SUNDAY) as host-enum singletons (ADR-0161 / D-510) + `.toString` (the
//! enum name) / `.name` / `.getValue` (the ISO value 1..7). Static-field access
//! (`DayOfWeek/MONDAY`) resolves to the interned singleton; `LocalDate`/
//! `LocalDateTime`'s `getDayOfWeek` getter returns the SAME interned singleton
//! (clj `identical?` parity). Folds the former `time/day_of_week_value.zig`
//! (D-462 typed_instance) into the general host-enum mechanism.
//!
//! Backend: impl-only
//! Impl deps: host_enum
//! Clojure peer: none.
//!
//! The singletons + the ordinal↔name↔value mapping live in the neutral host-enum
//! registry `runtime/host_enum.zig` (zone rule). This file owns the descriptor +
//! static-field table + `.toString`/`.name`/`.getValue`.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const string_collection = @import("../../collection/string.zig");
const host_enum = @import("../../host_enum.zig");

/// `(str dow)` / `(.toString dow)` — the bare enum-constant name ("MONDAY").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.toStringOf(.day_of_week, ord));
}

/// `(.name dow)` — the enum-constant name ("MONDAY").
fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.name(.day_of_week, ord));
}

/// `(.getValue dow)` — the ISO ordinal 1..7 (JVM `DayOfWeek.getValue`).
fn getValueFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getValue", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return Value.initInteger(host_enum.value(.day_of_week, ord).?);
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const specs = .{
        .{ "toString", &toString },
        .{ "name", &nameFn },
        .{ "getValue", &getValueFn },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, spec[0]), .method_val = Value.initBuiltinFn(spec[1]) };
    }
    td.method_table = entries;
}

/// The 7 enum constants, generated from the canonical `host_enum` registry.
const static_fields = build: {
    var arr: [host_enum.count(.day_of_week)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.day_of_week, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.day_of_week), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.DayOfWeek",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.DayOfWeek",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
    .host_enum_idx = @intFromEnum(host_enum.Idx.day_of_week),
};
