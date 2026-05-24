// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Random`.
//!
//! Backend: impl-only
//! Impl deps: random
//! Clojure peer: none (clojure.core/rand & rand-int land in
//! lang/clj/clojure/core.clj at Phase 6.9 with implementations
//! that route through this Java surface via Phase 7 dispatch)
//!
//! Phase 6.4 lands the `___HOST_EXTENSION` declaration; instance
//! methods (nextInt / nextLong / nextDouble / setSeed) wire through
//! Phase 7 dispatch (ADR-0008 a1) on top of `runtime/random.zig`.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.Random",
    .descriptor = &descriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.Random",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
