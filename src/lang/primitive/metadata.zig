// SPDX-License-Identifier: EPL-2.0
//! Runtime metadata primitives — `meta` / `with-meta`. Metadata storage
//! is a `meta: Value` field on each IObj collection (vector / map / set /
//! list / lazy_seq); `meta` reads it, `with-meta` shallow-copies the
//! collection (sharing internals) with the new meta. `vary-meta` is a
//! core.clj defn over these. Same-type ops (assoc/conj/dissoc) already
//! thread `.meta` so metadata is preserved. `reset-meta!` (here) +
//! `alter-meta!` (core.clj) mutate a Var's / atom's / agent's / ref's /
//! namespace's meta slot (D-239 complete); keyword meta stays rejected
//! (clj parity). Metadata cycle 2026-05-30; discharges D-075.

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
const atom = @import("../../runtime/atom.zig");
const agent = @import("../../runtime/agent.zig");
const ref_mod = @import("../../runtime/stm/ref.zig");
const symbol = @import("../../runtime/symbol.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const meta_mod = @import("../../runtime/meta.zig");

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
/// Delegates to the Layer-0 `meta_mod.metaOf` SSOT (shared with extend-via-
/// metadata protocol dispatch, ADR-0144 — one meta-read switch, not two).
pub fn metaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("meta", args, 1, loc);
    return meta_mod.metaOf(rt, env, args[0], loc);
}

/// `(reset-meta! iref metadata-map)` — set the metadata of a mutable
/// reference (Var, atom, or agent) to `metadata-map` (a map or nil), returning
/// the new metadata. `alter-meta!` (core.clj) is `(reset-meta! r (apply f
/// (meta r) args))`. Namespace / ref targets are deferred (their meta slot
/// does not exist yet — D-239; agent landed with D-441).
pub fn resetMetaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("reset-meta!", args, 2, loc);
    const r = args[0];
    const m = args[1];
    if (!(m.isNil() or m.tag() == .array_map or m.tag() == .hash_map))
        return error_catalog.raise(.reset_meta_meta_not_map, loc, .{ .actual = @tagName(m.tag()) });
    switch (r.tag()) {
        .var_ref => {
            const vr: *env_mod.Var = @constCast(r.decodePtr(*const env_mod.Var));
            vr.meta = if (m.isNil()) null else m;
        },
        .atom => atom.setMeta(r, m),
        .agent => agent.setMeta(r, m),
        .ref => ref_mod.setMeta(r, m),
        // Namespace meta (D-239 last remainder): mutate the ns's meta slot
        // (GC-rooted by root_set's ns_vars walk).
        .ns => {
            const ns: *env_mod.Namespace = @constCast(r.decodePtr(*const env_mod.Namespace));
            ns.meta = m;
        },
        else => return error_catalog.raise(.reset_meta_target_not_ref, loc, .{ .actual = @tagName(r.tag()) }),
    }
    return m;
}

/// `(with-meta obj m)` — a new obj with the same VALUE but metadata = m
/// (a map or nil). Throws on a non-IObj target or a non-map `m`.
pub fn withMetaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
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
        // D-304 / ADR-0110: mints a fresh non-interned symbol carrying meta.
        // Keyword stays in the `else` arm (clj rejects keyword metadata).
        .symbol => try symbol.withMeta(rt, v, m),
        // D-312: a defrecord supports with-meta natively (clj records carry a
        // hidden __meta field). A user IObj `-with-meta` impl wins (D-280d7); else
        // records mint a fresh instance with the meta; a plain deftype/reify
        // without an IObj impl keeps the not-an-IObj error (= clj ClassCastException).
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-with-meta", &.{ v, m }, loc)) |r| break :blk r;
            if (v.decodePtr(*const td_mod.TypedInstance).descriptor.kind == .defrecord)
                break :blk try td_mod.instWithMeta(rt, v, m);
            break :blk error_catalog.raise(.with_meta_target_not_iobj, loc, .{ .actual = @tagName(v.tag()) });
        },
        // clj reify ALWAYS implements IObj: a user `-with-meta` impl wins, else
        // the native meta slot mints a fresh instance (ADR-0134; plain deftype,
        // which is NOT auto-IObj, stays `.typed_instance` and keeps its error).
        .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-with-meta", &.{ v, m }, loc)) |r| break :blk r;
            break :blk try td_mod.reifiedInstWithMeta(rt, v, m);
        },
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
    .{ .name = "reset-meta!", .f = &resetMetaFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
