// SPDX-License-Identifier: EPL-2.0
//! TransientArrayMap — single-use mutable scratch buffer that
//! materialises into a PersistentHashMap (ArrayMap variant) via
//! `persistent!`. Phase 8 row 8.5 cycle 2 landing per D-074.
//!
//! ## Shape
//!
//!   ```
//!   TransientArrayMap { consumed, count, entries: [16]Value, meta }
//!   ```
//!
//! Mirrors the persistent ArrayMap layout (`runtime/collection/map.zig`
//! L55-65): entries stored as `[k0, v0, k1, v1, ...]` in
//! `entries[0..2*count]`. Capped at 8 K/V pairs (= ARRAY_MAP_THRESHOLD)
//! for the cycle-2 landing; growing past 8 requires `TransientHashMap`
//! which blocks on D-045 (HAMT body for `.hash_map`). When `assoc!`
//! would push count past 8 with a new key, the call raises
//! `feature_not_supported` naming "transient assoc! beyond ArrayMap
//! capacity (transient hash_map pending)" so the user sees an explicit
//! signal rather than a silent degradation.
//!
//! ## Lifecycle (mirrors transient_vector.zig)
//!
//! - `(transient m)` on `.array_map` source copies entries inline.
//! - `(transient m)` on `.hash_map` source raises
//!   `error.HashMapNotImplemented` (mirrors persistent dispatch —
//!   transient stub per `provisional_marker.md` row 2 / D-045 hook).
//! - Each `(assoc! tm k v)` / `(dissoc! tm k)` / `(conj! tm [k v])`
//!   checks `consumed == 0`, mutates in place, returns same Value.
//! - `(persistent! tm)` flips `consumed = 1`, rebuilds a persistent
//!   ArrayMap via repeated `map.assoc` over the entries.

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
const equal = @import("../../equal.zig");

const ARRAY_MAP_THRESHOLD = map_mod.ARRAY_MAP_THRESHOLD;

pub const TransientArrayMap = extern struct {
    header: HeapHeader,
    consumed: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    count: u32 = 0,
    entries: [2 * ARRAY_MAP_THRESHOLD]Value = @splat(Value.nil_val),
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(TransientArrayMap) >= 8);
        std.debug.assert(@offsetOf(TransientArrayMap, "header") == 0);
    }
};

fn keyEq(a: Value, b: Value) bool {
    return equal.keyEqValue(a, b); // D-151: value-eq for String keys
}

/// Build a TransientArrayMap from a persistent map source. Cycle 2
/// supports `.array_map` source only; `.hash_map` source raises
/// `error.HashMapNotImplemented` (mirrors the persistent dispatch
/// gap pending D-045). `.nil` produces an empty transient.
pub fn fromMap(rt: *Runtime, source: Value) !Value {
    const tm = try rt.gc.alloc(TransientArrayMap);
    tm.* = .{ .header = HeapHeader.init(.transient_map) };

    if (source.isNil()) return Value.encodeHeapPtr(.transient_map, tm);

    return switch (source.tag()) {
        .array_map => blk: {
            const am = source.decodePtr(*const map_mod.ArrayMap);
            tm.count = am.count;
            var i: u32 = 0;
            while (i < 2 * am.count) : (i += 1) {
                tm.entries[i] = am.entries[i];
            }
            break :blk Value.encodeHeapPtr(.transient_map, tm);
        },
        .hash_map => error.HashMapNotImplemented,
        else => unreachable, // caller (primitive layer) gates the tag set
    };
}

pub fn toPersistent(rt: *Runtime, tm_val: Value, loc: SourceLocation) !Value {
    const tm = try expectTransient(tm_val, "persistent!", loc);
    try ensureEditable(tm, "persistent!", loc);
    tm.consumed = 1;

    var out = map_mod.empty();
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        out = try map_mod.assoc(rt, out, tm.entries[2 * i], tm.entries[2 * i + 1]);
    }
    return out;
}

pub fn assoc(rt: *Runtime, tm_val: Value, k: Value, v: Value, loc: SourceLocation) !Value {
    _ = rt;
    const tm = try expectTransient(tm_val, "assoc!", loc);
    try ensureEditable(tm, "assoc!", loc);

    // Search for existing key.
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (keyEq(tm.entries[2 * i], k)) {
            tm.entries[2 * i + 1] = v;
            return tm_val;
        }
    }
    // New key — append if room remains.
    if (tm.count >= ARRAY_MAP_THRESHOLD) {
        return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "transient assoc! beyond ArrayMap capacity (transient hash_map pending)",
        });
    }
    tm.entries[2 * tm.count] = k;
    tm.entries[2 * tm.count + 1] = v;
    tm.count += 1;
    return tm_val;
}

pub fn dissoc(tm_val: Value, k: Value, loc: SourceLocation) !Value {
    const tm = try expectTransient(tm_val, "dissoc!", loc);
    try ensureEditable(tm, "dissoc!", loc);

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
/// vector `[k v]`. JVM also accepts `MapEntry`, but cw v1 has no
/// `.map_entry`-tagged Values yet (F-004 slot reserved but unwired)
/// so vector is the only supported entry shape.
pub fn conjEntry(rt: *Runtime, tm_val: Value, entry: Value, loc: SourceLocation) !Value {
    if (entry.tag() != .vector or vector_mod.count(entry) != 2) {
        return error_catalog.raise(.transient_kind_mismatch, loc, .{
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
    var i: u32 = 0;
    while (i < tm.count) : (i += 1) {
        if (tm.entries[2 * i].heapHeader()) |h| mark_sweep.mark(gc, h);
        if (tm.entries[2 * i + 1].heapHeader()) |h| mark_sweep.mark(gc, h);
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
    _ = try dissoc(tm, Value.initInteger(1), loc);
    const p = try toPersistent(&fix.rt, tm, loc);
    try testing.expectEqual(@as(u32, 1), map_mod.count(p));
    try testing.expectEqual(@as(i48, 20), (try map_mod.get(p, Value.initInteger(2))).asInteger());
}

test "assoc! beyond capacity raises feature_not_supported" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tm = try fromMap(&fix.rt, Value.nil_val);
    var i: i48 = 0;
    while (i < ARRAY_MAP_THRESHOLD) : (i += 1) {
        _ = try assoc(&fix.rt, tm, Value.initInteger(i), Value.initInteger(i + 100), loc);
    }
    error_mod.clearLastError();
    try testing.expectError(
        error_mod.ClojureWasmError.NotImplemented,
        assoc(&fix.rt, tm, Value.initInteger(999), Value.initInteger(999), loc),
    );
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
        error_mod.ClojureWasmError.ValueError,
        assoc(&fix.rt, tm, Value.initInteger(1), Value.initInteger(1), loc),
    );
}
