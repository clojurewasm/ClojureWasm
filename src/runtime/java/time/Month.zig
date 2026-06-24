// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.Month` — the 12 month-of-year enum constants
//! (JANUARY..DECEMBER) as host-enum singletons (ADR-0161 / D-510) + `.toString`
//! (the enum name) / `.name` / `.getValue` (the value 1..12). Static-field access
//! (`Month/JANUARY`) resolves to the interned singleton; `LocalDate`/
//! `LocalDateTime`'s `getMonth` getter returns the SAME interned singleton (clj
//! `identical?` parity). Folds the former `time/month_value.zig` (D-462
//! typed_instance) into the general host-enum mechanism.
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

/// `(str m)` / `(.toString m)` — the bare enum-constant name ("JANUARY").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.toStringOf(.month, ord));
}

/// `(.name m)` — the enum-constant name ("JANUARY").
fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.name(.month, ord));
}

/// `(.getValue m)` — the month value 1..12 (JVM `Month.getValue`).
fn getValueFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getValue", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return Value.initInteger(host_enum.value(.month, ord).?);
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

/// The 12 enum constants, generated from the canonical `host_enum` registry.
const static_fields = build: {
    var arr: [host_enum.count(.month)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.month, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.month), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.Month",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.Month",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
    .host_enum_idx = @intFromEnum(host_enum.Idx.month),
};
