// SPDX-License-Identifier: EPL-2.0
//! Layer-0 SSOT for "a value's metadata map": the `metaOf` read, the
//! `withMetaOrNull` / `resetMetaOrNull` writes, the reader's
//! `readerAttachOrNull` (ADR-0200), and extend-via-metadata protocol dispatch
//! (ADR-0144 / D-314).
//!
//! `metaOf` is the unified `(meta x)` read: `lang/primitive/metadata.zig::metaFn`
//! (the `(meta x)` primitive) delegates to it, and `metaDispatch` consults it for
//! receiver-metadata protocol dispatch. Living in Layer 0 lets the Layer-1
//! protocol-fn dispatch path read metadata without importing the Layer-2 `(meta)`
//! primitive (zone_deps), and keeps one meta-read switch instead of two (F-011).
//!
//! Imports `dispatch` one-way (for the `typed_instance`/`reified_instance` IObj
//! `-meta` path); `dispatch.zig` does NOT import this module, so there is no cycle.

const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const dispatch = @import("dispatch.zig");
const protocol_mod = @import("protocol.zig");
const vector = @import("collection/vector.zig");
const sub_vector = @import("collection/sub_vector.zig");
const map = @import("collection/map.zig");
const set = @import("collection/set.zig");
const sorted = @import("collection/sorted.zig");
const list = @import("collection/list.zig");
const lazy_seq = @import("lazy_seq.zig");
const atom = @import("atom.zig");
const agent = @import("agent.zig");
const ref = @import("stm/ref.zig");
const symbol = @import("symbol.zig");
const keyword = @import("keyword.zig");
const td_mod = @import("type_descriptor.zig");
const array_seq = @import("collection/array_seq.zig");
const string_seq = @import("collection/string_seq.zig");
const persistent_queue = @import("collection/persistent_queue.zig");
const root_set = @import("gc/root_set.zig");

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
/// The single meta-read switch shared by the `(meta x)` primitive and
/// extend-via-metadata dispatch. `typed_instance` / `reified_instance` honour a
/// user `IObj -meta` impl (D-280d7) before the native field; `var_ref` projects
/// the mechanical :name/:ns/:macro/:dynamic/:private keys (D-183).
pub fn metaOf(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    return switch (v.tag()) {
        .vector => vector.metaOf(v),
        .sub_vector => sub_vector.metaOf(v),
        .array_map, .hash_map => map.metaOf(v),
        .hash_set => set.metaOf(v),
        .sorted_map, .sorted_set => sorted.metaOf(v),
        .list, .cons => list.metaOf(v),
        .lazy_seq => lazy_seq.metaOf(v),
        .array_seq => array_seq.metaOf(v),
        .string_seq => string_seq.metaOf(v),
        .persistent_queue => persistent_queue.metaOf(v),
        .var_ref => try synthVarMeta(rt, v),
        .atom => atom.metaOf(v),
        .agent => agent.metaOf(v),
        .ref => ref.metaOf(v),
        .ns => v.decodePtr(*const env_mod.Namespace).meta,
        .symbol => symbol.metaOf(v),
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-meta", &.{v}, loc)) |r| break :blk r;
            break :blk td_mod.instMetaOf(v);
        },
        .reified_instance => blk: {
            // A user IObj `-meta` impl wins; else the native meta slot (ADR-0134).
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-meta", &.{v}, loc)) |r| break :blk r;
            break :blk td_mod.reifiedInstMetaOf(v);
        },
        else => Value.nil_val,
    };
}

/// `v` carrying the metadata `m` (a map or nil), or null when `v` is not an
/// IObj. The single meta-write switch shared by the `(with-meta v m)`
/// primitive, which raises on null, and the reader's `^meta` attach
/// (ADR-0200), which raises clj's reader error instead.
pub fn withMetaOrNull(rt: *Runtime, env: *Env, v: Value, m: Value, loc: SourceLocation) anyerror!?Value {
    return switch (v.tag()) {
        .vector => try vector.withMeta(rt, v, m),
        .sub_vector => try sub_vector.withMeta(rt, v, m),
        .array_map, .hash_map => try map.withMeta(rt, v, m),
        .hash_set => try set.withMeta(rt, v, m),
        .sorted_map, .sorted_set => try sorted.withMeta(rt, v, m),
        .list, .cons => try list.withMeta(rt, v, m),
        // A seq is IObj on the JVM (ASeq), so a vector VIEW must round-trip
        // meta as the eager list it replaced did.
        .array_seq => try array_seq.withMeta(rt, v, m),
        .string_seq => try string_seq.withMeta(rt, v, m),
        .lazy_seq => try lazy_seq.withMeta(rt, v, m),
        .persistent_queue => try persistent_queue.withMeta(rt, v, m),
        // D-304 / ADR-0110: mints a fresh non-interned symbol carrying meta.
        // Keyword stays in the `else` arm (clj rejects keyword metadata).
        .symbol => try symbol.withMeta(rt, v, m),
        // D-312: a defrecord supports with-meta natively (clj records carry a
        // hidden __meta field). A user IObj `-with-meta` impl wins (D-280d7); else
        // records mint a fresh instance with the meta; a plain deftype/reify
        // without an IObj impl is not an IObj (= clj ClassCastException).
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-with-meta", &.{ v, m }, loc)) |r| break :blk r;
            if (v.decodePtr(*const td_mod.TypedInstance).descriptor.kind == .defrecord)
                break :blk try td_mod.instWithMeta(rt, v, m);
            break :blk null;
        },
        // clj reify ALWAYS implements IObj: a user `-with-meta` impl wins, else
        // the native meta slot mints a fresh instance (ADR-0134; plain deftype,
        // which is NOT auto-IObj, stays `.typed_instance` and returns null).
        .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IObj", "-with-meta", &.{ v, m }, loc)) |r| break :blk r;
            break :blk try td_mod.reifiedInstWithMeta(rt, v, m);
        },
        else => null,
    };
}

/// Replace the metadata of a mutable reference (Var, atom, agent, ref,
/// namespace) in place and return the reference, or null when `r` is not
/// one: clj's IReference.resetMeta. `reset-meta!` raises on null; the
/// reader's `^meta` on a reference uses it too (ADR-0200). `m` is a map or nil.
pub fn resetMetaOrNull(r: Value, m: Value) ?Value {
    switch (r.tag()) {
        .var_ref => {
            const vr: *env_mod.Var = @constCast(r.decodePtr(*const env_mod.Var));
            vr.meta = if (m.isNil()) null else m;
        },
        .atom => atom.setMeta(r, m),
        .agent => agent.setMeta(r, m),
        .ref => ref.setMeta(r, m),
        // Namespace meta (D-239): GC-rooted by root_set's ns_vars walk.
        .ns => {
            const ns: *env_mod.Namespace = @constCast(r.decodePtr(*const env_mod.Namespace));
            ns.meta = m;
        },
        else => return null,
    }
    return r;
}

/// clj's MetaReader attach, the `^meta` a reader puts on a value it read
/// (ADR-0200): a reference has its meta replaced in place; an IObj gets a
/// copy whose meta is its existing meta merged with `m`, `m` winning on an
/// equal key; anything else is null, and the caller raises "Metadata can
/// only be applied to IMetas". `m` is a map.
pub fn readerAttachOrNull(rt: *Runtime, env: *Env, v: Value, m: Value, loc: SourceLocation) anyerror!?Value {
    if (resetMetaOrNull(v, m)) |r| return r;
    const old = try metaOf(rt, env, v, loc);
    // GC-ROOT: C — the merged meta lives only in this frame across the copy
    // `withMetaOrNull` allocates. [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{.nil_val};
    var sp: u16 = 1;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const plain_map = old.tag() == .array_map or old.tag() == .hash_map;
    roots[0] = if (plain_map) try map.mergeInto(rt, old, m) else m;
    return withMetaOrNull(rt, env, v, roots[0], loc);
}

/// Apply an `(ns name "docstring" …)` docstring onto the namespace's meta as
/// `{:doc "…"}` (clj parity — D-239 sibling). Shared by both backends' ns
/// execution (tree_walk evalNs + the VM's op_ns ops) so the semantics cannot
/// drift. Re-evaluating the ns form re-assocs :doc onto any existing meta.
pub fn setNsDoc(rt: *Runtime, ns: *env_mod.Namespace, doc: []const u8) !void {
    const string_mod = @import("collection/string.zig");
    const base = if (ns.meta.isNil()) map.empty() else ns.meta;
    ns.meta = try map.assoc(rt, base, try keyword.intern(rt, null, "doc"), try string_mod.alloc(rt, doc));
}

/// Merge an `(ns ^{…} name {:attr …})` lifted meta map onto the namespace's
/// meta (D-554; shared by both backends like `setNsDoc`). Applied BEFORE the
/// docstring so an explicit docstring wins over an attr-map `:doc`.
pub fn mergeNsMeta(rt: *Runtime, ns: *env_mod.Namespace, attr: Value) !void {
    const base = if (ns.meta.isNil()) map.empty() else ns.meta;
    ns.meta = try map.mergeInto(rt, base, attr);
}

/// Var-meta projection: the Var's stored `.meta` with the mechanical
/// :name/:ns/:macro/:dynamic/:private keys forced on top (the Var fields are the
/// SSOT; the map is a fresh projection — matches clj's Var.setMeta).
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

/// Extend-via-metadata dispatch (ADR-0144 / D-314). When `desc.extend_via_metadata`
/// is set, look up a fn on `receiver`'s metadata under the protocol-defining-ns-
/// qualified method SYMBOL (`<defining-ns>/<method>`) and, if present, call it —
/// returning the result. Returns `null` (fall through to the per-type dispatch)
/// when the flag is unset, the receiver has no map metadata, or the key is absent.
///
/// Per-VALUE, so it MUST run before the per-TYPE CallSite cache (`callProtocolFn`
/// invokes it before `dispatch.dispatch`): a meta hit returns here and never
/// writes the type cache, so two values of one type with different meta dispatch
/// differently (the cache-bypass invariant, ADR-0144).
pub fn metaDispatch(
    rt: *Runtime,
    env: *Env,
    desc: *const protocol_mod.ProtocolDescriptor,
    receiver: Value,
    method_name: []const u8,
    args: []const Value,
    loc: SourceLocation,
) anyerror!?Value {
    if (!desc.extend_via_metadata) return null;
    const m = try metaOf(rt, env, receiver, loc);
    if (m.tag() != .array_map and m.tag() != .hash_map) return null;
    // The metadata key is the defining-ns-qualified method symbol (e.g.
    // `user/sized`). The defining ns is captured on the descriptor (a bare
    // protocol name has a bare fqcn with no ns to split); empty → no meta key.
    const def_ns = desc.definingNs();
    if (def_ns.len == 0) return null;
    const key = try symbol.intern(rt, def_ns, method_name);
    const f = try map.get(m, key);
    if (f.tag() == .nil) return null;
    return try rt.vtable.?.callFn(rt, env, f, args, loc);
}
