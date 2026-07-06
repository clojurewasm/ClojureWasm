// SPDX-License-Identifier: EPL-2.0
//! Layer-0 SSOT for "a value's metadata map" + extend-via-metadata protocol
//! dispatch (ADR-0144 / D-314).
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
const map = @import("collection/map.zig");
const set = @import("collection/set.zig");
const list = @import("collection/list.zig");
const lazy_seq = @import("lazy_seq.zig");
const atom = @import("atom.zig");
const agent = @import("agent.zig");
const ref = @import("stm/ref.zig");
const symbol = @import("symbol.zig");
const keyword = @import("keyword.zig");
const td_mod = @import("type_descriptor.zig");

/// `(meta obj)` — obj's metadata map, or nil for a non-IObj / no-meta value.
/// The single meta-read switch shared by the `(meta x)` primitive and
/// extend-via-metadata dispatch. `typed_instance` / `reified_instance` honour a
/// user `IObj -meta` impl (D-280d7) before the native field; `var_ref` projects
/// the mechanical :name/:ns/:macro/:dynamic/:private keys (D-183).
pub fn metaOf(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    return switch (v.tag()) {
        .vector => vector.metaOf(v),
        .array_map, .hash_map => map.metaOf(v),
        .hash_set => set.metaOf(v),
        .list => list.metaOf(v),
        .lazy_seq => lazy_seq.metaOf(v),
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

/// Apply an `(ns name "docstring" …)` docstring onto the namespace's meta as
/// `{:doc "…"}` (clj parity — D-239 sibling). Shared by both backends' ns
/// execution (tree_walk evalNs + the VM's op_ns ops) so the semantics cannot
/// drift. Re-evaluating the ns form re-assocs :doc onto any existing meta.
pub fn setNsDoc(rt: *Runtime, ns: *env_mod.Namespace, doc: []const u8) !void {
    const string_mod = @import("collection/string.zig");
    const base = if (ns.meta.isNil()) map.empty() else ns.meta;
    ns.meta = try map.assoc(rt, base, try keyword.intern(rt, null, "doc"), try string_mod.alloc(rt, doc));
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
