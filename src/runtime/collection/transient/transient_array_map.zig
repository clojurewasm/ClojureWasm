// SPDX-License-Identifier: EPL-2.0
//! TransientArrayMap — single-use mutable map scratch that materialises
//! into a persistent map via `persistent!`. Phase 8 row 8.5 cycle 2
//! landing per D-074; >8-entry support added per ADR-0064 (D-045
//! transient half).
//!
//! ## Shape
//!
//!   ```
//!   TransientArrayMap { consumed, count, entries: [16]Value, meta, overflow }
//!   ```
//!
//! Two modes, gated by `overflow`:
//!
//! - **Flat mode** (`overflow == nil`, count ≤ 8): entries stored
//!   `[k0, v0, k1, v1, …]` in `entries[0..2*count]`, mirroring the
//!   persistent ArrayMap layout (`runtime/collection/map.zig`). `assoc!`
//!   replaces in place on a key hit, appends on a new key.
//! - **Hash mode** (`overflow` holds a persistent `.hash_map`): once a
//!   9th distinct key arrives, the 8 flat pairs + the new key are
//!   replayed through `map.assoc` into a persistent HAMT held in
//!   `overflow`; further `assoc!`/`dissoc!` delegate to the persistent
//!   `map.assoc`/`map.dissoc` (which dedup + promote for free). This
//!   mirrors how the *persistent* ArrayMap transitions to a HAMT past 8.
//!
//! Per ADR-0064 (Alt 1) hash-mode `assoc!` is persistent-path
//! O(log32 n) copy-on-write, NOT an in-place editable-CHAMP transient —
//! correct (the result equals `(reduce conj {} …)` byte-for-byte) but
//! without the in-place allocation win. The editable-CHAMP finished form
//! is deferred to D-181 (maps were not a measured perf bottleneck;
//! §9.2.S ROI was vectors). Once in hash mode, the transient never
//! demotes back to flat (matching the persistent side's no-HAMT→ArrayMap
//! demotion).
//!
//! ## Lifecycle (mirrors transient_vector.zig)
//!
//! - `(transient m)` on `.array_map` source copies entries inline; on
//!   `.hash_map` source holds it directly in `overflow` (hash mode).
//! - Each `(assoc! tm k v)` / `(dissoc! tm k)` / `(conj! tm [k v])`
//!   checks `consumed == 0`, mutates in place (flat) or rebinds
//!   `overflow` (hash), returns the same Value.
//! - `(persistent! tm)` flips `consumed = 1`, returns the flat-built
//!   ArrayMap (flat mode) or `overflow` (hash mode), re-applying `meta`.

const std = @import("std");
const value_mod = @import("../../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../../runtime.zig").Runtime;
const error_catalog = @import("../../error/catalog.zig");
const error_mod = @import("../../error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const tag_ops = @import("../../gc/tag_ops.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const map_mod = @import("../map.zig");
const vector_mod = @import("../vector.zig");
const map_entry_mod = @import("../map_entry.zig");
const equal = @import("../../equal.zig");

const ARRAY_MAP_THRESHOLD = map_mod.ARRAY_MAP_THRESHOLD;

pub const TransientArrayMap = extern struct {
    header: HeapHeader,
    consumed: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    count: u32 = 0,
    entries: [2 * ARRAY_MAP_THRESHOLD]Value = @splat(Value.nil_val),
    meta: Value = Value.nil_val,
    /// Persistent `.hash_map` once the map grows past ARRAY_MAP_THRESHOLD.
    /// `nil` = flat mode (use `entries`); non-nil = hash mode (ADR-0064).
    overflow: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(TransientArrayMap) >= 8);
        std.debug.assert(@offsetOf(TransientArrayMap, "header") == 0);
    }
};

fn keyEq(a: Value, b: Value) bool {
    return equal.keyEqValue(a, b); // D-151: value-eq for String keys
}

/// Build a TransientArrayMap from a persistent map source. `.array_map`
/// copies entries inline (flat mode); `.hash_map` holds the source map
/// directly in `overflow` (hash mode — it is already a HAMT and
/// `map.assoc` is copy-on-write, so the source is never mutated).
/// `.nil` produces an empty transient.
pub fn fromMap(rt: *Runtime, source: Value) !Value {
    const tm = try rt.gc.alloc(TransientArrayMap);
    tm.* = .{ .header = HeapHeader.init(.transient_map) };

    if (source.isNil()) return Value.encodeHeapPtr(.transient_map, tm);

    switch (source.tag()) {
        .array_map => {
            const am = source.decodePtr(*const map_mod.ArrayMap);
            tm.count = am.count;
            var i: u32 = 0;
            while (i < 2 * am.count) : (i += 1) {
                tm.entries[i] = am.entries[i];
            }
            tm.meta = am.meta;
        },
        .hash_map => {
            tm.overflow = source;
            tm.count = map_mod.count(source);
            tm.meta = map_mod.metaOf(source);
        },
        else => unreachable, // caller (primitive layer) gates the tag set
    }
    return Value.encodeHeapPtr(.transient_map, tm);
}

pub fn toPersistent(rt: *Runtime, tm_val: Value, loc: SourceLocation) !Value {
    const tm = try expectTransient(tm_val, "persistent!", loc);
    try ensureEditable(tm, "persistent!", loc);
    tm.consumed = 1;

    // D-244 #4: `out` held unrooted across the assoc-replay + `withMeta` allocs
    // (ADR-0150 fabrication region; map_mod.assoc also brackets internally).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var out: Value = undefined;
    if (tm.overflow.isNil()) {
        out = map_mod.empty();
        var i: u32 = 0;
        while (i < tm.count) : (i += 1) {
            out = try map_mod.assoc(rt, out, tm.entries[2 * i], tm.entries[2 * i + 1]);
        }
    } else {
        out = tm.overflow; // already a persistent .hash_map
    }
    if (tm.meta.isNil()) return out;
    return try map_mod.withMeta(rt, out, tm.meta);
}

pub fn assoc(rt: *Runtime, tm_val: Value, k: Value, v: Value, loc: SourceLocation) !Value {
    const tm = try expectTransient(tm_val, "assoc!", loc);
    try ensureEditable(tm, "assoc!", loc);

    // Hash mode: delegate to the persistent HAMT (dedups + promotes for
    // free; the result equals the persistent-conj path byte-for-byte).
    if (!tm.overflow.isNil()) {
        tm.overflow = try map_mod.assoc(rt, tm.overflow, k, v);
        tm.count = map_mod.count(tm.overflow);
        return tm_val;
    }

    // Flat mode: existing key → replace in place, stay flat.
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (keyEq(tm.entries[2 * i], k)) {
            tm.entries[2 * i + 1] = v;
            return tm_val;
        }
    }
    // New distinct key with room → append.
    if (tm.count < ARRAY_MAP_THRESHOLD) {
        tm.entries[2 * tm.count] = k;
        tm.entries[2 * tm.count + 1] = v;
        tm.count += 1;
        return tm_val;
    }
    // count == ARRAY_MAP_THRESHOLD and a new distinct key arrived:
    // promote to a persistent HAMT (replay the 8 flat pairs + the new
    // key through map.assoc, which auto-promotes array_map → hash_map).
    var m = map_mod.empty();
    var j: u32 = 0;
    while (j < tm.count) : (j += 1) {
        m = try map_mod.assoc(rt, m, tm.entries[2 * j], tm.entries[2 * j + 1]);
    }
    m = try map_mod.assoc(rt, m, k, v);
    tm.overflow = m;
    tm.count = map_mod.count(m);
    return tm_val;
}

/// Entry count — read accessor so `count` treats a live transient map as
/// a first-class read target (clj parity). No editable check: reads are
/// valid on a live transient.
pub fn count(tm_val: Value) u32 {
    return tm_val.decodePtr(*const TransientArrayMap).count;
}

/// True iff key `k` is present (both flat + hash modes). Powers
/// `contains?` / the `get` lookup on a transient map.
pub fn contains(tm_val: Value, k: Value) !bool {
    const tm = tm_val.decodePtr(*const TransientArrayMap);
    if (!tm.overflow.isNil()) return map_mod.contains(tm.overflow, k); // hash mode
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (keyEq(tm.entries[2 * i], k)) return true;
    }
    return false;
}

/// Value for key `k`, or nil when absent (callers guard via `contains`
/// for the not-found-vs-nil-value distinction, mirroring the persistent
/// `getFn` path). Both flat + hash modes.
pub fn get(tm_val: Value, k: Value) !Value {
    const tm = tm_val.decodePtr(*const TransientArrayMap);
    if (!tm.overflow.isNil()) return map_mod.get(tm.overflow, k); // hash mode
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (keyEq(tm.entries[2 * i], k)) return tm.entries[2 * i + 1];
    }
    return Value.nil_val;
}

pub fn dissoc(rt: *Runtime, tm_val: Value, k: Value, loc: SourceLocation) !Value {
    const tm = try expectTransient(tm_val, "dissoc!", loc);
    try ensureEditable(tm, "dissoc!", loc);

    // Hash mode: delegate to persistent dissoc. Stays in hash mode even
    // if count drops ≤ 8 (matches the persistent side's no demotion).
    if (!tm.overflow.isNil()) {
        tm.overflow = try map_mod.dissoc(rt, tm.overflow, k);
        tm.count = map_mod.count(tm.overflow);
        return tm_val;
    }

    var found: ?u32 = null;
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (keyEq(tm.entries[2 * i], k)) {
            found = i;
            break;
        }
    }
    if (found == null) return tm_val;
    const idx = found.?;
    // Shift entries after idx down by one K/V pair.
    var w: u32 = idx;
    while (w + 1 < tm.count) : (w += 1) {
        tm.entries[2 * w] = tm.entries[2 * (w + 1)];
        tm.entries[2 * w + 1] = tm.entries[2 * (w + 1) + 1];
    }
    tm.count -= 1;
    tm.entries[2 * tm.count] = Value.nil_val;
    tm.entries[2 * tm.count + 1] = Value.nil_val;
    return tm_val;
}

/// Widened `conj!` arm for map-shape transients: accepts a 2-element
/// vector `[k v]` OR a distinct MapEntry (D-209 / ADR-0078; the `into {}`
/// path conj!s the entries a map-seq yields, which are now `.map_entry`).
pub fn conjEntry(rt: *Runtime, tm_val: Value, entry: Value, loc: SourceLocation) !Value {
    if (entry.tag() == .map_entry) {
        return try assoc(rt, tm_val, map_entry_mod.keyOf(entry), map_entry_mod.valOf(entry), loc);
    }
    if (entry.tag() != .vector or vector_mod.count(entry) != 2) {
        // A non-[k v] entry conj!-ed into a transient map → IllegalArgumentException
        // in clj (mirrors the persistent `(conj {} 1)` path), NOT the
        // ClassCastException of a wrong-transient-KIND mismatch. D-459 (this is the
        // path `(into {} [1])` takes — into builds via a transient).
        return error_catalog.raise(.arg_value_invalid, loc, .{
            .fn_name = "conj!",
            .expected = "2-element [k v] vector",
            .actual = @tagName(entry.tag()),
        });
    }
    const k = vector_mod.nth(entry, 0);
    const v = vector_mod.nth(entry, 1);
    return try assoc(rt, tm_val, k, v, loc);
}

pub fn traceTransientArrayMap(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const tm: *TransientArrayMap = @ptrCast(@alignCast(header));
    // Flat-mode entries (count is the persistent map's count in hash
    // mode, so guard the entries walk on flat mode to avoid reading
    // stale slots beyond ARRAY_MAP_THRESHOLD).
    if (tm.overflow.isNil()) {
        var i: u32 = 0;
        while (i < tm.count) : (i += 1) {
            if (tm.entries[2 * i].heapHeader()) |h| mark_sweep.mark(gc, h);
            if (tm.entries[2 * i + 1].heapHeader()) |h| mark_sweep.mark(gc, h);
        }
    } else {
        if (tm.overflow.heapHeader()) |h| mark_sweep.mark(gc, h);
    }
    if (tm.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.transient_map, &traceTransientArrayMap);
}

// --- internals ---

fn expectTransient(v: Value, fn_name: []const u8, loc: SourceLocation) !*TransientArrayMap {
    if (v.tag() != .transient_map) {
        return error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = fn_name,
            .expected = "transient_map",
            .actual = @tagName(v.tag()),
        });
    }
    return v.decodePtr(*TransientArrayMap);
}

fn ensureEditable(tm: *TransientArrayMap, fn_name: []const u8, loc: SourceLocation) !void {
    if (tm.consumed != 0) {
        return error_catalog.raise(.transient_used_after_persistent, loc, .{
            .fn_name = fn_name,
        });
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "TransientArrayMap layout asserts" {
    try testing.expect(@offsetOf(TransientArrayMap, "header") == 0);
    try testing.expect(@alignOf(TransientArrayMap) >= 8);
}

test "fromMap on nil + persistent! returns empty array_map" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    try testing.expect(tm.tag() == .transient_map);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expect(p.tag() == .array_map);
    try testing.expectEqual(@as(u32, 0), map_mod.count(p));
}

test "assoc! + persistent! round-trip" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    _ = try assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(10), loc);
    _ = try assoc(&fix.rt, tm, Value.initInteger(2), Value.initInteger(20), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 2), map_mod.count(p));
    try testing.expectEqual(@as(i48, 10), (try map_mod.get(p, Value.initInteger(1))).asInteger());
    try testing.expectEqual(@as(i48, 20), (try map_mod.get(p, Value.initInteger(2))).asInteger());
}

test "assoc! replaces existing key in place" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    _ = try assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(10), loc);
    _ = try assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(99), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 1), map_mod.count(p));
    try testing.expectEqual(@as(i48, 99), (try map_mod.get(p, Value.initInteger(1))).asInteger());
}

test "dissoc! removes a key" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    _ = try assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(10), loc);
    _ = try assoc(&fix.rt, tm, Value.initInteger(2), Value.initInteger(20), loc);
    _ = try dissoc(&fix.rt, tm, Value.initInteger(1), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 1), map_mod.count(p));
    try testing.expectEqual(@as(i48, 20), (try map_mod.get(p, Value.initInteger(2))).asInteger());
}

test "assoc! beyond ARRAY_MAP_THRESHOLD promotes to a persistent hash map (ADR-0064)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    // 20 distinct keys crosses the threshold (8) into hash mode.
    var i: i48 = 0;
    while (i < 20) : (i += 1) {
        _ = try assoc(&fix.rt, tm, Value.initInteger(i), Value.initInteger(i + 100), loc);
    }
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expect(p.tag() == .hash_map); // promoted past 8
    try testing.expectEqual(@as(u32, 20), map_mod.count(p));
    // Every key round-trips (the bug this fixes: get returned nil/error).
    var k: i48 = 0;
    while (k < 20) : (k += 1) {
        try testing.expectEqual(@as(i48, k + 100), (try map_mod.get(p, Value.initInteger(k))).asInteger());
    }
    // Equivalence with the persistent-conj path (F-011): build the same
    // map via map.assoc and confirm identical lookups.
    var ref = map_mod.empty();
    var r: i48 = 0;
    while (r < 20) : (r += 1) ref = try map_mod.assoc(&fix.rt, ref, Value.initInteger(r), Value.initInteger(r + 100));
    try testing.expectEqual(map_mod.count(ref), map_mod.count(p));
}

test "assoc! replace-in-place near the threshold stays flat (no spurious promotion)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    var i: i48 = 0;
    while (i < ARRAY_MAP_THRESHOLD) : (i += 1) {
        _ = try assoc(&fix.rt, tm, Value.initInteger(i), Value.initInteger(i), loc);
    }
    // Re-assoc an existing key while full — must replace in place, NOT
    // promote (the count-8-with-existing-key trap).
    _ = try assoc(&fix.rt, tm, Value.initInteger(3), Value.initInteger(999), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expect(p.tag() == .array_map); // stayed flat
    try testing.expectEqual(@as(u32, ARRAY_MAP_THRESHOLD), map_mod.count(p));
    try testing.expectEqual(@as(i48, 999), (try map_mod.get(p, Value.initInteger(3))).asInteger());
}

test "dissoc! in hash mode stays hash even below 8 (no demotion)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    var i: i48 = 0;
    while (i < 12) : (i += 1) {
        _ = try assoc(&fix.rt, tm, Value.initInteger(i), Value.initInteger(i), loc);
    }
    // Drop back below 8 — persistent side has no HAMT→ArrayMap demotion,
    // so the transient must stay hash too.
    var d: i48 = 0;
    while (d < 7) : (d += 1) _ = try dissoc(&fix.rt, tm, Value.initInteger(d), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expect(p.tag() == .hash_map);
    try testing.expectEqual(@as(u32, 5), map_mod.count(p));
    try testing.expectEqual(@as(i48, 9), (try map_mod.get(p, Value.initInteger(9))).asInteger());
}

test "transient of a .hash_map source seeds hash mode + assoc!" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    // Build a persistent hash_map (> 8 entries) the persistent way.
    var src = map_mod.empty();
    var i: i48 = 0;
    while (i < 10) : (i += 1) src = try map_mod.assoc(&fix.rt, src, Value.initInteger(i), Value.initInteger(i));
    try testing.expect(src.tag() == .hash_map);

    const tm = try fromMap(&fix.rt, src); // previously error.HashMapNotImplemented
    _ = try assoc(&fix.rt, tm, Value.initInteger(99), Value.initInteger(99), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 11), map_mod.count(p));
    try testing.expectEqual(@as(i48, 99), (try map_mod.get(p, Value.initInteger(99))).asInteger());
    // Source unchanged (persistent assoc is copy-on-write).
    try testing.expectEqual(@as(u32, 10), map_mod.count(src));
}

test "persistent! carries the source map's meta through" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    // array_map source with meta.
    var meta_pairs = map_mod.empty();
    meta_pairs = try map_mod.assoc(&fix.rt, meta_pairs, Value.initInteger(0), Value.initInteger(1));
    var src = map_mod.empty();
    src = try map_mod.assoc(&fix.rt, src, Value.initInteger(7), Value.initInteger(70));
    src = try map_mod.withMeta(&fix.rt, src, meta_pairs);

    const tm = try fromMap(&fix.rt, src);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expect(!map_mod.metaOf(p).isNil());
    try testing.expectEqual(@as(i48, 70), (try map_mod.get(p, Value.initInteger(7))).asInteger());
}

test "conj! [k v] vector dispatches to assoc!" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);

    var pair = vector_mod.empty();
    pair = try vector_mod.conj(&fix.rt, pair, Value.initInteger(7));
    pair = try vector_mod.conj(&fix.rt, pair, Value.initInteger(70));
    _ = try conjEntry(&fix.rt, tm, pair, loc);

    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 1), map_mod.count(p));
    try testing.expectEqual(@as(i48, 70), (try map_mod.get(p, Value.initInteger(7))).asInteger());
}

test "assoc! after persistent! raises transient_used_after_persistent" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    _ = try toPersistent(&fix.rt, tm, loc);
    error_mod.clearLastError();
    try testing.expectError(
        error_mod.ClojureWasmError.StateError,
        assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(1), loc),
    );
}
