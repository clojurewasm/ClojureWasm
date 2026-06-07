// SPDX-License-Identifier: EPL-2.0
//! Runtime metadata primitives — `meta` / `with-meta`. Metadata storage
//! is a `meta: Value` field on each IObj collection (vector / map / set /
//! list / lazy_seq); `meta` reads it, `with-meta` shallow-copies the
//! collection (sharing internals) with the new meta. `vary-meta` is a
//! core.clj defn over these. Same-type ops (assoc/conj/dissoc) already
//! thread `.meta` so metadata is preserved. `reset-meta!` (here) +
//! `alter-meta!` (core.clj) mutate a Var's / atom's meta slot; namespace /
//! ref / agent meta and symbol/keyword meta are deferred (D-239).
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
const atom = @import("../../runtime/atom.zig");
const symbol = @import("../../runtime/symbol.zig");
const keyword = @import("../../runtime/keyword.zig");

/// Project the mechanical var-meta keys onto the Var's stored `.meta`
/// (Stage 1.4 synthesize-on-read). `:name` (bare symbol) + `:ns` (first-class
/// namespace value) are always present; `:macro`/`:dynamic`/`:private` only
/// when the corresponding flag is set — matching clj's `(meta #'x)` key set.
/// User meta (`:doc`/`:arglists`/…) is preserved; mechanical keys win on a
/// clash (clj forces :name/:ns over user meta). `:line`/`:file` are out of
/// scope; `:ns` renders as a bare namespace, not clj's `#object[…]` (AD-021).
fn synthVarMeta(rt: *Runtime, v: Value) !Value {
    const vr = v.decodePtr(*const env_mod.Var);
    var m = vr.meta orelse map.empty();
    m = try map.assoc(rt, m, try keyword.intern(rt, null, "name"), try symbol.intern(rt, null, vr.name));
    m = try map.assoc(rt, m, try keyword.intern(rt, null, "ns"), Env.nsValue(vr.ns));
    if (vr.flags.macro_)
        m = try map.assoc(rt, m, try keyword.intern(rt, null, "macro"), Value.true_val);
    if (vr.flags.dynamic)
        m = try map.assoc(rt, m, try keyword.intern(rt, null, "dynamic"), Value.true_val);
    if (vr.flags.private)
        m = try map.assoc(rt, m, try keyword.intern(rt, null, "private"), Value.true_val);
    return m;
}

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
pub fn metaFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("meta", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .vector => vector.metaOf(v),
        .array_map, .hash_map => map.metaOf(v),
        .hash_set => set.metaOf(v),
        .list => list.metaOf(v),
        .lazy_seq => lazy_seq.metaOf(v),
        // D-183 + Stage 1.4 synthesize-on-read: `(meta #'x)` returns the Var's
        // stored `.meta` (populated by `analyzeDef` from a `^meta` def target)
        // with the MECHANICAL keys :name/:ns/:macro/:dynamic/:private projected
        // from the Var's own fields on top — matching clj's Var.setMeta forcing
        // of :name/:ns. The Var fields are the SSOT; the map is a fresh
        // projection (no stored redundant map → no bootstrap allocation cost).
        .var_ref => try synthVarMeta(rt, v),
        .atom => atom.metaOf(v),
        // D-304 / ADR-0110: a symbol's value-metadata (nil for interned).
        .symbol => symbol.metaOf(v),
        // D-280d7 functional: a deftype/reify implementing clojure.lang.IObj
        // `meta` → consult IObj/-meta; nil if it does not implement IObj.
        .typed_instance, .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            break :blk (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-meta", &.{v}, loc)) orelse Value.nil_val;
        },
        else => Value.nil_val,
    };
}

/// `(reset-meta! iref metadata-map)` — set the metadata of a mutable
/// reference (Var or atom) to `metadata-map` (a map or nil), returning
/// the new metadata. `alter-meta!` (core.clj) is `(reset-meta! r (apply f
/// (meta r) args))`. Namespace / ref / agent targets are deferred (their
/// meta slot does not exist yet — D-239).
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
        // D-280d7 functional: a deftype/reify implementing clojure.lang.IObj
        // `withMeta` → consult IObj/-with-meta; a non-IObj instance keeps the
        // not-an-IObj error.
        .typed_instance, .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-with-meta", &.{ v, m }, loc)) |r| break :blk r;
            break :blk error_catalog.raise(.with_meta_target_not_iobj, loc, .{ .actual = @tagName(v.tag()) });
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
