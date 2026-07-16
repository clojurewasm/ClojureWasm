// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.ZonedDateTime`.
//!
//! Backend: impl-only
//! Impl deps: time
//! Clojure peer: none
//!
//! TypeDescriptor reservation per ADR-0029 D5. Zone-aware date+time
//! semantics over a `runtime/time/zoned_date_time.zig` + ZoneId
//! table are unbuilt (the method_table is empty) — tracked by
//! **D-105**.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.ZonedDateTime",
    .descriptor = &descriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.ZonedDateTime",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
