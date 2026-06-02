// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.UUID`.
//!
//! Backend: impl-only
//! Impl deps: uuid
//! Clojure peer: clojure.core/random-uuid, clojure.core/parse-uuid
//!
//! Thin wrapper over `runtime/uuid.zig` per F-009. The Clojure-ns
//! peer (`lang/primitive/uuid.zig`) calls the same impl; this file
//! is the entry point for `(java.util.UUID/randomUUID)` and similar
//! Java-style static invocations.
//!
//! D-121 + ADR-0050: populates `method_table` for the static method
//! `randomUUID`. Dispatched via `InteropCallNode { .kind =
//! .static_method }`. Return Value is the canonical 36-char string
//! form (matches the Clojure-peer `random-uuid` shape; a
//! `host_instance` UUID Value is a Phase 7+ ergonomic ride-along).
//!
//! method_table is populated in `initUUID` (runtime) rather than at
//! module scope because `Value.initBuiltinFn(&fn)` calls
//! `@intFromPtr(&fn)` which is not comptime-known on Mac targets in
//! Zig 0.16.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const uuid = @import("../../uuid.zig");

/// Implements `(java.util.UUID/randomUUID)`.
/// Spec: returns a UUID v4 `.uuid` value (ADR-0074; was a canonical String
/// pre-cycle-3). Matches JVM `java.util.UUID.randomUUID()` returning a UUID
/// instance + `clojure.core/random-uuid`.
/// JVM reference: java.util.UUID#randomUUID (java.base/java/util/UUID.java).
/// cw v1 tier: A (Phase 14 row 14.11 / D-121).
fn randomUUID(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.UUID/randomUUID", args, 0, loc);
    return try uuid.alloc(rt, uuid.generateV4(rt.io));
}

const std = @import("std");

fn initUUID(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "randomUUID"),
        .method_val = Value.initBuiltinFn(&randomUUID),
    };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.UUID",
    .descriptor = &descriptor,
    .init = &initUUID,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.UUID",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
