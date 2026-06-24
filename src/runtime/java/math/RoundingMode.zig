// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.math.RoundingMode` — the 8 enum constants
//! (UP..UNNECESSARY) as host-enum singletons + `.toString` (the constant
//! name). This is the clj-modern rounding API: `(.setScale bd n RoundingMode/X)`
//! / `(.divide …)` take a RoundingMode, where the deprecated `BigDecimal/ROUND_*`
//! ints are the legacy form. Modeled as host_instance singletons (not the
//! int-ordinal anti-pattern) so `(class RoundingMode/X)` = `java.math.RoundingMode`
//! and `(= RoundingMode/X 4)` is false — clj parity (ADR-0160).
//!
//! Backend: impl-only
//! Impl deps: rounding_mode
//! Clojure peer: none.
//!
//! The singletons + the canonical name↔ordinal mapping live in the neutral
//! host-enum registry `runtime/host_enum.zig` (so the analyzer's static-field
//! resolve + `Runtime.deinit` reach them without importing this surface tree, per
//! the zone rule). This file owns the descriptor + static-field table + `.toString`.

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

/// `(str rm)` / `(.toString rm)` — the bare JVM enum-constant name ("HALF_UP").
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const ord: u8 = @intCast(host_instance.asHostInstance(args[0]).state[0]);
    return string_collection.alloc(rt, host_enum.toStringOf(.rounding_mode, ord));
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "toString"), .method_val = Value.initBuiltinFn(&toString) };
    td.method_table = entries;
}

/// The 8 enum constants, generated from the canonical `rounding_mode` table so
/// the names↔ordinals are a single source of truth (shared with BigDecimal's
/// `ROUND_*` int table). Each resolves to the cached ordinal-bearing singleton.
const static_fields = build: {
    var arr: [host_enum.count(.rounding_mode)]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{
            .name = host_enum.name(.rounding_mode, @intCast(i)),
            .value = .{ .host_enum = .{ .enum_idx = @intFromEnum(host_enum.Idx.rounding_mode), .ordinal = @intCast(i) } },
        };
    }
    break :build arr;
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.math.RoundingMode",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.math.RoundingMode",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
};
