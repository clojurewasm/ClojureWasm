// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.APersistentMap` static helpers (ADR-0108 am1).
//!
//! Backend: impl-only
//! Impl deps: coll_hash, equal
//! Clojure peer: clojure.core/hash, clojure.core/=
//!
//! Custom-collection libraries (flatland.ordered, data.avl, tech.ml.dataset)
//! call these statics from their deftype `hashCode`/`hasheq`/`equals` bodies —
//! e.g. flatland.ordered.map `(hashCode [this] (APersistentMap/mapHash this))`.
//! `this` is a deftype INSTANCE implementing the map interface, iterated via the
//! protocol-seq vtable callback (see `runtime/coll_hash.zig`).
//!
//! `mapHash` and `mapHasheq` return cljw's SINGLE content hash (ADR-0108 am1
//! DA-fork Alt 2 — cljw collapsed the JVM additive-hashCode/murmur-hasheq split
//! into one `valueHash`), so a custom map and an `=`-equal native map share one
//! `.hashCode`. AD-009: intra-cljw value, not JVM bit-parity.

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const coll_hash = @import("../../coll_hash.zig");

/// `(clojure.lang.APersistentMap/mapHash m)` — the map's content hash (cljw's
/// single value-hash; ADR-0108 am1). Equals an `=`-equal native map's hash.
fn mapHash(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.APersistentMap/mapHash", args, 1, loc);
    return Value.initInteger(@as(i32, @bitCast(try coll_hash.mapContentHash(rt, env, args[0], loc))));
}

/// `(clojure.lang.APersistentMap/mapHasheq m)` — same value as `mapHash` in cljw
/// (one hash notion; the JVM additive/murmur split has no cljw counterpart).
fn mapHasheq(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.APersistentMap/mapHasheq", args, 1, loc);
    return Value.initInteger(@as(i32, @bitCast(try coll_hash.mapContentHash(rt, env, args[0], loc))));
}

/// `(clojure.lang.APersistentMap/mapEquals m1 other)` — entry-wise equality
/// (clj's `.equals` flavour); a non-map `other` → false.
fn mapEquals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.APersistentMap/mapEquals", args, 2, loc);
    return if (try coll_hash.mapEquals(rt, env, args[0], args[1], loc)) .true_val else .false_val;
}

fn initAPersistentMap(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "mapHash", &mapHash },
        .{ "mapHasheq", &mapHasheq },
        .{ "mapEquals", &mapEquals },
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
    .cljw_ns = "cljw.clojure.lang.APersistentMap",
    .descriptor = &descriptor,
    .init = &initAPersistentMap,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.APersistentMap",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
