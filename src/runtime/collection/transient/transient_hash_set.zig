// SPDX-License-Identifier: EPL-2.0
//! TransientHashSet — set scratch buffer that materialises into a
//! PersistentHashSet via `persistent!`. Phase 8 row 8.5 cycle 3
//! landing per D-074 + the survey-confirmed wrap shape (set =
//! map-with-sentinel-values, mirroring the persistent side).
//!
//! ## Shape
//!
//!   ```
//!   TransientHashSet { consumed, count, inner_map: Value, meta }
//!     └── inner_map : transient_map-tagged Value (TransientArrayMap)
//!   ```
//!
//! The set delegates all entry storage to a `TransientArrayMap`. Each
//! element `e` lives as a key with `Value.true_val` as the sentinel
//! value (same pattern PersistentHashSet uses). `conj!` adds via the
//! inner map's `assoc!`; `disj!` removes via the inner map's `dissoc!`.
//! `count` is re-read from the inner map after every mutation so the
//! transient surface mirrors what `(count)` would return on the
//! eventual persistent.

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
const set_mod = @import("../set.zig");
const map_mod = @import("../map.zig");
const transient_array_map = @import("transient_array_map.zig");

pub const TransientHashSet = extern struct {
    header: HeapHeader,
    consumed: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    count: u32 = 0,
    inner_map: Value = Value.nil_val,
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(TransientHashSet) >= 8);
        std.debug.assert(@offsetOf(TransientHashSet, "header") == 0);
    }
};

/// Build a TransientHashSet from a persistent hash_set source (or
/// `nil` → empty set). The source's backing map is copied into a
/// fresh TransientArrayMap; the new set wraps that inner transient.
pub fn fromSet(rt: *Runtime, source: Value) !Value {
    const inner_source: Value = if (source.isNil())
        Value.nil_val
    else
        source.decodePtr(*const set_mod.PersistentHashSet).map;

    const inner_tm = try transient_array_map.fromMap(rt, inner_source);

    const ts = try rt.gc.alloc(TransientHashSet);
    ts.* = .{
        .header = HeapHeader.init(.transient_set),
        .consumed = 0,
        .count = if (source.isNil()) 0 else source.decodePtr(*const set_mod.PersistentHashSet).count,
        .inner_map = inner_tm,
        .meta = if (source.isNil()) Value.nil_val else source.decodePtr(*const set_mod.PersistentHashSet).meta,
    };
    return Value.encodeHeapPtr(.transient_set, ts);
}

pub fn toPersistent(rt: *Runtime, ts_val: Value, loc: SourceLocation) !Value {
    const ts = try expectTransient(ts_val, "persistent!", loc);
    try ensureEditable(ts, "persistent!", loc);
    ts.consumed = 1;

    const persistent_map = try transient_array_map.toPersistent(rt, ts.inner_map, loc);

    const new_set = try rt.gc.alloc(set_mod.PersistentHashSet);
    new_set.* = .{
        .header = HeapHeader.init(.hash_set),
        .count = map_mod.count(persistent_map),
        .map = persistent_map,
        .meta = ts.meta,
    };
    return Value.encodeHeapPtr(.hash_set, new_set);
}

pub fn conj(rt: *Runtime, ts_val: Value, e: Value, loc: SourceLocation) !Value {
    const ts = try expectTransient(ts_val, "conj!", loc);
    try ensureEditable(ts, "conj!", loc);
    _ = try transient_array_map.assoc(rt, ts.inner_map, e, Value.true_val, loc);
    ts.count = transientMapCount(ts.inner_map);
    return ts_val;
}

pub fn disj(ts_val: Value, e: Value, loc: SourceLocation) !Value {
    const ts = try expectTransient(ts_val, "disj!", loc);
    try ensureEditable(ts, "disj!", loc);
    _ = try transient_array_map.dissoc(ts.inner_map, e, loc);
    ts.count = transientMapCount(ts.inner_map);
    return ts_val;
}

pub fn traceTransientHashSet(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ts: *TransientHashSet = @ptrCast(@alignCast(header));
    if (ts.inner_map.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ts.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.transient_set, &traceTransientHashSet);
}

// --- internals ---

fn expectTransient(v: Value, fn_name: []const u8, loc: SourceLocation) !*TransientHashSet {
    if (v.tag() != .transient_set) {
        return error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = fn_name,
            .expected = "transient_set",
            .actual = @tagName(v.tag()),
        });
    }
    return v.decodePtr(*TransientHashSet);
}

fn ensureEditable(ts: *TransientHashSet, fn_name: []const u8, loc: SourceLocation) !void {
    if (ts.consumed != 0) {
        return error_catalog.raise(.transient_used_after_persistent, loc, .{
            .fn_name = fn_name,
        });
    }
}

fn transientMapCount(tm_val: Value) u32 {
    if (tm_val.tag() != .transient_map) return 0;
    return tm_val.decodePtr(*const transient_array_map.TransientArrayMap).count;
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

test "TransientHashSet layout asserts" {
    try testing.expect(@offsetOf(TransientHashSet, "header") == 0);
    try testing.expect(@alignOf(TransientHashSet) >= 8);
}

test "fromSet on nil + persistent! returns empty hash_set" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const ts = try fromSet(&fix.rt, Value.nil_val);
    try testing.expect(ts.tag() == .transient_set);
    const p = try toPersistent(&fix.rt, ts, loc);
    try testing.expect(p.tag() == .hash_set);
    try testing.expectEqual(@as(u32, 0), set_mod.count(p));
}

test "conj! adds and persistent! produces a populated hash_set" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const ts = try fromSet(&fix.rt, Value.nil_val);
    _ = try conj(&fix.rt, ts, Value.initInteger(1), loc);
    _ = try conj(&fix.rt, ts, Value.initInteger(2), loc);
    _ = try conj(&fix.rt, ts, Value.initInteger(3), loc);
    const p = try toPersistent(&fix.rt, ts, loc);
    try testing.expectEqual(@as(u32, 3), set_mod.count(p));
    try testing.expect(try set_mod.contains(p, Value.initInteger(1)));
    try testing.expect(try set_mod.contains(p, Value.initInteger(2)));
    try testing.expect(try set_mod.contains(p, Value.initInteger(3)));
}

test "conj! is idempotent for duplicate elements" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const ts = try fromSet(&fix.rt, Value.nil_val);
    _ = try conj(&fix.rt, ts, Value.initInteger(7), loc);
    _ = try conj(&fix.rt, ts, Value.initInteger(7), loc);
    _ = try conj(&fix.rt, ts, Value.initInteger(7), loc);
    const p = try toPersistent(&fix.rt, ts, loc);
    try testing.expectEqual(@as(u32, 1), set_mod.count(p));
}

test "disj! removes an element" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const ts = try fromSet(&fix.rt, Value.nil_val);
    _ = try conj(&fix.rt, ts, Value.initInteger(1), loc);
    _ = try conj(&fix.rt, ts, Value.initInteger(2), loc);
    _ = try disj(ts, Value.initInteger(1), loc);
    const p = try toPersistent(&fix.rt, ts, loc);
    try testing.expectEqual(@as(u32, 1), set_mod.count(p));
    try testing.expect(!try set_mod.contains(p, Value.initInteger(1)));
    try testing.expect(try set_mod.contains(p, Value.initInteger(2)));
}

test "conj! after persistent! raises transient_used_after_persistent" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const ts = try fromSet(&fix.rt, Value.nil_val);
    _ = try toPersistent(&fix.rt, ts, loc);
    error_mod.clearLastError();
    try testing.expectError(
        error_mod.ClojureWasmError.ValueError,
        conj(&fix.rt, ts, Value.initInteger(1), loc),
    );
}
