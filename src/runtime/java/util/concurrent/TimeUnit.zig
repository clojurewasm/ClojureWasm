// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.TimeUnit` — the 7 enum constants
//! (NANOSECONDS..DAYS) as host-enum singletons + `.toString` / `.name` /
//! `.toMillis`.
//!
//! Backend: impl-only
//! Impl deps: host_enum
//! Clojure peer: none

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

/// Nanoseconds in one unit of each constant, indexed by ordinal.
const NANOS_PER = [_]i64{ 1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000 };

fn ordinalOf(v: Value) u8 {
    return @intCast(host_instance.asHostInstance(v).state[0]);
}

/// `(str u)` / `(.toString u)` — the enum-constant name ("MILLISECONDS").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    return string_collection.alloc(rt, host_enum.toStringOf(.time_unit, ordinalOf(args[0])));
}

/// `(.name u)` — the enum-constant name.
fn nameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("name", args, 1, loc);
    return string_collection.alloc(rt, host_enum.name(.time_unit, ordinalOf(args[0])));
}

/// `(.toMillis u n)` — `n` units expressed in milliseconds, truncated toward
/// zero for sub-millisecond units. Saturates rather than overflowing.
fn toMillis(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".toMillis", args, 2, loc);
    const n = try error_catalog.expectInteger(args[1], ".toMillis", loc);
    const nanos = NANOS_PER[ordinalOf(args[0])];
    const total = std.math.mul(i64, n, nanos) catch
        return Value.initInteger(if (n < 0) std.math.minInt(i64) else std.math.maxInt(i64));
    return Value.initInteger(@divTrunc(total, 1_000_000));
}

/// `(.toNanos u n)` — `n` units expressed in nanoseconds; saturating.
fn toNanos(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".toNanos", args, 2, loc);
    const n = try error_catalog.expectInteger(args[1], ".toNanos", loc);
    const nanos = NANOS_PER[ordinalOf(args[0])];
    return Value.initInteger(std.math.mul(i64, n, nanos) catch
        (if (n < 0) std.math.minInt(i64) else std.math.maxInt(i64)));
}

/// `n` units of `unit_val` in nanoseconds, saturating; null when `unit_val` is
/// not a TimeUnit constant. The sole reader of NANOS_PER outside this file.
pub fn nanosOf(unit_val: Value, n: i64) ?i64 {
    if (unit_val.tag() != .host_instance) return null;
    const inst = host_instance.asHostInstance(unit_val);
    const inst_fqcn = inst.descriptor.fqcn orelse return null;
    if (!std.mem.eql(u8, inst_fqcn, descriptor.fqcn.?)) return null;
    const nanos = NANOS_PER[@as(usize, @intCast(inst.state[0]))];
    return std.math.mul(i64, n, nanos) catch
        (if (n < 0) std.math.minInt(i64) else std.math.maxInt(i64));
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 4);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toString"), .method_val = Value.initBuiltinFn(&toString) };
    entries[1] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "name"), .method_val = Value.initBuiltinFn(&nameFn) };
    entries[2] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toMillis"), .method_val = Value.initBuiltinFn(&toMillis) };
    entries[3] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toNanos"), .method_val = Value.initBuiltinFn(&toNanos) };
    td.method_table = entries;
    const statics = host_enum.Statics(.time_unit);
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "values", &statics.values },
        .{ "valueOf", &statics.valueOf },
    });
}

const static_fields = build: {
    var arr: [host_enum.count(.time_unit)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.time_unit, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.time_unit), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.TimeUnit",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.TimeUnit",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
    .host_enum_idx = @intFromEnum(host_enum.Idx.time_unit),
};
