// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.net.Socket`.
//!
//! Backend: impl-only
//! Impl deps: net
//! Clojure peer: none
//!
//! TypeDescriptor reservation per ADR-0029 D5. The backing impl
//! `runtime/net/socket.zig` (TCP client / server primitives) is
//! unbuilt — tracked by **D-106**. The surface is reachable through
//! `(rt.types.get "java.net.Socket")` and the
//! `cljw.java.net.Socket` namespace exists, but the method_table is
//! empty, so `(java.net.Socket. host port)` does not yet resolve.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.net.Socket",
    .descriptor = &descriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.net.Socket",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
