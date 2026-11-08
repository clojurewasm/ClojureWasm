// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.atomic.AtomicInteger`.
//!
//! Backend: impl-only
//! Impl deps: _atomic.zig (shared CAS impl over `host_instance.state[0]`)
//! Clojure peer: none
//!
//! Surface: identical to AtomicLong — cljw has one integer width, so this
//! class stores an `i64` and never truncates to 32 bits (AD-062).

const host_api = @import("../../../_host_api.zig");
const type_descriptor = @import("../../../../type_descriptor.zig");
const atomic = @import("_atomic.zig");

var slot: ?*const type_descriptor.TypeDescriptor = null;
const Impl = atomic.Impl(&slot, "java.util.concurrent.atomic.AtomicInteger", .integer);

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.atomic.AtomicInteger",
    .descriptor = &descriptor,
    .init = &Impl.initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.atomic.AtomicInteger",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
