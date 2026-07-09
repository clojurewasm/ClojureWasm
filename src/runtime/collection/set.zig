// SPDX-License-Identifier: EPL-2.0
//! PersistentHashSet — Clojure-shape set backed by PersistentHashMap
//! (5.5) per ROADMAP §9.7 row 5.6. Each element is a key in the
//! underlying map; the value is a sentinel (`Value.true_val`) since
//! the user only ever observes membership (contains? / seq).
//!
//! Tag: `.hash_set` (= A7) wraps a `PersistentHashSet` extern struct
//! holding a Value-encoded reference to the backing ArrayMap or
//! HashMap. Set ops conj / disj / contains? / count / seq translate
//! 1:1 to map assoc / dissoc / contains / count / keys. The backing
//! map promotes to a HAMT past 8 elements, so sets of any size work.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const HeapTag = value_mod.HeapTag;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const map_mod = @import("map.zig");

/// PersistentHashSet — extern struct wrapper over a backing map
/// Value (ArrayMap or HashMap). `count` mirrors the underlying map's
/// count (denormalised for O(1) access without touching the map).
pub const PersistentHashSet = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    map: Value = Value.nil_val,
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(PersistentHashSet) >= 8);
        std.debug.assert(@offsetOf(PersistentHashSet, "header") == 0);
    }
};

/// Empty set singleton (count = 0, map = empty ArrayMap).
pub var EMPTY: PersistentHashSet align(8) = .{
    .header = HeapHeader.init(.hash_set),
    .count = 0,
    .map = undefined,
    .meta = Value.nil_val,
};

/// Initialise EMPTY.map at module init (cannot reference the function
/// `map_mod.empty()` from a comptime const literal). Called from
/// `registerGcHooks`.
fn initEmptySingleton() void {
    EMPTY.map = map_mod.empty();
}

/// Empty set as a Value.
pub fn empty() Value {
    return Value.encodeHeapPtr(.hash_set, &EMPTY);
}

/// O(1) element count.
pub fn count(v: Value) u32 {
    return switch (v.tag()) {
        .hash_set => v.decodePtr(*const PersistentHashSet).count,
        .nil => 0,
        else => 0,
    };
}

/// `(contains? s e)` — true iff `e` is a member of `s`.
pub fn contains(v: Value, e: Value) !bool {
    return switch (v.tag()) {
        .hash_set => map_mod.contains(v.decodePtr(*const PersistentHashSet).map, e),
        .nil => false,
        else => false,
    };
}

/// Content hash of a set as a key (rt-free, order-independent) — folds
/// element hashes over the backing map's keys. Partner of
/// `equal.valueHash` / `equal.keyEqValue` set arms (D-092).
pub fn contentHash(v: Value) u32 {
    return switch (v.tag()) {
        .hash_set => map_mod.keysetHash(v.decodePtr(*const PersistentHashSet).map),
        else => 0,
    };
}

/// Content equality of two sets as keys (rt-free): same count + every
/// element of `a` present in `b`. Rides the backing maps' key subset.
pub fn contentEq(a: Value, b: Value) bool {
    if (count(a) != count(b)) return false;
    const am = a.decodePtr(*const PersistentHashSet).map;
    const bm = b.decodePtr(*const PersistentHashSet).map;
    return map_mod.keysSubsetOf(am, bm);
}

/// Walk every element of a `.hash_set` (= the keys of its backing map).
/// Pure (no rt/env, no allocation), mirroring `map.forEachEntry`.
pub fn forEachElem(
    v: Value,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Value) anyerror!void,
) anyerror!void {
    const Wrap = struct {
        fn entry(c: @TypeOf(ctx), k: Value, _: Value) anyerror!void {
            try cb(c, k);
        }
    };
    try map_mod.forEachEntry(v.decodePtr(*const PersistentHashSet).map, ctx, Wrap.entry);
}

/// `(conj s e)` — returns a new set with `e` added. Idempotent —
/// re-adding an existing element returns an equivalent set
/// (current implementation may copy; identity-preservation deferred).
pub fn conj(rt: *Runtime, v: Value, e: Value) !Value {
    std.debug.assert(v.tag() == .hash_set);
    // D-244 #4: `new_map` is held unrooted across `alloc(PersistentHashSet)`
    // (ADR-0150 fabrication region; also covers map_mod.assoc's internal nodes).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const old = v.decodePtr(*const PersistentHashSet);
    const new_map = try map_mod.assoc(rt, old.map, e, Value.true_val);
    const new_set = try rt.gc.alloc(PersistentHashSet);
    new_set.* = .{
        .header = HeapHeader.init(.hash_set),
        .count = map_mod.count(new_map),
        .map = new_map,
        .meta = old.meta,
    };
    return Value.encodeHeapPtr(.hash_set, new_set);
}

/// `(disj s e)` — returns a new set with `e` removed. Idempotent —
/// removing an absent element returns the original (no copy when
/// the underlying map's dissoc returns identity).
pub fn disj(rt: *Runtime, v: Value, e: Value) !Value {
    std.debug.assert(v.tag() == .hash_set);
    // D-244 #4: `new_map` held unrooted across `alloc(PersistentHashSet)`
    // (ADR-0150 fabrication region).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const old = v.decodePtr(*const PersistentHashSet);
    const new_map = try map_mod.dissoc(rt, old.map, e);
    if (@intFromEnum(new_map) == @intFromEnum(old.map)) return v; // absent — identity
    const new_set = try rt.gc.alloc(PersistentHashSet);
    new_set.* = .{
        .header = HeapHeader.init(.hash_set),
        .count = map_mod.count(new_map),
        .map = new_map,
        .meta = old.meta,
    };
    return Value.encodeHeapPtr(.hash_set, new_set);
}

/// `(seq s)` — returns a list of set elements (nil for empty per
/// Clojure). Reuses `map.keys` since values are all the sentinel.
pub fn seq(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .hash_set => try map_mod.keys(rt, v.decodePtr(*const PersistentHashSet).map),
        .nil => Value.nil_val,
        else => error.SeqOnNonSet,
    };
}

/// Per-tag trace fn — walks the backing map Value + meta.
pub fn traceSet(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const s: *PersistentHashSet = @ptrCast(@alignCast(header));
    if (s.map.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (s.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register the set trace fn + initialise the EMPTY singleton's map
/// field. Called from `Runtime.init` (idempotent; multi-Runtime
/// test process re-runs safely).
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.hash_set, &traceSet);
    initEmptySingleton();
}

/// Metadata of a set (or nil).
pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const PersistentHashSet).meta;
}

/// `(with-meta s newmeta)` — shallow copy sharing the backing map, meta set.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const s = v.decodePtr(*const PersistentHashSet);
    const ns = try rt.gc.alloc(PersistentHashSet);
    ns.* = .{ .header = HeapHeader.init(.hash_set), .count = s.count, .map = s.map, .meta = m };
    return Value.encodeHeapPtr(.hash_set, ns);
}

// --- tests ---

const testing = std.testing;

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

test "EMPTY set: count = 0, contains? returns false" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = empty();
    try testing.expect(s.tag() == .hash_set);
    try testing.expectEqual(@as(u32, 0), count(s));
    try testing.expect(!try contains(s, Value.initInteger(42)));
}

test "conj adds element: count = 1, contains? returns true" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s1 = try conj(&fix.rt, empty(), Value.initInteger(42));
    try testing.expectEqual(@as(u32, 1), count(s1));
    try testing.expect(try contains(s1, Value.initInteger(42)));
    try testing.expect(!try contains(s1, Value.initInteger(99)));
}

test "conj is idempotent: re-adding doesn't grow count" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var s = empty();
    s = try conj(&fix.rt, s, Value.initInteger(42));
    s = try conj(&fix.rt, s, Value.initInteger(42));
    try testing.expectEqual(@as(u32, 1), count(s));
}

test "disj removes element: count decremented" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var s = empty();
    s = try conj(&fix.rt, s, Value.initInteger(1));
    s = try conj(&fix.rt, s, Value.initInteger(2));
    s = try conj(&fix.rt, s, Value.initInteger(3));

    const s2 = try disj(&fix.rt, s, Value.initInteger(2));
    try testing.expectEqual(@as(u32, 2), count(s2));
    try testing.expect(try contains(s2, Value.initInteger(1)));
    try testing.expect(!try contains(s2, Value.initInteger(2)));
    try testing.expect(try contains(s2, Value.initInteger(3)));
}

test "disj absent element: returns original set (identity)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const s = try conj(&fix.rt, empty(), Value.initInteger(1));
    const s2 = try disj(&fix.rt, s, Value.initInteger(99));
    try testing.expectEqual(@intFromEnum(s), @intFromEnum(s2));
}

test "seq returns a list of elements (nil for empty)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    try testing.expect((try seq(&fix.rt, empty())).isNil());

    var s = empty();
    s = try conj(&fix.rt, s, Value.initInteger(10));
    s = try conj(&fix.rt, s, Value.initInteger(20));
    s = try conj(&fix.rt, s, Value.initInteger(30));

    const list_mod = @import("list.zig");
    const lst = try seq(&fix.rt, s);
    try testing.expectEqual(@as(u32, 3), list_mod.countOf(lst));
}

test "PersistentHashSet layout: header at offset 0" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(PersistentHashSet, "header"));
    try testing.expect(@alignOf(PersistentHashSet) >= 8);
}

test "count on nil = 0; contains on nil = false" {
    try testing.expectEqual(@as(u32, 0), count(Value.nil_val));
    try testing.expect(!try contains(Value.nil_val, Value.initInteger(1)));
}
