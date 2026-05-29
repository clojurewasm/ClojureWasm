// SPDX-License-Identifier: EPL-2.0
//! PersistentHashMap — Clojure-shape ArrayMap (≤ 8 entries, linear
//! scan) + HAMT (shift=5 = 32-way, CHAMP-style bitmap-indexed) per
//! ROADMAP §9.7 row 5.5.
//!
//! ## Layout
//!
//! Two Tag-discriminated representations:
//!
//!   - `.array_map` (A5): `ArrayMap { count, entries: [16]Value }`
//!     holds ≤ 8 key/value pairs as `[k0, v0, k1, v1, ...]`. Linear
//!     scan on get / contains? — O(n) but n ≤ 8 so cache-line
//!     friendly. assoc promotes to `.hash_map` when count > 8.
//!   - `.hash_map` (A6): `PersistentHashMap { count, root: ?*HamtMapNode }`
//!     wraps a CHAMP-style HAMT (each node = 32-bit bitmap + slots
//!     array). Day-1 layout uses a single `[64]Value` slots region
//!     (front-loaded KV pairs + back-loaded child pointers, gated by
//!     two bitmaps) per the 5.5 survey recommendation
//!     (`private/notes/phase5-5.5-survey.md`).
//!
//! ## What lands when
//!
//! - **5.5.a** (this commit): ArrayMap + HamtMapNode struct shapes;
//!   `count(v)` + `get(v, k)` for ArrayMap; `get` on `.hash_map`
//!   raises `error.HashMapNotImplemented` until 5.5.b.
//! - **5.5.b**: assoc — ArrayMap path + threshold promotion +
//!   HamtMapNode path with bitmap-indexed slots.
//! - **5.5.c**: dissoc — ArrayMap shrink + HamtMapNode demote to
//!   ArrayMap when count drops back ≤ 8.
//! - **5.5.d**: contains? / keys / vals / seq + reader-literal hook.
//!
//! Per-tag trace fns for `.array_map` / `.hash_map` /
//! `.hamt_map_node` / `.hash_collision_map_node` land at 5.5.b
//! alongside the first rt.gc.alloc — at 5.5.a EMPTY is a comptime
//! const singleton, no GC trace needed.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const HeapTag = value_mod.HeapTag;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const list_mod = @import("list.zig");
const vector_mod = @import("vector.zig");
const equal = @import("../equal.zig");

/// ArrayMap threshold: at most 8 K/V pairs before promotion to
/// HamtMap. Per ROADMAP row 5.5 wording + survey recommendation.
pub const ARRAY_MAP_THRESHOLD: u8 = 8;

/// ArrayMap — linear-scan map for ≤ 8 entries. Entries are stored as
/// `[k0, v0, k1, v1, ...]` in `entries[0..2*count]`.
pub const ArrayMap = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    entries: [2 * ARRAY_MAP_THRESHOLD]Value = @splat(Value.nil_val),

    comptime {
        std.debug.assert(@alignOf(ArrayMap) >= 8);
        std.debug.assert(@offsetOf(ArrayMap, "header") == 0);
    }
};

/// HamtMapNode — CHAMP-style HAMT bitmap-indexed node. `data_map`
/// marks slots holding K/V pairs; `node_map` marks slots holding
/// child node pointers. The slots region holds K/V pairs in slot
/// pairs (k at 2*i, v at 2*i+1) at the front; child pointers at the
/// back. The two bitmaps tell whether a hash-bucket has data or a
/// child sub-node.
pub const HamtMapNode = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    data_map: u32 = 0,
    node_map: u32 = 0,
    slots: [64]Value = @splat(Value.nil_val),

    comptime {
        std.debug.assert(@alignOf(HamtMapNode) >= 8);
        std.debug.assert(@offsetOf(HamtMapNode, "header") == 0);
    }
};

/// PersistentHashMap — top-level wrapper for the HamtMap variant.
/// `.array_map` Tag values point directly at `ArrayMap`; once a
/// map promotes past ARRAY_MAP_THRESHOLD it becomes a
/// `PersistentHashMap` (`.hash_map` Tag) wrapping the root HamtMapNode.
pub const PersistentHashMap = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    root: ?*HamtMapNode = null,
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(PersistentHashMap) >= 8);
        std.debug.assert(@offsetOf(PersistentHashMap, "header") == 0);
    }
};

/// Empty ArrayMap singleton.
pub var EMPTY_ARRAY_MAP: ArrayMap align(8) = .{
    .header = HeapHeader.init(.array_map),
    .count = 0,
};

/// Empty map as a Value (returns an `.array_map`-tagged Value
/// pointing at the EMPTY_ARRAY_MAP singleton).
pub fn empty() Value {
    return Value.encodeHeapPtr(.array_map, &EMPTY_ARRAY_MAP);
}

/// O(1) element count. Per Clojure semantics, `(count nil) = 0`.
pub fn count(v: Value) u32 {
    return switch (v.tag()) {
        .array_map => v.decodePtr(*const ArrayMap).count,
        .hash_map => v.decodePtr(*const PersistentHashMap).count,
        .nil => 0,
        else => 0,
    };
}

/// Key equality for the linear-scan ArrayMap path. Delegates to
/// `equal.keyEqValue` (D-151): identity fast path for immediates +
/// interned keyword·symbol, plus byte-equality for non-interned String
/// keys (the D-151 fix — `(get {"x" 5} "x")`). Collection / ratio /
/// big_int keys stay identity-compared (rare residual; the recursive
/// `=` over them needs `rt`, which the ~68 map call sites lack).
fn keyEq(a: Value, b: Value) bool {
    return equal.keyEqValue(a, b);
}

/// `(assoc m k v)` — returns a new map with `k → v` per Clojure
/// semantics. 5.5.b body handles the ArrayMap path:
///   - key found → copy with that slot's value replaced
///   - key absent, count < 8 → copy with append
///   - key absent, count == 8 → promote to HamtMap (5.5.b.2)
///
/// HamtMap path raises `error.HashMapNotImplemented` at 5.5.b
/// until 5.5.b.2 lands the bitmap-indexed body.
pub fn assoc(rt: *Runtime, v: Value, k: Value, val: Value) !Value {
    return switch (v.tag()) {
        .array_map => try assocArrayMap(rt, v.decodePtr(*const ArrayMap), k, val),
        .hash_map => error.HashMapNotImplemented,
        .nil => try assocArrayMap(rt, &EMPTY_ARRAY_MAP, k, val),
        else => error.AssocOnNonMap,
    };
}

fn assocArrayMap(rt: *Runtime, am: *const ArrayMap, k: Value, val: Value) !Value {
    // Search for existing key.
    var found_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        if (keyEq(am.entries[2 * i], k)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx) |idx| {
        // Replace value at idx — copy the map with the one slot updated.
        const new_am = try rt.gc.alloc(ArrayMap);
        new_am.* = .{ .header = HeapHeader.init(.array_map), .count = am.count, .entries = am.entries };
        new_am.entries[2 * idx + 1] = val;
        return Value.encodeHeapPtr(.array_map, new_am);
    }

    // Append — promote to HamtMap if count would exceed threshold.
    if (am.count >= ARRAY_MAP_THRESHOLD) {
        return error.HashMapPromotionNotImplemented; // 5.5.b.2 lands the promote path
    }

    const new_am = try rt.gc.alloc(ArrayMap);
    new_am.* = .{ .header = HeapHeader.init(.array_map), .count = am.count + 1, .entries = am.entries };
    new_am.entries[2 * am.count] = k;
    new_am.entries[2 * am.count + 1] = val;
    return Value.encodeHeapPtr(.array_map, new_am);
}

/// `(dissoc m k)` — returns a new map without `k`. Returns the
/// original map (no copy) when the key is absent. ArrayMap path
/// linear-scans + copy-with-hole-removed; HamtMap path raises
/// `error.HashMapNotImplemented` until 5.5.b.2 lands the body.
pub fn dissoc(rt: *Runtime, v: Value, k: Value) !Value {
    return switch (v.tag()) {
        .array_map => try dissocArrayMap(rt, v.decodePtr(*const ArrayMap), v, k),
        .hash_map => error.HashMapNotImplemented,
        .nil => Value.nil_val,
        else => error.DissocOnNonMap,
    };
}

fn dissocArrayMap(rt: *Runtime, am: *const ArrayMap, original: Value, k: Value) !Value {
    var found_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        if (keyEq(am.entries[2 * i], k)) {
            found_idx = i;
            break;
        }
    }
    if (found_idx == null) return original;
    if (am.count == 1) return empty(); // collapses to empty singleton

    // Copy + shift entries after the removed slot down by one K/V pair.
    const new_am = try rt.gc.alloc(ArrayMap);
    new_am.* = .{
        .header = HeapHeader.init(.array_map),
        .count = am.count - 1,
        .entries = @splat(Value.nil_val),
    };
    var write: u32 = 0;
    var read: u32 = 0;
    while (read < am.count) : (read += 1) {
        if (read == found_idx.?) continue;
        new_am.entries[2 * write] = am.entries[2 * read];
        new_am.entries[2 * write + 1] = am.entries[2 * read + 1];
        write += 1;
    }
    return Value.encodeHeapPtr(.array_map, new_am);
}

/// Per-tag trace fns (called by mark phase to walk outgoing GC-
/// managed pointers per ADR-0028 §5).
pub fn traceArrayMap(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const am: *ArrayMap = @ptrCast(@alignCast(header));
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        if (am.entries[2 * i].heapHeader()) |h| mark_sweep.mark(gc, h);
        if (am.entries[2 * i + 1].heapHeader()) |h| mark_sweep.mark(gc, h);
    }
}

pub fn tracePersistentHashMap(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const m: *PersistentHashMap = @ptrCast(@alignCast(header));
    if (m.root) |r| mark_sweep.mark(gc, @ptrCast(r));
    if (m.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn traceHamtMapNode(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const node: *HamtMapNode = @ptrCast(@alignCast(header));
    // CHAMP layout: 5.5.b.2 wires the data_map / node_map walk. For
    // 5.5.a/b every slot is conservatively walked — nil + immediate
    // Values filter out via Value.heapHeader.
    for (node.slots) |slot| {
        if (slot.heapHeader()) |h| mark_sweep.mark(gc, h);
    }
}

/// Register all four map-related trace fns into
/// `tag_ops.tag_trace_table`. Idempotent at same fn pointers.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.array_map, &traceArrayMap);
    tag_ops.registerTrace(.hash_map, &tracePersistentHashMap);
    tag_ops.registerTrace(.hamt_map_node, &traceHamtMapNode);
    tag_ops.registerTrace(.hash_collision_map_node, &traceHamtMapNode); // same slot-walk; 5.5.c may specialise
}

/// `(contains? m k)` — returns true when the key exists, false
/// otherwise. Distinct from `get` only for distinguishing
/// "key absent" vs "key maps to nil" (which `get` cannot do).
pub fn contains(v: Value, k: Value) !bool {
    return switch (v.tag()) {
        .array_map => blk: {
            const am = v.decodePtr(*const ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                if (keyEq(am.entries[2 * i], k)) break :blk true;
            }
            break :blk false;
        },
        .hash_map => error.HashMapNotImplemented,
        .nil => false,
        else => false,
    };
}

/// `(keys m)` — returns a list of keys in iteration order (empty
/// list when `m` is empty per Clojure; returns nil here for empty
/// to match `(seq m)` semantics).
pub fn keys(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .array_map => try keysArrayMap(rt, v.decodePtr(*const ArrayMap)),
        .hash_map => error.HashMapNotImplemented,
        .nil => Value.nil_val,
        else => error.KeysOnNonMap,
    };
}

fn keysArrayMap(rt: *Runtime, am: *const ArrayMap) !Value {
    if (am.count == 0) return Value.nil_val;
    // Build the list backwards (consHeap prepends) so the resulting
    // list iterates in insertion order.
    var result: Value = Value.nil_val;
    var i: i32 = @intCast(am.count);
    while (i > 0) {
        i -= 1;
        result = try list_mod.consHeap(rt, am.entries[@intCast(2 * i)], result);
    }
    return result;
}

/// `(vals m)` — returns a list of values in iteration order
/// (nil for empty, matching `(seq m)`).
pub fn vals(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .array_map => try valsArrayMap(rt, v.decodePtr(*const ArrayMap)),
        .hash_map => error.HashMapNotImplemented,
        .nil => Value.nil_val,
        else => error.ValsOnNonMap,
    };
}

fn valsArrayMap(rt: *Runtime, am: *const ArrayMap) !Value {
    if (am.count == 0) return Value.nil_val;
    var result: Value = Value.nil_val;
    var i: i32 = @intCast(am.count);
    while (i > 0) {
        i -= 1;
        result = try list_mod.consHeap(rt, am.entries[@intCast(2 * i + 1)], result);
    }
    return result;
}

/// `(seq m)` — returns a list of 2-element vector pairs `[k v]`
/// (or nil for empty per Clojure). 5.5.d uses 2-element
/// PersistentVector as the entry representation; future ADR may
/// promote to a dedicated `map_entry` Tag (A15 is reserved per
/// F-004) once the `MapEntry.key` / `MapEntry.val` accessor needs
/// the distinction.
pub fn seq(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .array_map => try seqArrayMap(rt, v.decodePtr(*const ArrayMap)),
        .hash_map => error.HashMapNotImplemented,
        .nil => Value.nil_val,
        else => error.SeqOnNonMap,
    };
}

fn seqArrayMap(rt: *Runtime, am: *const ArrayMap) !Value {
    if (am.count == 0) return Value.nil_val;
    var result: Value = Value.nil_val;
    var i: i32 = @intCast(am.count);
    while (i > 0) {
        i -= 1;
        var pair = vector_mod.empty();
        pair = try vector_mod.conj(rt, pair, am.entries[@intCast(2 * i)]);
        pair = try vector_mod.conj(rt, pair, am.entries[@intCast(2 * i + 1)]);
        result = try list_mod.consHeap(rt, pair, result);
    }
    return result;
}

/// `(get m k)` — returns `nil` when the key is absent (matches
/// Clojure 2-arg `get`; the 3-arg `(get m k not-found)` form lands
/// at 5.5.d via the `contains?` path).
pub fn get(v: Value, k: Value) !Value {
    return switch (v.tag()) {
        .array_map => blk: {
            const am = v.decodePtr(*const ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                if (keyEq(am.entries[2 * i], k)) break :blk am.entries[2 * i + 1];
            }
            break :blk Value.nil_val;
        },
        .hash_map => error.HashMapNotImplemented, // 5.5.b body lands
        .nil => Value.nil_val,
        else => Value.nil_val,
    };
}

// --- tests ---

const testing = std.testing;

test "EMPTY ArrayMap: count = 0; get returns nil" {
    const v = empty();
    try testing.expect(v.tag() == .array_map);
    try testing.expectEqual(@as(u32, 0), count(v));
    try testing.expectEqual(Value.nil_val, try get(v, Value.initInteger(42)));
}

test "count on nil = 0; count on non-map = 0" {
    try testing.expectEqual(@as(u32, 0), count(Value.nil_val));
    try testing.expectEqual(@as(u32, 0), count(Value.initInteger(42)));
}

test "ArrayMap layout: header at offset 0, 16 slots inlined" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(ArrayMap, "header"));
    const am: ArrayMap = .{ .header = HeapHeader.init(.array_map) };
    try testing.expectEqual(@as(usize, 16), am.entries.len);
    try testing.expect(@alignOf(ArrayMap) >= 8);
}

test "HamtMapNode layout: header at offset 0, 64 slots + 2 bitmaps" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(HamtMapNode, "header"));
    const node: HamtMapNode = .{ .header = HeapHeader.init(.hamt_map_node) };
    try testing.expectEqual(@as(usize, 64), node.slots.len);
    try testing.expectEqual(@as(u32, 0), node.data_map);
    try testing.expectEqual(@as(u32, 0), node.node_map);
    try testing.expect(@alignOf(HamtMapNode) >= 8);
}

test "PersistentHashMap layout: header at offset 0" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(PersistentHashMap, "header"));
    try testing.expect(@alignOf(PersistentHashMap) >= 8);
}

test "ArrayMap.get: linear scan on hand-built 3-entry map" {
    var am: ArrayMap align(8) = .{
        .header = HeapHeader.init(.array_map),
        .count = 3,
        .entries = blk: {
            var e: [16]Value = @splat(Value.nil_val);
            e[0] = Value.initInteger(1);
            e[1] = Value.initInteger(100);
            e[2] = Value.initInteger(2);
            e[3] = Value.initInteger(200);
            e[4] = Value.initInteger(3);
            e[5] = Value.initInteger(300);
            break :blk e;
        },
    };
    const v = Value.encodeHeapPtr(.array_map, &am);

    try testing.expectEqual(@as(u32, 3), count(v));
    try testing.expectEqual(@as(i48, 100), (try get(v, Value.initInteger(1))).asInteger());
    try testing.expectEqual(@as(i48, 200), (try get(v, Value.initInteger(2))).asInteger());
    try testing.expectEqual(@as(i48, 300), (try get(v, Value.initInteger(3))).asInteger());
    try testing.expectEqual(Value.nil_val, try get(v, Value.initInteger(999)));
}

const RuntimeFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() RuntimeFixture {
        var fix: RuntimeFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *RuntimeFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "assoc on empty: count = 1; get returns the value" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const m1 = try assoc(&fix.rt, empty(), Value.initInteger(1), Value.initInteger(100));
    try testing.expectEqual(@as(u32, 1), count(m1));
    try testing.expectEqual(@as(i48, 100), (try get(m1, Value.initInteger(1))).asInteger());
}

test "assoc replaces existing key: count unchanged, value updated" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(2), Value.initInteger(200));
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.initInteger(999));

    try testing.expectEqual(@as(u32, 2), count(m));
    try testing.expectEqual(@as(i48, 999), (try get(m, Value.initInteger(1))).asInteger());
    try testing.expectEqual(@as(i48, 200), (try get(m, Value.initInteger(2))).asInteger());
}

test "assoc appends up to ARRAY_MAP_THRESHOLD = 8 entries" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    for (0..ARRAY_MAP_THRESHOLD) |i| {
        m = try assoc(&fix.rt, m, Value.initInteger(@intCast(i)), Value.initInteger(@intCast(i + 1000)));
    }
    try testing.expectEqual(@as(u32, ARRAY_MAP_THRESHOLD), count(m));
    for (0..ARRAY_MAP_THRESHOLD) |i| {
        try testing.expectEqual(@as(i48, @intCast(i + 1000)), (try get(m, Value.initInteger(@intCast(i)))).asInteger());
    }
}

test "assoc at threshold: 9th distinct key raises HashMapPromotionNotImplemented (5.5.b.2 lands the promote)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    for (0..ARRAY_MAP_THRESHOLD) |i| {
        m = try assoc(&fix.rt, m, Value.initInteger(@intCast(i)), Value.initInteger(@intCast(i)));
    }
    try testing.expectError(
        error.HashMapPromotionNotImplemented,
        assoc(&fix.rt, m, Value.initInteger(99), Value.initInteger(99)),
    );
}

test "assoc on nil: starts from EMPTY (treats nil as empty map per Clojure)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const m = try assoc(&fix.rt, Value.nil_val, Value.initInteger(1), Value.initInteger(100));
    try testing.expectEqual(@as(u32, 1), count(m));
}

test "dissoc removes key: count decremented, value gone" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(2), Value.initInteger(200));
    m = try assoc(&fix.rt, m, Value.initInteger(3), Value.initInteger(300));

    const m2 = try dissoc(&fix.rt, m, Value.initInteger(2));
    try testing.expectEqual(@as(u32, 2), count(m2));
    try testing.expectEqual(@as(i48, 100), (try get(m2, Value.initInteger(1))).asInteger());
    try testing.expectEqual(Value.nil_val, try get(m2, Value.initInteger(2)));
    try testing.expectEqual(@as(i48, 300), (try get(m2, Value.initInteger(3))).asInteger());
    // Original unchanged
    try testing.expectEqual(@as(u32, 3), count(m));
}

test "dissoc absent key: returns original map (no copy)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const m = try assoc(&fix.rt, empty(), Value.initInteger(1), Value.initInteger(100));
    const m2 = try dissoc(&fix.rt, m, Value.initInteger(99));
    try testing.expectEqual(@intFromEnum(m), @intFromEnum(m2)); // identity
}

test "dissoc last entry collapses to empty singleton" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const m1 = try assoc(&fix.rt, empty(), Value.initInteger(1), Value.initInteger(100));
    const m0 = try dissoc(&fix.rt, m1, Value.initInteger(1));
    try testing.expectEqual(@as(u32, 0), count(m0));
    try testing.expectEqual(@intFromEnum(empty()), @intFromEnum(m0)); // back to EMPTY singleton
}

test "dissoc on nil: returns nil" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const r = try dissoc(&fix.rt, Value.nil_val, Value.initInteger(1));
    try testing.expect(r.isNil());
}

test "contains? distinguishes key-present-with-nil-value from key-absent" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.nil_val);

    try testing.expect(try contains(m, Value.initInteger(1)));
    try testing.expect(!try contains(m, Value.initInteger(99)));
    // get returns nil for both (the disambiguation IS contains?'s job)
    try testing.expectEqual(Value.nil_val, try get(m, Value.initInteger(1)));
    try testing.expectEqual(Value.nil_val, try get(m, Value.initInteger(99)));
}

test "keys returns a list of keys in insertion order" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(10), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(20), Value.initInteger(200));
    m = try assoc(&fix.rt, m, Value.initInteger(30), Value.initInteger(300));

    const ks = try keys(&fix.rt, m);
    try testing.expectEqual(@as(u32, 3), list_mod.countOf(ks));
    try testing.expectEqual(@as(i48, 10), list_mod.first(ks).asInteger());
    try testing.expectEqual(@as(i48, 20), list_mod.first(list_mod.rest(ks)).asInteger());
    try testing.expectEqual(@as(i48, 30), list_mod.first(list_mod.rest(list_mod.rest(ks))).asInteger());
}

test "vals returns a list of values in insertion order" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(10), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(20), Value.initInteger(200));

    const vs = try vals(&fix.rt, m);
    try testing.expectEqual(@as(u32, 2), list_mod.countOf(vs));
    try testing.expectEqual(@as(i48, 100), list_mod.first(vs).asInteger());
    try testing.expectEqual(@as(i48, 200), list_mod.first(list_mod.rest(vs)).asInteger());
}

test "seq returns a list of [k v] vector pairs (nil for empty)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    try testing.expect((try seq(&fix.rt, empty())).isNil());

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(2), Value.initInteger(200));

    const s = try seq(&fix.rt, m);
    try testing.expectEqual(@as(u32, 2), list_mod.countOf(s));
    const first_pair = list_mod.first(s);
    try testing.expectEqual(@as(u32, 2), vector_mod.count(first_pair));
    try testing.expectEqual(@as(i48, 1), vector_mod.nth(first_pair, 0).asInteger());
    try testing.expectEqual(@as(i48, 100), vector_mod.nth(first_pair, 1).asInteger());
}

test "get on .hash_map raises HashMapNotImplemented at 5.5.a" {
    // Build a stub PersistentHashMap (no root) to verify the dispatch
    // routes to the 5.5.b stub. Once 5.5.b lands, this test updates.
    var phm: PersistentHashMap align(8) = .{
        .header = HeapHeader.init(.hash_map),
        .count = 0,
    };
    const v = Value.encodeHeapPtr(.hash_map, &phm);
    try testing.expectError(error.HashMapNotImplemented, get(v, Value.initInteger(1)));
}
