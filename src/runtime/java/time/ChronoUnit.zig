// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.temporal.ChronoUnit` — the 16 enum constants
//! (NANOS..FOREVER) as host-enum singletons + `.toString` (display name) /
//! `.name` (enum name). The temporal-difference unit passed to
//! `(.until d1 d2 ChronoUnit/DAYS)`; modeled as host_instance singletons (not
//! int ordinals) so `(class …)` = the enum class — the 2nd host-enum after
//! RoundingMode (ADR-0160; D-510 folds both into a general mechanism).
//!
//! Backend: impl-only
//! Impl deps: chrono_unit
//! Clojure peer: none.
//!
//! Singletons + the ordinal↔name↔display mapping live in the neutral host-enum
//! registry `runtime/host_enum.zig` (zone rule). This file owns the descriptor +
//! static-field table + `.toString`/`.name`.

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

/// `(str u)` / `(.toString u)` — the DISPLAY name ("Days", "HalfDays").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.toStringOf(.chrono_unit, ord));
}

/// `(.name u)` — the enum-constant name ("DAYS").
fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.name(.chrono_unit, ord));
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 2);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toString"), .method_val = Value.initBuiltinFn(&toString) };
    entries[1] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "name"), .method_val = Value.initBuiltinFn(&nameFn) };
    td.method_table = entries;
}

/// The 16 enum constants, generated from the canonical `host_enum` registry.
const static_fields = build: {
    var arr: [host_enum.count(.chrono_unit)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.chrono_unit, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.chrono_unit), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.temporal.ChronoUnit",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.temporal.ChronoUnit",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
    .host_enum_idx = @intFromEnum(host_enum.Idx.chrono_unit),
};
