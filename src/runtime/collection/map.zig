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
//! ## Operations
//!
//! - `count` / `get` / `contains?` read both representations.
//! - `assoc` copies the ArrayMap path and promotes to a HAMT past the
//!   8-entry threshold; the HAMT path inserts bitmap-indexed slots.
//! - `dissoc` shrinks the ArrayMap (collapsing to the empty singleton
//!   at count 1) and deletes from the HAMT.
//! - `keys` / `vals` / `seq` walk either representation.
//!
//! Per-tag trace fns for `.array_map` / `.hash_map` /
//! `.hamt_map_node` / `.hash_collision_map_node` are registered via
//! `registerGcHooks`. EMPTY is a comptime const singleton that never
//! lives on the GC heap, so it needs no trace.

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
const map_entry_mod = @import("map_entry.zig");
const equal = @import("../equal.zig");
const hash = @import("../hash.zig");

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
    /// Metadata map (or nil). Same-type ops (assoc/dissoc) preserve it;
    /// `with-meta` sets it on a copy. D-075 / metadata cycle 2026-05-30.
    meta: Value = Value.nil_val,

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

/// Walk every `(key, value)` entry of an `.array_map` or `.hash_map`, calling
/// `cb(ctx, key, value)` per entry. The iteration order is the map's storage
/// order (array_map = insertion; hash_map = HAMT order) — the same order
/// `pr-str` / `seq` expose, so callers that mirror print/seq output stay
/// consistent. Pure (no `rt`/`env`, no allocation, no GC trigger), so it is
/// safe to call from a non-reentrant primitive walk. A non-map `v` is a
/// programming error (callers guard the tag). `.sorted_map` is NOT handled
/// here (different backing structure); callers needing it dispatch separately.
pub fn forEachEntry(
    v: Value,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value, Value) anyerror!void,
) anyerror!void {
    switch (v.tag()) {
        .array_map => {
            const am = v.decodePtr(*const ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                try cb(ctx, am.entries[2 * i], am.entries[2 * i + 1]);
            }
        },
        .hash_map => {
            const phm = v.decodePtr(*const PersistentHashMap);
            if (phm.root) |root| try hamtForEachEntry(root, ctx, cb);
        },
        else => return error.NotAMap,
    }
}

fn hamtForEachEntry(
    node: *const HamtMapNode,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value, Value) anyerror!void,
) anyerror!void {
    const data_count = @popCount(node.data_map);
    var i: u32 = 0;
    while (i < data_count) : (i += 1) {
        try cb(ctx, node.slots[2 * i], node.slots[2 * i + 1]);
    }
    const child_count = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < child_count) : (j += 1) {
        try hamtForEachEntry(node.slots[63 - j].decodePtr(*const HamtMapNode), ctx, cb);
    }
}

/// Key equality for every HAMT / ArrayMap key compare. Routes to
/// `equal.eqConsult` (ADR-0129): a custom-`equiv` deftype/reify key is
/// compared via its impl (reading the ambient `dispatch.current_env`), else
/// the rt-free `equal.keyEqValue` (identity for immediates + interned
/// keyword·symbol, byte-equality for non-interned String keys per D-151).
/// Unarmed (outside evaluation) ⇒ the rt-free path. The nested deftype inside
/// a collection KEY stays rt-free (shared with the `(hash x)` residual).
fn keyEq(a: Value, b: Value) !bool {
    return equal.eqConsult(a, b);
}

/// Bucketing hash for every HAMT key site. Routes to `equal.hashConsult`
/// (ADR-0129): a custom-`hasheq` deftype/reify key hashes via its impl, else
/// the rt-free `equal.valueHash`. MUST stay paired with `keyEq` so a deftype
/// key and its `=`-equal value land in the same bucket. The map's own
/// recursive content hash (`contentHash`/`entryHash`) stays on `valueHash`.
fn keyHash(k: Value) !u32 {
    return equal.hashConsult(k);
}

/// PERF: O-026 a key whose `keyEq` (eqConsult) is guaranteed PURE — no user
/// `=`/`hasheq` dispatch, no alloc, no eval. A `.typed_instance` (deftype/reify)
/// key may carry a custom `=`, so it is excluded; any tag not in this set falls
/// back to the assoc-fold. Lets `fromLiteralPairs` dedup without a GC-rooting
/// frame (a pure keyEq cannot trigger GC). [refs: O-026]
fn isSimpleKey(k: Value) bool {
    return switch (k.tag()) {
        .keyword, .symbol, .string, .integer, .char, .boolean, .nil => true,
        else => false,
    };
}

/// PERF: O-026 — true iff every key (even index) of `pairs` is a simple key.
pub fn allSimpleKeys(pairs: []const Value) bool {
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        if (!isSimpleKey(pairs[i])) return false;
    }
    return true;
}

/// PERF: O-026 build an ArrayMap from N k/v `pairs` in ONE alloc (the map-literal
/// fast path), instead of an N-deep `assoc` fold that copies the 16-slot ArrayMap
/// each step. CALLER GUARANTEES: `pairs.len` even, `pairs.len/2 ≤
/// ARRAY_MAP_THRESHOLD`, and `allSimpleKeys(pairs)` — so the dedup `keyEq` is pure
/// (no alloc/eval) and the single `gc.alloc` is the ONLY allocation. The fill
/// therefore cannot trigger GC, so the freshly-alloc'd `am` is safe WITHOUT a
/// rooting frame (last-key-wins, matching the assoc-fold). [refs: O-026, D-386]
pub fn fromLiteralPairs(rt: *Runtime, pairs: []const Value) !Value {
    // D-244 #4: single ArrayMap alloc, filled from the rooted operand stack —
    // no multi-alloc internal window, so no fabrication region needed (the
    // alloc-torture is the completeness guard if this ever grows a 2nd alloc).
    const am = try rt.gc.alloc(ArrayMap);
    am.* = .{ .header = HeapHeader.init(.array_map) };
    var w: u32 = 0;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const k = pairs[i];
        const val = pairs[i + 1];
        var found = false;
        var j: u32 = 0;
        while (j < w) : (j += 1) {
            if (try keyEq(am.entries[2 * j], k)) {
                am.entries[2 * j + 1] = val;
                found = true;
                break;
            }
        }
        if (!found) {
            am.entries[2 * w] = k;
            am.entries[2 * w + 1] = val;
            w += 1;
        }
    }
    am.count = w;
    return Value.encodeHeapPtr(.array_map, am);
}

/// `(assoc m k v)` — returns a new map with `k → v` per Clojure
/// semantics. ArrayMap path:
///   - key found → copy with that slot's value replaced
///   - key absent, count < 8 → copy with append
///   - key absent, count == 8 → promote to HamtMap
///
/// HamtMap path inserts into the bitmap-indexed HAMT (`assocHashMap`).
pub fn assoc(rt: *Runtime, v: Value, k: Value, val: Value) !Value {
    // D-244 #4: HAMT/promote paths hold fresh nodes unrooted across allocs
    // (ADR-0150 fabrication region). The array_map fast path is single-alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return switch (v.tag()) {
        .array_map => try assocArrayMap(rt, v.decodePtr(*const ArrayMap), k, val),
        .hash_map => try assocHashMap(rt, v.decodePtr(*const PersistentHashMap), k, val),
        .nil => try assocArrayMap(rt, &EMPTY_ARRAY_MAP, k, val),
        else => error.AssocOnNonMap,
    };
}

fn assocArrayMap(rt: *Runtime, am: *const ArrayMap, k: Value, val: Value) !Value {
    // Search for existing key.
    var found_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        if (try keyEq(am.entries[2 * i], k)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx) |idx| {
        // Replace value at idx — copy the map with the one slot updated.
        const new_am = try rt.gc.alloc(ArrayMap);
        new_am.* = .{ .header = HeapHeader.init(.array_map), .count = am.count, .entries = am.entries, .meta = am.meta };
        new_am.entries[2 * idx + 1] = val;
        return Value.encodeHeapPtr(.array_map, new_am);
    }

    // Append — promote to HamtMap if count would exceed threshold.
    if (am.count >= ARRAY_MAP_THRESHOLD) {
        return try promoteArrayMap(rt, am, k, val);
    }

    const new_am = try rt.gc.alloc(ArrayMap);
    new_am.* = .{ .header = HeapHeader.init(.array_map), .count = am.count + 1, .entries = am.entries, .meta = am.meta };
    new_am.entries[2 * am.count] = k;
    new_am.entries[2 * am.count + 1] = val;
    return Value.encodeHeapPtr(.array_map, new_am);
}

/// `(dissoc m k)` — returns a new map without `k`. Returns the
/// original map (no copy) when the key is absent. ArrayMap path
/// linear-scans + copy-with-hole-removed; HamtMap path deletes from
/// the HAMT (`dissocHashMap`).
pub fn dissoc(rt: *Runtime, v: Value, k: Value) !Value {
    // D-244 #4: HAMT delete holds fresh nodes unrooted across allocs
    // (ADR-0150 fabrication region).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return switch (v.tag()) {
        .array_map => try dissocArrayMap(rt, v.decodePtr(*const ArrayMap), v, k),
        .hash_map => try dissocHashMap(rt, v.decodePtr(*const PersistentHashMap), v, k),
        .nil => Value.nil_val,
        else => error.DissocOnNonMap,
    };
}

fn dissocArrayMap(rt: *Runtime, am: *const ArrayMap, original: Value, k: Value) !Value {
    var found_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        if (try keyEq(am.entries[2 * i], k)) {
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
        .meta = am.meta,
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
    if (am.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
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
    // CHAMP layout: every slot is walked — nil + immediate Values
    // filter out via Value.heapHeader, so no bitmap-guided walk is
    // needed.
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
    tag_ops.registerTrace(.hash_collision_map_node, &traceHamtMapNode); // same slot-walk
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
                if (try keyEq(am.entries[2 * i], k)) break :blk true;
            }
            break :blk false;
        },
        .hash_map => blk: {
            const phm = v.decodePtr(*const PersistentHashMap);
            const root = phm.root orelse break :blk false;
            break :blk try hamtContains(root, k, try keyHash(k), 0);
        },
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
        .hash_map => try keysHashMap(rt, v.decodePtr(*const PersistentHashMap)),
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
        .hash_map => try valsHashMap(rt, v.decodePtr(*const PersistentHashMap)),
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

/// `(seq m)` — returns a list of MapEntry pairs (or nil for empty per
/// Clojure). Entries are minted as the dedicated `.map_entry` Tag
/// (D-209 / ADR-0078), so `(map-entry? (first {…}))` is true while the
/// entry still behaves as `[k v]`.
pub fn seq(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .array_map => try seqArrayMap(rt, v.decodePtr(*const ArrayMap)),
        .hash_map => try seqHashMap(rt, v.decodePtr(*const PersistentHashMap)),
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
        // A distinct MapEntry (D-209 / ADR-0078), not a 2-vector, so
        // `(map-entry? (first {…}))`→true while it still behaves as `[k v]`.
        const pair = try map_entry_mod.make(rt, am.entries[@intCast(2 * i)], am.entries[@intCast(2 * i + 1)]);
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
                if (try keyEq(am.entries[2 * i], k)) break :blk am.entries[2 * i + 1];
            }
            break :blk Value.nil_val;
        },
        .hash_map => blk: {
            const phm = v.decodePtr(*const PersistentHashMap);
            const root = phm.root orelse break :blk Value.nil_val;
            break :blk try hamtGet(root, k, try keyHash(k), 0);
        },
        .nil => Value.nil_val,
        else => Value.nil_val,
    };
}

// --- Map-as-key content hash + equality (D-092) ----------------------
//
// rt-free so they can partner `equal.valueHash` / `equal.keyEqValue`
// (whose ~68 call sites lack a Runtime). A map's hash folds each entry's
// (keyHash, valHash) and combines entries by an order-independent sum, so
// two maps built by different insertion paths hash equal. The ratio /
// big_decimal element residual is shared with the vector-key path.

/// Per-entry hash contribution = the `[k v]` MapEntry's own hash (a 2-element
/// ordered/vector hash: `mixCollHash((1*31+hash k)*31+hash v, 2)`), so a map's
/// content hash folds the SAME per-entry value `(hash (first m))` / `(hash [k v])`
/// / `hash-unordered-coll` over the entries produce. This makes `(hash m)` ==
/// `(hash-unordered-coll m)` (clj parity, D-377 facet 1) and keeps
/// `(hash mapentry)` == `(hash [k v])`. Entries still combine by order-independent
/// `+%` sum in foldHash. Exposed (D-375) so the
/// `clojure.lang.APersistentMap/mapHash` surface reuses the identical fold.
pub inline fn entryHash(k: Value, v: Value) u32 {
    const h: u32 = (1 *% 31 +% equal.valueHash(k)) *% 31 +% equal.valueHash(v);
    return hash.mixCollHash(h, 2);
}

fn hamtFoldHash(node: *const HamtMapNode, acc: *u32, comptime keys_only: bool) void {
    const dc = @popCount(node.data_map);
    var i: u32 = 0;
    while (i < dc) : (i += 1) {
        acc.* +%= if (keys_only)
            equal.valueHash(node.slots[2 * i])
        else
            entryHash(node.slots[2 * i], node.slots[2 * i + 1]);
    }
    const nc = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < nc) : (j += 1)
        hamtFoldHash(node.slots[63 - j].decodePtr(*const HamtMapNode), acc, keys_only);
}

fn foldHash(v: Value, comptime keys_only: bool) u32 {
    var acc: u32 = 0;
    switch (v.tag()) {
        .array_map => {
            const am = v.decodePtr(*const ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1)
                acc +%= if (keys_only)
                    equal.valueHash(am.entries[2 * i])
                else
                    entryHash(am.entries[2 * i], am.entries[2 * i + 1]);
        },
        .hash_map => if (v.decodePtr(*const PersistentHashMap).root) |root|
            hamtFoldHash(root, &acc, keys_only),
        else => {},
    }
    return hash.mixCollHash(acc, count(v));
}

/// Content hash of a map (rt-free): order-independent over entries.
pub fn contentHash(v: Value) u32 {
    return foldHash(v, false);
}

/// Order-independent hash over a map's keys only — the set hash partner
/// (a set is a map with sentinel values, so folding values would mix the
/// sentinel in; sets fold element hashes directly).
pub fn keysetHash(v: Value) u32 {
    return foldHash(v, true);
}

fn entryMatches(k: Value, v: Value, b: Value, comptime check_val: bool) bool {
    if (!(contains(b, k) catch return false)) return false;
    if (!check_val) return true;
    return equal.keyEqValue(v, get(b, k) catch return false);
}

fn hamtSubset(node: *const HamtMapNode, b: Value, comptime check_val: bool) bool {
    const dc = @popCount(node.data_map);
    var i: u32 = 0;
    while (i < dc) : (i += 1)
        if (!entryMatches(node.slots[2 * i], node.slots[2 * i + 1], b, check_val)) return false;
    const nc = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < nc) : (j += 1)
        if (!hamtSubset(node.slots[63 - j].decodePtr(*const HamtMapNode), b, check_val)) return false;
    return true;
}

fn subsetOf(a: Value, b: Value, comptime check_val: bool) bool {
    switch (a.tag()) {
        .array_map => {
            const am = a.decodePtr(*const ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1)
                if (!entryMatches(am.entries[2 * i], am.entries[2 * i + 1], b, check_val)) return false;
            return true;
        },
        .hash_map => {
            const root = a.decodePtr(*const PersistentHashMap).root orelse return true;
            return hamtSubset(root, b, check_val);
        },
        else => return false,
    }
}

/// Content equality of two maps as keys (rt-free): same count + every
/// entry of `a` present in `b` with a key-equal value.
pub fn contentEq(a: Value, b: Value) bool {
    if (count(a) != count(b)) return false;
    return subsetOf(a, b, true);
}

/// Every key of `a` is contained in `b` (values ignored) — the set
/// equality partner.
pub fn keysSubsetOf(a: Value, b: Value) bool {
    return subsetOf(a, b, false);
}

// --- HAMT body (D-045 cycle A): CHAMP trie over `equal.valueHash` ---
//
// HamtMapNode.slots is a single `[64]Value` region: KV pairs are
// front-loaded (data entry i at slots[2*i], slots[2*i+1]); child
// pointers are back-loaded (child entry j at slots[63-j]). `data_map`
// marks hash-buckets holding a KV pair, `node_map` marks buckets holding
// a child — they are disjoint, so 2*popcount(data_map)+popcount(node_map)
// <= 64 always. shift advances 5 bits/level (0,5,…,30). A full 32-bit
// hash collision (depth exhausted past shift 30) raises
// `error.HashCollision` (a transient stub; cycle C lands a collision
// bucket — D-155). keys/vals/seq/dissoc on `.hash_map` still raise
// (cycle B).

const HAMT_SHIFT_STEP: u32 = 5;
const HAMT_MAX_SHIFT: u32 = 30;

inline fn hamtBit(hash_val: u32, shift: u32) u32 {
    const idx: u5 = @intCast((hash_val >> @intCast(shift)) & 0x1F);
    return @as(u32, 1) << idx;
}

/// Number of set bits below `bit` in `bitmap` = the entry's position in
/// the front (data) or back (node) region.
inline fn sparseIndex(bitmap: u32, bit: u32) u32 {
    return @popCount(bitmap & (bit - 1));
}

fn copyHamtNode(rt: *Runtime, node: *const HamtMapNode) !*HamtMapNode {
    const new = try rt.gc.alloc(HamtMapNode);
    new.* = .{
        .header = HeapHeader.init(.hamt_map_node),
        .data_map = node.data_map,
        .node_map = node.node_map,
        .slots = node.slots,
    };
    return new;
}

/// Build a node holding two distinct keys (assoc push-down + promotion
/// when two keys share a bucket). Raises `error.HashCollision` on a full
/// 32-bit hash match (cycle C replaces with a collision bucket).
fn createTwoNode(
    rt: *Runtime,
    k1: Value,
    v1: Value,
    h1: u32,
    k2: Value,
    v2: Value,
    h2: u32,
    shift: u32,
) !*HamtMapNode {
    if (shift > HAMT_MAX_SHIFT) return error.HashCollision;
    const bit1 = hamtBit(h1, shift);
    const bit2 = hamtBit(h2, shift);
    const node = try rt.gc.alloc(HamtMapNode);
    if (bit1 == bit2) {
        // same bucket — one level deeper, store as a single child
        const sub = try createTwoNode(rt, k1, v1, h1, k2, v2, h2, shift + HAMT_SHIFT_STEP);
        node.* = .{
            .header = HeapHeader.init(.hamt_map_node),
            .data_map = 0,
            .node_map = bit1,
            .slots = @splat(Value.nil_val),
        };
        node.slots[63] = Value.encodeHeapPtr(.hamt_map_node, sub);
    } else {
        node.* = .{
            .header = HeapHeader.init(.hamt_map_node),
            .data_map = bit1 | bit2,
            .node_map = 0,
            .slots = @splat(Value.nil_val),
        };
        const di1 = sparseIndex(bit1 | bit2, bit1);
        const di2 = sparseIndex(bit1 | bit2, bit2);
        node.slots[2 * di1] = k1;
        node.slots[2 * di1 + 1] = v1;
        node.slots[2 * di2] = k2;
        node.slots[2 * di2 + 1] = v2;
    }
    return node;
}

fn hamtGet(node: *const HamtMapNode, key: Value, hash_val: u32, shift: u32) !Value {
    const bit = hamtBit(hash_val, shift);
    if (node.data_map & bit != 0) {
        const di = sparseIndex(node.data_map, bit);
        if (try keyEq(node.slots[2 * di], key)) return node.slots[2 * di + 1];
        return Value.nil_val;
    }
    if (node.node_map & bit != 0) {
        const ni = sparseIndex(node.node_map, bit);
        const child = node.slots[63 - ni].decodePtr(*const HamtMapNode);
        return hamtGet(child, key, hash_val, shift + HAMT_SHIFT_STEP);
    }
    return Value.nil_val;
}

fn hamtContains(node: *const HamtMapNode, key: Value, hash_val: u32, shift: u32) !bool {
    const bit = hamtBit(hash_val, shift);
    if (node.data_map & bit != 0) {
        const di = sparseIndex(node.data_map, bit);
        return try keyEq(node.slots[2 * di], key);
    }
    if (node.node_map & bit != 0) {
        const ni = sparseIndex(node.node_map, bit);
        const child = node.slots[63 - ni].decodePtr(*const HamtMapNode);
        return hamtContains(child, key, hash_val, shift + HAMT_SHIFT_STEP);
    }
    return false;
}

const HamtAssocResult = struct { node: *HamtMapNode, added: bool };

fn hamtAssoc(
    rt: *Runtime,
    node: *const HamtMapNode,
    key: Value,
    val: Value,
    hash_val: u32,
    shift: u32,
) !HamtAssocResult {
    const bit = hamtBit(hash_val, shift);
    if (node.data_map & bit != 0) {
        const di = sparseIndex(node.data_map, bit);
        const ek = node.slots[2 * di];
        if (try keyEq(ek, key)) {
            const new = try copyHamtNode(rt, node);
            new.slots[2 * di + 1] = val;
            return .{ .node = new, .added = false };
        }
        // push-down: existing KV + new KV into a sub-node one level down
        const ev = node.slots[2 * di + 1];
        const sub = try createTwoNode(rt, ek, ev, try keyHash(ek), key, val, hash_val, shift + HAMT_SHIFT_STEP);
        const new = try pushDownDataToNode(rt, node, bit, di, sub);
        return .{ .node = new, .added = true };
    }
    if (node.node_map & bit != 0) {
        const ni = sparseIndex(node.node_map, bit);
        const child = node.slots[63 - ni].decodePtr(*const HamtMapNode);
        const res = try hamtAssoc(rt, child, key, val, hash_val, shift + HAMT_SHIFT_STEP);
        const new = try copyHamtNode(rt, node);
        new.slots[63 - ni] = Value.encodeHeapPtr(.hamt_map_node, res.node);
        return .{ .node = new, .added = res.added };
    }
    // empty bucket — insert a fresh data entry, shifting later pairs right
    const new = try insertDataEntry(rt, node, bit, key, val);
    return .{ .node = new, .added = true };
}

/// Copy `node` with a new data entry inserted at `bit`'s data-index,
/// shifting the existing front pairs at or after it right by one pair.
/// Back-loaded children keep their slots (the new bit was free, so the
/// front never reaches the back region).
fn insertDataEntry(rt: *Runtime, node: *const HamtMapNode, bit: u32, key: Value, val: Value) !*HamtMapNode {
    const new = try copyHamtNode(rt, node);
    new.data_map = node.data_map | bit;
    const di = sparseIndex(node.data_map, bit);
    const old_d = @popCount(node.data_map);
    var j = old_d;
    while (j > di) : (j -= 1) {
        new.slots[2 * j] = new.slots[2 * (j - 1)];
        new.slots[2 * j + 1] = new.slots[2 * (j - 1) + 1];
    }
    new.slots[2 * di] = key;
    new.slots[2 * di + 1] = val;
    return new;
}

/// Build a fresh node from `node` with the data entry at `di` removed and
/// `sub` added as the child for `bit` (the mirror of `insertDataEntry`'s
/// front growth — the layout changes, so this rebuilds rather than copies).
fn pushDownDataToNode(rt: *Runtime, node: *const HamtMapNode, bit: u32, di: u32, sub: *HamtMapNode) !*HamtMapNode {
    const new = try rt.gc.alloc(HamtMapNode);
    new.* = .{
        .header = HeapHeader.init(.hamt_map_node),
        .data_map = node.data_map & ~bit,
        .node_map = node.node_map | bit,
        .slots = @splat(Value.nil_val),
    };
    const old_d = @popCount(node.data_map);
    const old_n = @popCount(node.node_map);
    var w: u32 = 0;
    var r: u32 = 0;
    while (r < old_d) : (r += 1) {
        if (r == di) continue;
        new.slots[2 * w] = node.slots[2 * r];
        new.slots[2 * w + 1] = node.slots[2 * r + 1];
        w += 1;
    }
    const ni = sparseIndex(node.node_map | bit, bit);
    var j: u32 = 0;
    while (j < ni) : (j += 1) {
        new.slots[63 - j] = node.slots[63 - j];
    }
    new.slots[63 - ni] = Value.encodeHeapPtr(.hamt_map_node, sub);
    j = ni;
    while (j < old_n) : (j += 1) {
        new.slots[63 - (j + 1)] = node.slots[63 - j];
    }
    return new;
}

/// assoc on a promoted `.hash_map`: HAMT insert/replace → fresh root +
/// fresh PersistentHashMap (count grows only when a new key was added).
fn assocHashMap(rt: *Runtime, phm: *const PersistentHashMap, k: Value, val: Value) !Value {
    const res = try hamtAssoc(rt, phm.root.?, k, val, try keyHash(k), 0);
    const new_phm = try rt.gc.alloc(PersistentHashMap);
    new_phm.* = .{
        .header = HeapHeader.init(.hash_map),
        .count = if (res.added) phm.count + 1 else phm.count,
        .root = res.node,
        .meta = phm.meta,
    };
    return Value.encodeHeapPtr(.hash_map, new_phm);
}

/// ArrayMap at the 8-entry threshold gaining a 9th distinct key: build a
/// HAMT root from the 8 existing pairs + the new pair, wrap in a
/// PersistentHashMap.
fn promoteArrayMap(rt: *Runtime, am: *const ArrayMap, k: Value, val: Value) !Value {
    var root = try rt.gc.alloc(HamtMapNode);
    root.* = .{
        .header = HeapHeader.init(.hamt_map_node),
        .data_map = 0,
        .node_map = 0,
        .slots = @splat(Value.nil_val),
    };
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        const ek = am.entries[2 * i];
        const res = try hamtAssoc(rt, root, ek, am.entries[2 * i + 1], try keyHash(ek), 0);
        root = res.node;
    }
    const res = try hamtAssoc(rt, root, k, val, try keyHash(k), 0);
    const phm = try rt.gc.alloc(PersistentHashMap);
    phm.* = .{
        .header = HeapHeader.init(.hash_map),
        .count = am.count + 1,
        .root = res.node,
        .meta = am.meta,
    };
    return Value.encodeHeapPtr(.hash_map, phm);
}

// --- HAMT body (D-045 cycle B): dissoc + keys/vals/seq ---
//
// keys/vals/seq walk the trie pre-order, materialising a list (order is
// hash-bucket order, unspecified for a hash map — matches JVM). dissoc
// removes the entry and prunes an emptied child, but does NOT inline a
// single-entry sub-node back into its parent (a canonical-form
// micro-optimisation; cw has no trie-shape-dependent operation, so a
// non-inlined node is observationally identical — D-156). Per survey
// DIVERGENCE 3 there is no HAMT -> ArrayMap demotion (JVM-faithful): a
// map that dissocs back to <= 8 entries stays `.hash_map`.

fn hamtKeysInto(rt: *Runtime, node: *const HamtMapNode, acc: Value) !Value {
    var result = acc;
    const nc = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < nc) : (j += 1) {
        result = try hamtKeysInto(rt, node.slots[63 - j].decodePtr(*const HamtMapNode), result);
    }
    var i: u32 = @popCount(node.data_map);
    while (i > 0) {
        i -= 1;
        result = try list_mod.consHeap(rt, node.slots[2 * i], result);
    }
    return result;
}

fn hamtValsInto(rt: *Runtime, node: *const HamtMapNode, acc: Value) !Value {
    var result = acc;
    const nc = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < nc) : (j += 1) {
        result = try hamtValsInto(rt, node.slots[63 - j].decodePtr(*const HamtMapNode), result);
    }
    var i: u32 = @popCount(node.data_map);
    while (i > 0) {
        i -= 1;
        result = try list_mod.consHeap(rt, node.slots[2 * i + 1], result);
    }
    return result;
}

fn hamtSeqInto(rt: *Runtime, node: *const HamtMapNode, acc: Value) !Value {
    var result = acc;
    const nc = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < nc) : (j += 1) {
        result = try hamtSeqInto(rt, node.slots[63 - j].decodePtr(*const HamtMapNode), result);
    }
    var i: u32 = @popCount(node.data_map);
    while (i > 0) {
        i -= 1;
        // Distinct MapEntry (D-209 / ADR-0078), not a 2-vector.
        const pair = try map_entry_mod.make(rt, node.slots[2 * i], node.slots[2 * i + 1]);
        result = try list_mod.consHeap(rt, pair, result);
    }
    return result;
}

const HamtDissocResult = struct { node: ?*HamtMapNode, found: bool };

fn hamtDissoc(rt: *Runtime, node: *const HamtMapNode, key: Value, hash_val: u32, shift: u32) !HamtDissocResult {
    const bit = hamtBit(hash_val, shift);
    if (node.data_map & bit != 0) {
        const di = sparseIndex(node.data_map, bit);
        if (!try keyEq(node.slots[2 * di], key)) return .{ .node = null, .found = false };
        const new = try removeDataEntry(rt, node, bit, di);
        if (new.data_map == 0 and new.node_map == 0) return .{ .node = null, .found = true };
        return .{ .node = new, .found = true };
    }
    if (node.node_map & bit != 0) {
        const ni = sparseIndex(node.node_map, bit);
        const child = node.slots[63 - ni].decodePtr(*const HamtMapNode);
        const res = try hamtDissoc(rt, child, key, hash_val, shift + HAMT_SHIFT_STEP);
        if (!res.found) return .{ .node = null, .found = false };
        if (res.node) |new_child| {
            const new = try copyHamtNode(rt, node);
            new.slots[63 - ni] = Value.encodeHeapPtr(.hamt_map_node, new_child);
            return .{ .node = new, .found = true };
        }
        // child emptied — drop the node entry
        const new = try removeNodeEntry(rt, node, bit, ni);
        if (new.data_map == 0 and new.node_map == 0) return .{ .node = null, .found = true };
        return .{ .node = new, .found = true };
    }
    return .{ .node = null, .found = false };
}

/// Copy `node` with the data entry at `di` removed (clear `bit`, shift
/// later front pairs left, nil the vacated slot).
fn removeDataEntry(rt: *Runtime, node: *const HamtMapNode, bit: u32, di: u32) !*HamtMapNode {
    const new = try copyHamtNode(rt, node);
    new.data_map = node.data_map & ~bit;
    const old_d = @popCount(node.data_map);
    var j = di;
    while (j + 1 < old_d) : (j += 1) {
        new.slots[2 * j] = node.slots[2 * (j + 1)];
        new.slots[2 * j + 1] = node.slots[2 * (j + 1) + 1];
    }
    new.slots[2 * (old_d - 1)] = Value.nil_val;
    new.slots[2 * (old_d - 1) + 1] = Value.nil_val;
    return new;
}

/// Copy `node` with the child entry at node-index `ni` removed (clear
/// `bit`, shift later back children toward the back, nil the vacated slot).
fn removeNodeEntry(rt: *Runtime, node: *const HamtMapNode, bit: u32, ni: u32) !*HamtMapNode {
    const new = try copyHamtNode(rt, node);
    new.node_map = node.node_map & ~bit;
    const old_n = @popCount(node.node_map);
    var j = ni;
    while (j + 1 < old_n) : (j += 1) {
        new.slots[63 - j] = node.slots[63 - (j + 1)];
    }
    new.slots[63 - (old_n - 1)] = Value.nil_val;
    return new;
}

fn keysHashMap(rt: *Runtime, phm: *const PersistentHashMap) !Value {
    const root = phm.root orelse return Value.nil_val;
    return try hamtKeysInto(rt, root, Value.nil_val);
}

fn valsHashMap(rt: *Runtime, phm: *const PersistentHashMap) !Value {
    const root = phm.root orelse return Value.nil_val;
    return try hamtValsInto(rt, root, Value.nil_val);
}

fn seqHashMap(rt: *Runtime, phm: *const PersistentHashMap) !Value {
    const root = phm.root orelse return Value.nil_val;
    return try hamtSeqInto(rt, root, Value.nil_val);
}

fn dissocHashMap(rt: *Runtime, phm: *const PersistentHashMap, original: Value, k: Value) !Value {
    const res = try hamtDissoc(rt, phm.root.?, k, try keyHash(k), 0);
    if (!res.found) return original;
    const new_phm = try rt.gc.alloc(PersistentHashMap);
    new_phm.* = .{
        .header = HeapHeader.init(.hash_map),
        .count = phm.count - 1,
        .root = res.node,
        .meta = phm.meta,
    };
    return Value.encodeHeapPtr(.hash_map, new_phm);
}

/// `(with-meta m newmeta)` — shallow copy of the map (sharing entries /
/// root) with `meta` set. Handles both `.array_map` and `.hash_map`.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    switch (v.tag()) {
        .array_map => {
            const am = v.decodePtr(*const ArrayMap);
            const new_am = try rt.gc.alloc(ArrayMap);
            new_am.* = .{ .header = HeapHeader.init(.array_map), .count = am.count, .entries = am.entries, .meta = m };
            return Value.encodeHeapPtr(.array_map, new_am);
        },
        .hash_map => {
            const phm = v.decodePtr(*const PersistentHashMap);
            const new_phm = try rt.gc.alloc(PersistentHashMap);
            new_phm.* = .{ .header = HeapHeader.init(.hash_map), .count = phm.count, .root = phm.root, .meta = m };
            return Value.encodeHeapPtr(.hash_map, new_phm);
        },
        else => unreachable, // caller (metadata primitive) gates the tag
    }
}

/// Metadata of a map (or nil). Handles both map tags.
pub fn metaOf(v: Value) Value {
    return switch (v.tag()) {
        .array_map => v.decodePtr(*const ArrayMap).meta,
        .hash_map => v.decodePtr(*const PersistentHashMap).meta,
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

test "assoc at threshold: 9th distinct key promotes ArrayMap -> .hash_map, all readable" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var m = empty();
    for (0..ARRAY_MAP_THRESHOLD) |i| {
        m = try assoc(&fix.rt, m, Value.initInteger(@intCast(i)), Value.initInteger(@intCast(i * 10)));
    }
    try testing.expect(m.tag() == .array_map);
    m = try assoc(&fix.rt, m, Value.initInteger(99), Value.initInteger(990));
    try testing.expect(m.tag() == .hash_map);
    try testing.expectEqual(@as(u32, 9), count(m));
    // every key reads back through the trie
    for (0..ARRAY_MAP_THRESHOLD) |i| {
        try testing.expectEqual(
            @as(i48, @intCast(i * 10)),
            (try get(m, Value.initInteger(@intCast(i)))).asInteger(),
        );
    }
    try testing.expectEqual(@as(i48, 990), (try get(m, Value.initInteger(99))).asInteger());
    try testing.expect(try contains(m, Value.initInteger(99)));
    try testing.expect(!try contains(m, Value.initInteger(1000)));
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

test "seq returns a list of MapEntry pairs (nil for empty)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    try testing.expect((try seq(&fix.rt, empty())).isNil());

    var m = empty();
    m = try assoc(&fix.rt, m, Value.initInteger(1), Value.initInteger(100));
    m = try assoc(&fix.rt, m, Value.initInteger(2), Value.initInteger(200));

    const s = try seq(&fix.rt, m);
    try testing.expectEqual(@as(u32, 2), list_mod.countOf(s));
    // Each pair is a distinct MapEntry (D-209 / ADR-0078), not a 2-vector.
    const first_pair = list_mod.first(s);
    try testing.expect(first_pair.tag() == .map_entry);
    try testing.expectEqual(@as(i48, 1), map_entry_mod.keyOf(first_pair).asInteger());
    try testing.expectEqual(@as(i48, 100), map_entry_mod.valOf(first_pair).asInteger());
}

test "HAMT round-trip: build 100 int keys by assoc, read every key back (corruption canary)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const N = 100;
    var m = empty();
    var i: i48 = 0;
    while (i < N) : (i += 1) {
        m = try assoc(&fix.rt, m, Value.initInteger(i), Value.initInteger(i * i));
    }
    try testing.expect(m.tag() == .hash_map);
    try testing.expectEqual(@as(u32, N), count(m));
    i = 0;
    while (i < N) : (i += 1) {
        try testing.expectEqual(@as(i48, i * i), (try get(m, Value.initInteger(i))).asInteger());
        try testing.expect(try contains(m, Value.initInteger(i)));
    }
    try testing.expect(!try contains(m, Value.initInteger(N)));
    try testing.expect((try get(m, Value.initInteger(N))).tag() == .nil);

    // replace an existing key — count unchanged, value updated
    m = try assoc(&fix.rt, m, Value.initInteger(50), Value.initInteger(-1));
    try testing.expectEqual(@as(u32, N), count(m));
    try testing.expectEqual(@as(i48, -1), (try get(m, Value.initInteger(50))).asInteger());

    // insert a new key — count grows
    m = try assoc(&fix.rt, m, Value.initInteger(12345), Value.initInteger(7));
    try testing.expectEqual(@as(u32, N + 1), count(m));
    try testing.expectEqual(@as(i48, 7), (try get(m, Value.initInteger(12345))).asInteger());
}

test "HAMT round-trip: string keys hash by bytes (D-151) through the trie" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const string_mod = @import("string.zig");
    var m = empty();
    var i: usize = 0;
    var buf: [16]u8 = undefined;
    while (i < 30) : (i += 1) {
        const s = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        const ks = try string_mod.alloc(&fix.rt, s);
        m = try assoc(&fix.rt, m, ks, Value.initInteger(@intCast(i)));
    }
    try testing.expect(m.tag() == .hash_map);
    try testing.expectEqual(@as(u32, 30), count(m));
    // look up with a FRESH String Value (distinct pointer, equal bytes)
    const probe = try string_mod.alloc(&fix.rt, "key17");
    try testing.expectEqual(@as(i48, 17), (try get(m, probe)).asInteger());
    try testing.expect(try contains(m, probe));
    const miss = try string_mod.alloc(&fix.rt, "key99");
    try testing.expect((try get(m, miss)).tag() == .nil);
}

test "HAMT dissoc: remove half of 60 keys, survivors intact, count tracks (no leak)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const N = 60;
    var m = empty();
    var i: i48 = 0;
    while (i < N) : (i += 1) {
        m = try assoc(&fix.rt, m, Value.initInteger(i), Value.initInteger(i + 1000));
    }
    // dissoc every even key
    i = 0;
    while (i < N) : (i += 2) {
        m = try dissoc(&fix.rt, m, Value.initInteger(i));
    }
    try testing.expectEqual(@as(u32, N / 2), count(m));
    try testing.expect(m.tag() == .hash_map); // no demotion (survey DIVERGENCE 3)
    i = 0;
    while (i < N) : (i += 1) {
        if (@mod(i, 2) == 0) {
            try testing.expect((try get(m, Value.initInteger(i))).tag() == .nil);
            try testing.expect(!try contains(m, Value.initInteger(i)));
        } else {
            try testing.expectEqual(@as(i48, i + 1000), (try get(m, Value.initInteger(i))).asInteger());
        }
    }
    // dissoc an absent key returns the same map unchanged
    const before = m;
    m = try dissoc(&fix.rt, m, Value.initInteger(9999));
    try testing.expectEqual(@intFromEnum(before), @intFromEnum(m));
    // keys/vals/seq materialise the right number of entries
    try testing.expectEqual(@as(u32, N / 2), list_mod.countOf(try keys(&fix.rt, m)));
    try testing.expectEqual(@as(u32, N / 2), list_mod.countOf(try vals(&fix.rt, m)));
    try testing.expectEqual(@as(u32, N / 2), list_mod.countOf(try seq(&fix.rt, m)));
}
