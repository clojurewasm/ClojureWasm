// SPDX-License-Identifier: EPL-2.0
//! Runtime metadata primitives — `meta` / `with-meta`. Metadata storage
//! is a `meta: Value` field on each IObj collection (vector / map / set /
//! list / lazy_seq); `meta` reads it, `with-meta` shallow-copies the
//! collection (sharing internals) with the new meta. `vary-meta` is a
//! core.clj defn over these. Same-type ops (assoc/conj/dissoc) already
//! thread `.meta` so metadata is preserved. `reset-meta!` (here) +
//! `alter-meta!` (core.clj) mutate a Var's / atom's / agent's / ref's /
//! namespace's meta slot (D-239); keyword meta stays rejected
//! (clj parity; D-075).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const meta_mod = @import("../../runtime/meta.zig");

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
/// Delegates to the Layer-0 `meta_mod.metaOf` SSOT (shared with extend-via-
/// metadata protocol dispatch, ADR-0144 — one meta-read switch, not two).
pub fn metaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("meta", args, 1, loc);
    return meta_mod.metaOf(rt, env, args[0], loc);
}

/// `(reset-meta! iref metadata-map)` — set the metadata of a mutable
/// reference (Var, atom, agent, ref or namespace) to `metadata-map` (a map
/// or nil), returning the new metadata. `alter-meta!` (core.clj) is
/// `(reset-meta! r (apply f (meta r) args))`. Which values are references is
/// decided by `meta_mod.resetMetaOrNull`.
pub fn resetMetaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("reset-meta!", args, 2, loc);
    const r = args[0];
    const m = args[1];
    if (!(m.isNil() or m.tag() == .array_map or m.tag() == .hash_map))
        return error_catalog.raise(.reset_meta_meta_not_map, loc, .{ .actual = @tagName(m.tag()) });
    if (meta_mod.resetMetaOrNull(r, m) == null)
        return error_catalog.raise(.reset_meta_target_not_ref, loc, .{ .actual = @tagName(r.tag()) });
    return m;
}

/// `(with-meta obj m)` — a new obj with the same VALUE but metadata = m
/// (a map or nil). Throws on a non-IObj target or a non-map `m`. Which
/// values are IObj is decided by `meta_mod.withMetaOrNull`.
pub fn withMetaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("with-meta", args, 2, loc);
    const v = args[0];
    const m = args[1];
    if (!(m.isNil() or m.tag() == .array_map or m.tag() == .hash_map)) {
        return error_catalog.raise(.with_meta_meta_not_map, loc, .{ .actual = @tagName(m.tag()) });
    }
    if (try meta_mod.withMetaOrNull(rt, env, v, m, loc)) |r| return r;
    return error_catalog.raise(.with_meta_target_not_iobj, loc, .{ .actual = @tagName(v.tag()) });
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "meta", .f = &metaFn },
    .{ .name = "with-meta", .f = &withMetaFn },
    .{ .name = "reset-meta!", .f = &resetMetaFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
