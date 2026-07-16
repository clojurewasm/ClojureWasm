// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Byte` — `MIN_VALUE` / `MAX_VALUE` static fields
//! (ADR-0061). clojure.data.generators reads `Byte/MIN_VALUE` / `Byte/MAX_VALUE`
//! for its byte range; cljw has no `byte` primitive type (F-005), so these are
//! plain Long constants. No instance methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

const byte_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .int = 127 } },
    .{ .name = "MIN_VALUE", .value = .{ .int = -128 } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Byte",
    .descriptor = &descriptor,
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
