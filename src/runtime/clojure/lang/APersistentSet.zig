// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.APersistentSet` static helpers (ADR-0108 am1).
//!
//! Backend: impl-only
//! Impl deps: coll_hash
//! Clojure peer: clojure.core/=
//!
//! JVM `APersistentSet` exposes exactly ONE pure static — `setEquals`
//! (hashCode/hasheq are instance methods, so there is no `setHash` static; cljw
//! does NOT invent one — that would be the F-013 ad-hoc special-casing trap). data.avl calls
//! `(APersistentSet/setEquals this other)` from its deftype `equals` body.

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const coll_hash = @import("../../coll_hash.zig");

/// `(clojure.lang.APersistentSet/setEquals s1 other)` — membership-wise equality
/// (same count, every `s1` element in `other`); a non-set `other` → false.
fn setEquals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.APersistentSet/setEquals", args, 2, loc);
    return if (try coll_hash.setEquals(rt, env, args[0], args[1], loc)) .true_val else .false_val;
}

fn initAPersistentSet(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "setEquals", &setEquals },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.clojure.lang.APersistentSet",
    .descriptor = &descriptor,
    .init = &initAPersistentSet,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.APersistentSet",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
