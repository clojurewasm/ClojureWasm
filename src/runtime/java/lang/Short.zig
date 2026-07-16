// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Short` — `MIN_VALUE` / `MAX_VALUE` static fields
//! (ADR-0061). clojure.data.generators reads `Short/MIN_VALUE` /
//! `Short/MAX_VALUE` for its short range; cljw has no `short` primitive type
//! (F-005), so these are plain Long constants. No instance methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

// Both fit i48 → clean Long (mirrors Integer.zig's static-field pattern).
const short_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = 32767 } },
    .{ .name = "MIN_VALUE", .value = .{ .int = -32768 } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Short",
    .descriptor = &descriptor,
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
