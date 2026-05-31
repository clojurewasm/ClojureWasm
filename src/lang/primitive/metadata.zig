// SPDX-License-Identifier: EPL-2.0
//! Runtime metadata primitives — `meta` / `with-meta`. Metadata storage
//! is a `meta: Value` field on each IObj collection (vector / map / set /
//! list / lazy_seq); `meta` reads it, `with-meta` shallow-copies the
//! collection (sharing internals) with the new meta. `vary-meta` is a
//! core.clj defn over these. Same-type ops (assoc/conj/dissoc) already
//! thread `.meta` so metadata is preserved. Reader `^meta`, alter-meta! /
//! reset-meta! (mutable ref meta), and symbol/keyword meta are deferred.
//! Metadata cycle 2026-05-30; discharges D-075.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const vector = @import("../../runtime/collection/vector.zig");
const map = @import("../../runtime/collection/map.zig");
const set = @import("../../runtime/collection/set.zig");
const list = @import("../../runtime/collection/list.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
pub fn metaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("meta", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .vector => vector.metaOf(v),
        .array_map, .hash_map => map.metaOf(v),
        .hash_set => set.metaOf(v),
        .list => list.metaOf(v),
        .lazy_seq => lazy_seq.metaOf(v),
        // D-183: `(meta #'x)` reads the Var's `.meta` Clojure-map slot,
        // populated by `analyzeDef` from a `^meta` def target.
        .var_ref => v.decodePtr(*const env_mod.Var).meta orelse Value.nil_val,
        else => Value.nil_val,
    };
}

/// `(with-meta obj m)` — a new obj with the same VALUE but metadata = m
/// (a map or nil). Throws on a non-IObj target or a non-map `m`.
pub fn withMetaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("with-meta", args, 2, loc);
    const v = args[0];
    const m = args[1];
    if (!(m.isNil() or m.tag() == .array_map or m.tag() == .hash_map)) {
        return error_catalog.raise(.with_meta_meta_not_map, loc, .{ .actual = @tagName(m.tag()) });
    }
    return switch (v.tag()) {
        .vector => try vector.withMeta(rt, v, m),
        .array_map, .hash_map => try map.withMeta(rt, v, m),
        .hash_set => try set.withMeta(rt, v, m),
        .list => try list.withMeta(rt, v, m),
        .lazy_seq => try lazy_seq.withMeta(rt, v, m),
        else => error_catalog.raise(.with_meta_target_not_iobj, loc, .{ .actual = @tagName(v.tag()) }),
    };
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "meta", .f = &metaFn },
    .{ .name = "with-meta", .f = &withMetaFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
