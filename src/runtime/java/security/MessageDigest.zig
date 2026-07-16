// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.security.MessageDigest`.
//!
//! Backend: impl-only
//! Impl deps: digest
//! Clojure peer: none
//!
//! TypeDescriptor reservation per ADR-0029 D5. The backing impl
//! `runtime/crypto/message_digest.zig` (SHA-256 / SHA-1 / MD5 via
//! Zig std.crypto) is unbuilt — tracked by **D-106**. The surface
//! is reachable through `(rt.types.get "java.security.MessageDigest")`
//! and the namespace exists, but the method_table is empty, so
//! `(java.security.MessageDigest/getInstance "SHA-256")` does not
//! yet resolve.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.security.MessageDigest",
    .descriptor = &descriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.security.MessageDigest",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
