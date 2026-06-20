// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.TreeMap` — a mutable SORTED key→value map (D-431
//! interop completeness; the sorted sibling of `HashMap`, last of the java.util
//! container family). The persistent `(sorted-map …)` is the idiomatic cljw
//! analogue, and backs this surface.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Stored as a `.host_instance` (ADR-0106) whose state[0] holds a cljw PERSISTENT
//! SORTED MAP Value (a red-black tree; `runtime/collection/sorted.zig`). `.put`/
//! `.remove` assoc/dissoc and write the new root back into state[0] (mutable-by-
//! rebind over a persistent value); the descriptor's `host_trace` marks the one map
//! Value each GC (no off-heap buffer → no `host_finalise`). The mutators need no
//! extra rooting (the receiver map lives in the rooted instance); only the `{…}`-
//! seed rebuild does (an EvalFrame + a forEachEntry assoc — NOT a seq walk).
//!
//! Iteration is by SORTED key, matching clj's `TreeMap` exactly — so the entry seq
//! / keySet / values order is real parity, not an AD-001 divergence. `(seq tm)` /
//! `(count tm)` / `(into {} tm)` work via the Seqable / IPersistentCollection
//! MethodEntries; seq yields cljw MapEntry pairs (AD-032, like HashMap).
//!
//! Methods: `<init>` (empty / int-capacity-hint / cljw map / sorted-map / TreeMap)
//! + put / get / containsKey / remove / getOrDefault / putIfAbsent / size /
//! isEmpty / clear / keySet / values / firstKey / lastKey. `keySet`/`values` are
//! cljw seqs (no-JVM view, AD-032). The wider NavigableMap surface (floorKey/
//! ceilingKey/headMap/tailMap/subMap/descendingMap) + `.containsValue` are a
//! deliberate follow-up (D-431).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const sorted = @import("../../collection/sorted.zig");
const map_mod = @import("../../collection/map.zig");
const list_mod = @import("../../collection/list.zig");
const root_set = @import("../../gc/root_set.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

var tm_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn mapOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}
fn setMap(recv: Value, m: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(m));
}
fn isTreeMap(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == tm_descriptor;
}
fn allocWith(rt: *Runtime, m: Value) !Value {
    const td = tm_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(m), 0, 0, 0 });
}

const SeedCtx = struct { rt: *Runtime, env: *Env, acc: *Value, loc: SourceLocation };
fn seedAssoc(ctx: SeedCtx, k: Value, v: Value) anyerror!void {
    ctx.acc.* = try sorted.assoc(ctx.rt, ctx.env, ctx.acc.*, k, v, ctx.loc);
}

/// `(java.util.TreeMap.)` — empty. `(TreeMap. n)` int capacity hint (→ empty).
/// `(TreeMap. m)` — seed from a cljw map (rebuilt into a sorted map so iteration is
/// by key), a sorted-map / TreeMap (share the RB-tree — immutable, so a later put
/// forks its own version).
pub fn initTreeMap(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.TreeMap.", .expected = 1 });
    if (args.len == 0) return allocWith(rt, try sorted.emptyMap(rt));
    switch (args[0].tag()) {
        .integer => return allocWith(rt, try sorted.emptyMap(rt)), // capacity hint
        .sorted_map => return allocWith(rt, args[0]),
        .host_instance => {
            if (!isTreeMap(args[0]))
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.TreeMap.", .expected = "int capacity, map, sorted-map, or TreeMap", .actual = @tagName(args[0].tag()) });
            return allocWith(rt, mapOf(args[0]));
        },
        .array_map, .hash_map => {
            // Rebuild into a sorted map. GC-ROOT: §C — the accumulator lives only
            // on this frame across the assoc allocs; publish it on an EvalFrame so a
            // collect mid-rebuild cannot sweep it [ref: .dev/gc_rooting.md §C].
            var roots: [1]Value = .{try sorted.emptyMap(rt)};
            var sp: u16 = 1;
            var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
            root_set.eval_frame_head = &frame;
            defer root_set.eval_frame_head = frame.parent;
            try map_mod.forEachEntry(args[0], SeedCtx{ .rt = rt, .env = env, .acc = &roots[0], .loc = loc }, seedAssoc);
            return allocWith(rt, roots[0]);
        },
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.TreeMap.", .expected = "int capacity, map, sorted-map, or TreeMap", .actual = @tagName(args[0].tag()) }),
    }
}

/// `(.put tm k v)` — associate `k`→`v`, returning the PREVIOUS value (nil if
/// absent), JVM-faithful. No allocation between the get and the state rebind.
fn put(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".put", args, 3, loc);
    const m = mapOf(args[0]);
    const prev: Value = if (try sorted.contains(rt, env, m, args[1], loc)) try sorted.get(rt, env, m, args[1], loc) else .nil_val;
    setMap(args[0], try sorted.assoc(rt, env, m, args[1], args[2], loc));
    return prev;
}

fn get(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".get", args, 2, loc);
    return sorted.get(rt, env, mapOf(args[0]), args[1], loc);
}

/// `ILookup -lookup` — `(get tm k)` / `(get tm k default)` / `(:k tm)` (clj allows
/// lookup on a java.util.Map). Uses contains so a present nil value returns nil.
fn lookupImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const m = mapOf(args[0]);
    if (try sorted.contains(rt, env, m, args[1], loc)) return sorted.get(rt, env, m, args[1], loc);
    return if (args.len == 3) args[2] else .nil_val;
}

fn containsKey(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".containsKey", args, 2, loc);
    return Value.initBoolean(try sorted.contains(rt, env, mapOf(args[0]), args[1], loc));
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    return Value.initInteger(@intCast(sorted.count(mapOf(args[0]))));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(sorted.count(mapOf(args[0])) == 0);
}

/// `(.remove tm k)` — remove `k`, returning its previous value (nil if absent).
fn remove(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".remove", args, 2, loc);
    const m = mapOf(args[0]);
    const old: Value = if (try sorted.contains(rt, env, m, args[1], loc)) try sorted.get(rt, env, m, args[1], loc) else .nil_val;
    setMap(args[0], try sorted.dissoc(rt, env, m, args[1], loc));
    return old;
}

/// `(.getOrDefault tm k default)` — value for `k`, or `default` if absent (uses
/// containsKey, so a present nil value returns nil, not the default; JVM-faithful).
fn getOrDefault(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".getOrDefault", args, 3, loc);
    const m = mapOf(args[0]);
    if (try sorted.contains(rt, env, m, args[1], loc)) return sorted.get(rt, env, m, args[1], loc);
    return args[2];
}

/// `(.putIfAbsent tm k v)` — associate only if `k` is absent; returns the existing
/// value (no change) or nil (JVM `Map.putIfAbsent`).
fn putIfAbsent(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".putIfAbsent", args, 3, loc);
    const m = mapOf(args[0]);
    if (try sorted.contains(rt, env, m, args[1], loc)) return sorted.get(rt, env, m, args[1], loc);
    setMap(args[0], try sorted.assoc(rt, env, m, args[1], args[2], loc));
    return Value.nil_val;
}

/// `(.clear tm)` — drop all entries (rebind to empty), return nil.
fn clear(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".clear", args, 1, loc);
    setMap(args[0], try sorted.emptyMap(rt));
    return Value.nil_val;
}

/// `(.keySet tm)` — the keys in SORTED order (cljw seq, AD-032). Empty → nil.
fn keySet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".keySet", args, 1, loc);
    const m = mapOf(args[0]);
    if (sorted.count(m) == 0) return Value.nil_val;
    return sorted.keys(rt, m);
}

/// `(.values tm)` — the values, ordered by key (cljw seq, AD-032). Empty → nil.
fn values(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".values", args, 1, loc);
    const m = mapOf(args[0]);
    if (sorted.count(m) == 0) return Value.nil_val;
    return sorted.vals(rt, m);
}

/// `(.firstKey tm)` — the least key (JVM `SortedMap.firstKey`). Empty raises
/// (JVM NoSuchElementException; cljw's Kind differs, AD-007).
fn firstKey(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".firstKey", args, 1, loc);
    const m = mapOf(args[0]);
    if (sorted.count(m) == 0) return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.TreeMap/firstKey" });
    return list_mod.first(try sorted.keys(rt, m));
}

/// `(.lastKey tm)` — the greatest key. The keys seq is realized + sorted, so the
/// walk to its tail allocates nothing (no GC fabrication window).
fn lastKey(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".lastKey", args, 1, loc);
    const m = mapOf(args[0]);
    if (sorted.count(m) == 0) return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.TreeMap/lastKey" });
    var cur = try sorted.keys(rt, m);
    while (true) {
        const nxt = list_mod.rest(cur);
        if (nxt.isNil() or list_mod.isEmpty(nxt)) return list_mod.first(cur);
        cur = nxt;
    }
}

/// `(Seqable -seq)` — the entry seq in SORTED key order (cljw `TreeMap` parity).
fn seqImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    const m = mapOf(args[0]);
    if (sorted.count(m) == 0) return Value.nil_val;
    return sorted.seq(rt, m);
}

/// `(IPersistentCollection -count)` — entry count.
fn countImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(sorted.count(mapOf(args[0]))));
}

/// GC-trace: mark the single backing sorted-map Value held in state[0].
/// GC-ROOT: §H — a moving GC must RELOCATE state[0] [ref: .dev/gc_rooting.md §H].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const m: Value = @enumFromInt(state[0]);
    if (m.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct {
    name: []const u8,
    proto: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .proto = "", .f = &initTreeMap },
    .{ .name = "put", .proto = "", .f = &put },
    .{ .name = "get", .proto = "", .f = &get },
    .{ .name = "containsKey", .proto = "", .f = &containsKey },
    .{ .name = "size", .proto = "", .f = &size },
    .{ .name = "isEmpty", .proto = "", .f = &isEmpty },
    .{ .name = "remove", .proto = "", .f = &remove },
    .{ .name = "getOrDefault", .proto = "", .f = &getOrDefault },
    .{ .name = "putIfAbsent", .proto = "", .f = &putIfAbsent },
    .{ .name = "clear", .proto = "", .f = &clear },
    .{ .name = "keySet", .proto = "", .f = &keySet },
    .{ .name = "values", .proto = "", .f = &values },
    .{ .name = "firstKey", .proto = "", .f = &firstKey },
    .{ .name = "lastKey", .proto = "", .f = &lastKey },
    .{ .name = "-seq", .proto = "Seqable", .f = &seqImpl },
    .{ .name = "-count", .proto = "IPersistentCollection", .f = &countImpl },
    // IPersistentMap -keys / -vals so `(keys tm)` / `(vals tm)` work like clj
    // (sorted, matching clj's keys/vals over a java.util.SortedMap). Reuse keySet/values.
    .{ .name = "-keys", .proto = "IPersistentMap", .f = &keySet },
    .{ .name = "-vals", .proto = "IPersistentMap", .f = &values },
    // ILookup -lookup + Associative -contains-key? so `(get tm k)` / `(:k tm)` /
    // `(contains? tm k)` work like clj.
    .{ .name = "-lookup", .proto = "ILookup", .f = &lookupImpl },
    .{ .name = "-contains-key?", .proto = "Associative", .f = &containsKey },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    tm_descriptor = td;
    td.host_trace = &traceState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = m.proto,
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.TreeMap",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.TreeMap",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
