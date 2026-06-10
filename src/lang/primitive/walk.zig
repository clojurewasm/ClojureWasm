// SPDX-License-Identifier: EPL-2.0
//! `clojure.walk/` namespace surface.
//!
//! Per the survey at `private/notes/phase6-6.11-survey.md`,
//! cw v1 adopts DIVERGENCE D1: the `walk` spine lives in this Zig
//! file and dispatches over `Value.Tag` directly, calling user fns
//! via `rt.vtable.callFn` (the pattern proven in
//! `lang/primitive/string.zig::escape`). The JVM
//! `(walk (partial prewalk f) identity (f form))` shape is realised
//! as explicit Zig recursion rather than via `partial`.
//!
//! `walk` is the one-level rebuild primitive; `keywordize-keys` /
//! `stringify-keys` / `prewalk` / `postwalk` / `prewalk-replace` /
//! `postwalk-replace` are Pattern A `.clj` defns over it in
//! `src/lang/clj/clojure/walk.clj`.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const dispatch = @import("../../runtime/dispatch.zig");

const vector_collection = @import("../../runtime/collection/vector.zig");
const list_collection = @import("../../runtime/collection/list.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const root_set = @import("../../runtime/gc/root_set.zig");

fn callOne(rt: *Runtime, env: *Env, fn_val: Value, arg: Value, loc: SourceLocation) anyerror!Value {
    if (fn_val.tag() != .fn_val and fn_val.tag() != .builtin_fn)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.walk callback (non-fn)" });
    const vt = rt.vtable orelse return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.walk (vtable not installed)" });
    const args = [_]Value{arg};
    return vt.callFn(rt, env, fn_val, &args, loc);
}

/// Rebuild a list with `transform_child` applied to each element.
/// Builds the result tail-first by collecting transformed children
/// into a temporary buffer (so we can `consHeap` in reverse).
fn rebuildList(
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    form: Value,
    /// Generic transformer: returns the transformed child Value.
    /// `ctx` is the caller's threaded state (fn Value + loc).
    comptime transform_child: fn (rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value,
    ctx: anytype,
) anyerror!Value {
    const n = list_collection.countOf(form);
    if (n == 0) return form;
    var buf: std.ArrayList(Value) = .empty;
    defer buf.deinit(rt.gc.infra);
    var cur = form;
    // GC-ROOT: C6 — root the source cursor (stack) + the transformed-so-far gpa
    // accumulator (locals = buf.items) across transform_child (D-252) [ref:
    // .dev/gc_rooting.md §C]. buf.items is refreshed each iter (append may realloc).
    var src_root: [1]Value = .{cur};
    var src_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &src_root, .sp = &src_sp, .locals = buf.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    while (cur.tag() == .list and list_collection.countOf(cur) > 0) {
        src_root[0] = cur;
        gc_frame.locals = buf.items;
        const child = list_collection.first(cur);
        const t = try transform_child(rt, env, ctx, child, loc);
        try buf.append(rt.gc.infra, t);
        cur = list_collection.rest(cur);
    }
    var result: Value = .nil_val;
    var i: usize = buf.items.len;
    while (i > 0) {
        i -= 1;
        result = try list_collection.consHeap(rt, buf.items[i], result);
    }
    return result;
}

fn rebuildVector(
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    form: Value,
    comptime transform_child: fn (rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value,
    ctx: anytype,
) anyerror!Value {
    const n = vector_collection.count(form);
    var result = vector_collection.empty();
    // GC-ROOT: C6 — root the source + the in-progress accumulator across the
    // reentrant transform_child (vt.callFn re-enters the VM) [ref: .dev/gc_rooting.md §C].
    // Without it a torture collect sweeps `result`; the next conj memcpy's a
    // garbage tail (D-252).
    var gc_roots: [2]Value = .{ form, result };
    var gc_sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        gc_roots[1] = result;
        const child = vector_collection.nth(form, i);
        const t = try transform_child(rt, env, ctx, child, loc);
        result = try vector_collection.conj(rt, result, t);
    }
    return result;
}

fn rebuildSet(
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    form: Value,
    comptime transform_child: fn (rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value,
    ctx: anytype,
) anyerror!Value {
    var result = set_collection.empty();
    var seq_v = try set_collection.seq(rt, form);
    // GC-ROOT: C6 — root the source cursor + accumulator across transform_child (D-252) [ref: .dev/gc_rooting.md §C]
    var gc_roots: [2]Value = .{ seq_v, result };
    var gc_sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    while (seq_v.tag() == .list and list_collection.countOf(seq_v) > 0) {
        gc_roots[0] = seq_v;
        gc_roots[1] = result;
        const child = list_collection.first(seq_v);
        const t = try transform_child(rt, env, ctx, child, loc);
        result = try set_collection.conj(rt, result, t);
        seq_v = list_collection.rest(seq_v);
    }
    return result;
}

/// Rebuild an array_map by walking each entry as a 2-vector and
/// applying `transform_child` to it. The transformer must return
/// a 2-vector (or 2-element collection); the resulting key/value
/// pair is `assoc`-ed into the rebuilt map. Per DIVERGENCE 1 the
/// inner fn sees `[k v]` not a JVM `MapEntry`.
fn rebuildArrayMap(
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    form: Value,
    comptime transform_child: fn (rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value,
    ctx: anytype,
) anyerror!Value {
    var result = map_collection.empty();
    const am = form.decodePtr(*const map_collection.ArrayMap);
    // GC-ROOT: C6 — root the source map + accumulator + the in-flight [k v] entry
    // across transform_child (D-252) [ref: .dev/gc_rooting.md §C].
    var gc_roots: [3]Value = .{ form, result, .nil_val };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        // Synthesize the [k v] 2-vector.
        var entry = vector_collection.empty();
        entry = try vector_collection.conj(rt, entry, am.entries[2 * i]);
        entry = try vector_collection.conj(rt, entry, am.entries[2 * i + 1]);
        gc_roots[1] = result;
        gc_roots[2] = entry;
        const transformed = try transform_child(rt, env, ctx, entry, loc);
        // Expect transformed back to a 2-vector.
        if (transformed.tag() != .vector or vector_collection.count(transformed) != 2)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.walk map child returned non-2-vector" });
        result = try map_collection.assoc(rt, result, vector_collection.nth(transformed, 0), vector_collection.nth(transformed, 1));
    }
    return result;
}

const HashMapCollectCtx = struct { list: *std.ArrayList(Value), gpa: std.mem.Allocator };

fn collectHashEntry(c: *HashMapCollectCtx, k: Value, v: Value) anyerror!void {
    try c.list.append(c.gpa, k);
    try c.list.append(c.gpa, v);
}

/// `rebuildArrayMap`'s `.hash_map` (> 8 entries) counterpart. The HAMT has no
/// flat entries array, so collect every `(k v)` first via the pure
/// `map.forEachEntry` (the collected Values stay alive through `form`, rooted
/// below), then rebuild reentrantly with the same C6 rooting as the array_map
/// path. Was a stale `feature_not_supported` stub citing D-045 — but D-045 (the
/// HAMT body) landed 2026-05-30, so `clojure.walk` on a > 8-key map (e.g.
/// `keywordize-keys` over a JSON-parsed map) just needed wiring.
fn rebuildHashMap(
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    form: Value,
    comptime transform_child: fn (rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value,
    ctx: anytype,
) anyerror!Value {
    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(rt.gpa);
    var collect_ctx = HashMapCollectCtx{ .list = &entries, .gpa = rt.gpa };
    try map_collection.forEachEntry(form, &collect_ctx, collectHashEntry);

    var result = map_collection.empty();
    // GC-ROOT: C6 — root the source map (keeps the collected entries alive) +
    // accumulator + the in-flight [k v] entry across transform_child (D-252)
    // [ref: .dev/gc_rooting.md §C].
    var gc_roots: [3]Value = .{ form, result, .nil_val };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var i: usize = 0;
    while (i < entries.items.len) : (i += 2) {
        var entry = vector_collection.empty();
        entry = try vector_collection.conj(rt, entry, entries.items[i]);
        entry = try vector_collection.conj(rt, entry, entries.items[i + 1]);
        gc_roots[1] = result;
        gc_roots[2] = entry;
        const transformed = try transform_child(rt, env, ctx, entry, loc);
        if (transformed.tag() != .vector or vector_collection.count(transformed) != 2)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.walk map child returned non-2-vector" });
        result = try map_collection.assoc(rt, result, vector_collection.nth(transformed, 0), vector_collection.nth(transformed, 1));
    }
    return result;
}

// --- walk (one-level) ---

const WalkCtx = struct { inner: Value };

fn walkInnerCallback(rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value {
    return callOne(rt, env, ctx.inner, child, loc);
}

fn walkRebuild(rt: *Runtime, env: *Env, inner: Value, form: Value, loc: SourceLocation) anyerror!Value {
    const ctx = WalkCtx{ .inner = inner };
    return switch (form.tag()) {
        .list, .cons => rebuildList(rt, env, loc, form, walkInnerCallback, ctx),
        .vector => rebuildVector(rt, env, loc, form, walkInnerCallback, ctx),
        .hash_set => rebuildSet(rt, env, loc, form, walkInnerCallback, ctx),
        .array_map => rebuildArrayMap(rt, env, loc, form, walkInnerCallback, ctx),
        .hash_map => rebuildHashMap(rt, env, loc, form, walkInnerCallback, ctx),
        else => form, // scalar / other Tag — walk leaves it alone
    };
}

/// `(clojure.walk/walk inner outer form)` — one-level: apply
/// `inner` to each immediate child, rebuild the same collection
/// type, then apply `outer` to the result. Scalars receive only
/// `outer`.
pub fn walkFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("walk", args, 3, loc);
    const rebuilt = try walkRebuild(rt, env, args[0], args[2], loc);
    return callOne(rt, env, args[1], rebuilt, loc);
}

// --- prewalk (pre-order: apply f first, then recurse) ---

const PrewalkCtx = struct { f: Value };

fn prewalkChildCallback(rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value {
    return prewalkRec(rt, env, ctx.f, child, loc);
}

fn prewalkRec(rt: *Runtime, env: *Env, f: Value, form: Value, loc: SourceLocation) anyerror!Value {
    const transformed = try callOne(rt, env, f, form, loc);
    const ctx = PrewalkCtx{ .f = f };
    return switch (transformed.tag()) {
        .list, .cons => rebuildList(rt, env, loc, transformed, prewalkChildCallback, ctx),
        .vector => rebuildVector(rt, env, loc, transformed, prewalkChildCallback, ctx),
        .hash_set => rebuildSet(rt, env, loc, transformed, prewalkChildCallback, ctx),
        .array_map => rebuildArrayMap(rt, env, loc, transformed, prewalkChildCallback, ctx),
        .hash_map => rebuildHashMap(rt, env, loc, transformed, prewalkChildCallback, ctx),
        else => transformed,
    };
}

pub fn prewalkFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("prewalk", args, 2, loc);
    return prewalkRec(rt, env, args[0], args[1], loc);
}

// --- postwalk (post-order: recurse first, then apply f) ---

const PostwalkCtx = struct { f: Value };

fn postwalkChildCallback(rt: *Runtime, env: *Env, ctx: anytype, child: Value, loc: SourceLocation) anyerror!Value {
    return postwalkRec(rt, env, ctx.f, child, loc);
}

fn postwalkRec(rt: *Runtime, env: *Env, f: Value, form: Value, loc: SourceLocation) anyerror!Value {
    const ctx = PostwalkCtx{ .f = f };
    const rebuilt = switch (form.tag()) {
        .list, .cons => try rebuildList(rt, env, loc, form, postwalkChildCallback, ctx),
        .vector => try rebuildVector(rt, env, loc, form, postwalkChildCallback, ctx),
        .hash_set => try rebuildSet(rt, env, loc, form, postwalkChildCallback, ctx),
        .array_map => try rebuildArrayMap(rt, env, loc, form, postwalkChildCallback, ctx),
        .hash_map => try rebuildHashMap(rt, env, loc, form, postwalkChildCallback, ctx),
        else => form,
    };
    return callOne(rt, env, f, rebuilt, loc);
}

pub fn postwalkFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("postwalk", args, 2, loc);
    return postwalkRec(rt, env, args[0], args[1], loc);
}

// --- registration ---

const std = @import("std");

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

/// `prewalk` + `postwalk` are Pattern A `.clj` defns over `walk` in
/// `src/lang/clj/clojure/walk.clj`; only the `walk` leaf is registered
/// here (B2 placement per v5 §9.1). The standalone `prewalkFn` /
/// `postwalkFn` impls above are now unreferenced (the `.clj` defns
/// recurse via `walk`) and are dead-code-removal candidates.
const ENTRIES = [_]Entry{
    .{ .name = "walk", .f = &walkFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.walk");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
