// SPDX-License-Identifier: EPL-2.0
//! LongRange (A12) — compact integer-range value: `{start, step, count}`.
//!
//! The performance finished-form for finite integer `(range …)` (ADR-0063,
//! O-001). Instead of a cons + lazy_seq per element (D-168's correct-but-slow
//! shape), a range is three scalars: element `i` is `start + i*step`, and the
//! length is the precomputed `count`. This gives O(1) `count`/`nth`/`first`
//! and a 0-allocation tight reduce loop (the loop lives in `reduceFn`,
//! Layer 2, using the accessors here — Layer 0 cannot call the fn vtable).
//!
//! Generic seq traversal (`map`/`doseq`/`first`+`rest` walking) goes through
//! `seqChunk`, which materialises ≤32 elements into the existing
//! `chunked_cons` machinery (JVM `LongRange` → `LongChunk`): one allocation
//! per 32 elements, not per element. So a range is a *producer* feeding the
//! one chunk mechanism (F-011), not a second iteration mechanism.
//!
//! Scope (ADR-0063, amended 2026-08-28): finite, integer (the full i64 Long
//! domain — an inline i48 OR a heap `big_int` origin `.long`), step≠0,
//! non-empty ranges. Empty → nil (D-164, no distinct empty-seq). Float /
//! step=0 / genuine-BigInt-bounded ranges stay the lazy `.clj` `range` body
//! (F-005-owner territory, F-003).
//! Elements and the virtual count project to a Value through the canonical
//! `promote.wrapI64` (completing D-165 for `.range`): a value past ±2^47
//! boxes as a heap Long — exact, class Long, never spilled to float.
//!
//! GC: a range owns no `Value` children, so NO trace fn is registered — the
//! `tag_trace_table[.range]` null entry is the finished-form-clean leaf case
//! (mark is null-safe; sweep is generic; no finaliser). This is deliberate,
//! not a forgotten hook.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const chunked_cons = @import("chunked_cons.zig");
const promote = @import("../numeric/promote.zig");
const big_int_mod = @import("../numeric/big_int.zig");

/// LongRange (A12). `count` is `i64` (not `u32`) so a range spanning the full
/// i48 element domain (~2.8e14 elements) cannot overflow the length field;
/// `countFn` wraps it through `initInteger` (i48-capped, D-165 sibling).
pub const LongRange = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// First element value (the head). `nth(i) = start + i*step`.
    start: i64,
    step: i64,
    /// Number of elements. Always ≥ 1 for a live range (empty → nil at
    /// construction, so a count-0 LongRange never exists).
    count: i64,

    comptime {
        std.debug.assert(@alignOf(LongRange) >= 8);
        std.debug.assert(@offsetOf(LongRange, "header") == 0);
    }
};

/// Number of elements in `[start, end)` stepped by `step` (step≠0), sign-aware
/// and clamped at 0. Mirrors JVM `LongRange.rangeCount`. `step == 0` is a
/// caller error (the producer gates it to the lazy `.clj` body — step-0 is an
/// infinite repeat, not a finite range).
pub fn boundsCount(start: i64, end: i64, step: i64) i64 {
    std.debug.assert(step != 0);
    // span is the signed distance to cover; divide by |step|, round up.
    if (step > 0) {
        if (end <= start) return 0;
        const span = end - start;
        return @divTrunc(span + step - 1, step);
    } else {
        if (end >= start) return 0;
        const span = start - end;
        const astep = -step;
        return @divTrunc(span + astep - 1, astep);
    }
}

/// Allocate a `.range` for `count` elements from `start` stepped by `step`.
/// `count ≤ 0` → nil (empty range ≡ nil, D-164). The caller guarantees
/// step≠0 and integer bounds.
pub fn make(rt: *Runtime, start: i64, step: i64, count: i64) !Value {
    if (count <= 0) return Value.nil_val;
    const r = try rt.gc.alloc(LongRange);
    r.* = .{
        .header = HeapHeader.init(.range),
        .start = start,
        .step = step,
        .count = count,
    };
    return Value.encodeHeapPtr(.range, r);
}

/// `(-range start end step)` producer: compute the count, then `make`.
pub fn fromBounds(rt: *Runtime, start: i64, end: i64, step: i64) !Value {
    return make(rt, start, step, boundsCount(start, end, step));
}

// --- accessors (the F-011 single source of range math) ---

pub fn countOf(v: Value) i64 {
    if (v.tag() != .range) return 0;
    return v.decodePtr(*const LongRange).count;
}

/// The element count as a Value — the user-facing `(count r)`. A range is a
/// virtual i64-domain value, so a count past i48 (a range wider than the i48
/// window — its bounds fit i48 but span more than 2^47 elements) boxes as a
/// heap Long through the same `wrapI64` lever the elements cross, never a
/// float. `countOf` stays the pure i64 accessor for internal bounds checks.
pub fn countValue(rt: *Runtime, v: Value) !Value {
    return promote.wrapI64(rt, countOf(v));
}

pub fn startOf(v: Value) i64 {
    return v.decodePtr(*const LongRange).start;
}

pub fn stepOf(v: Value) i64 {
    return v.decodePtr(*const LongRange).step;
}

/// The raw i64 of element `i` (0-based) — the one definition of the range's
/// element math (`start + i*step`). `elementAt` projects this to a (possibly
/// heap-Long) Value; the printer projects it straight to decimal text without
/// allocating. Caller bounds-checks against `countOf`.
pub fn elementI64(v: Value, i: i64) i64 {
    const r = v.decodePtr(*const LongRange);
    return r.start + i * r.step;
}

/// Element at index `i` (0-based) as a Value. Boxes through `wrapI64`: an
/// element past i48 is a heap Long (D-165), so this takes `rt` and is fallible
/// (the heap-Long alloc). Caller bounds-checks against `countOf`.
pub fn elementAt(rt: *Runtime, v: Value, i: i64) !Value {
    return promote.wrapI64(rt, elementI64(v, i));
}

/// Head element as a Value. A live range always has count ≥ 1.
pub fn first(rt: *Runtime, v: Value) !Value {
    return promote.wrapI64(rt, elementI64(v, 0));
}

/// Materialise the next ≤32 elements into a `chunked_cons` (JVM
/// `LongRange`→`LongChunk`): the chunk holds `min(32, count)` elements and its
/// `next` is the `.range` for the remainder (or nil). Generic seq traversal
/// (seq/rest/map/doseq) routes here so it pays one allocation per 32 elements
/// rather than per element. `count ≥ 1` is guaranteed (empty → nil upstream).
pub fn seqChunk(rt: *Runtime, v: Value) !Value {
    const r = v.decodePtr(*const LongRange);
    const n: u32 = @intCast(@min(@as(i64, chunked_cons.CHUNK_SIZE), r.count));

    // D-244 #4b: a multi-alloc builder — `cb` (the ChunkBuffer) is live-but-
    // UNROOTED across the later `make` (the `.range` tail) + `gc.alloc(ChunkedCons)`
    // allocations, so a collect THERE (alloc-torture, or ADR-0028 auto-collect)
    // would sweep `cb` → `cc.chunk` dangles → reads as nil (the
    // `(reduce + 0 (map inc (range N)))` → `(inc nil)` UAF). Bracket the whole
    // build in the fabrication no-collect region, like the vector/map/set/list
    // builders (ADR-0150 missed this range site). [ref: .dev/gc_rooting.md §A]
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();

    const cb = try rt.gc.alloc(chunked_cons.ChunkBuffer);
    cb.* = .{ .header = HeapHeader.init(.chunk_buffer), .count = n };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // wrapI64 may alloc a heap Long for an element past i48 — safe: the
        // whole build is inside the fabrication no-collect region above, so
        // the unrooted `cb` cannot be swept mid-fill (D-244 #4b).
        cb.slots[i] = try promote.wrapI64(rt, elementI64(v, @as(i64, i)));
    }

    const next: Value = if (r.count > chunked_cons.CHUNK_SIZE)
        try make(rt, r.start + @as(i64, chunked_cons.CHUNK_SIZE) * r.step, r.step, r.count - chunked_cons.CHUNK_SIZE)
    else
        Value.nil_val;

    const cc = try rt.gc.alloc(chunked_cons.ChunkedCons);
    cc.* = .{
        .header = HeapHeader.init(.chunked_cons),
        .offset = 0,
        .chunk = cb,
        .next = next,
    };
    return Value.encodeHeapPtr(.chunked_cons, cc);
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

test "boundsCount: positive / negative / empty / non-divisor step" {
    try testing.expectEqual(@as(i64, 3), boundsCount(0, 3, 1));
    try testing.expectEqual(@as(i64, 5), boundsCount(0, 10, 2));
    try testing.expectEqual(@as(i64, 3), boundsCount(1, 10, 3)); // 1,4,7
    try testing.expectEqual(@as(i64, 10), boundsCount(10, 0, -1));
    try testing.expectEqual(@as(i64, 5), boundsCount(10, 0, -2)); // 10,8,6,4,2
    try testing.expectEqual(@as(i64, 0), boundsCount(5, 5, 1));
    try testing.expectEqual(@as(i64, 0), boundsCount(5, 5, -1));
    try testing.expectEqual(@as(i64, 0), boundsCount(5, 3, 1)); // backwards, +step
}

test "make: empty range is nil; non-empty is a .range with O(1) count/nth" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    try testing.expect((try make(&fix.rt, 0, 1, 0)).isNil());

    const r = try make(&fix.rt, 0, 1, 5);
    try testing.expectEqual(@as(i64, 5), countOf(r));
    try testing.expectEqual(@as(i48, 0), (try first(&fix.rt, r)).asInteger());
    try testing.expectEqual(@as(i48, 3), (try elementAt(&fix.rt, r, 3)).asInteger());
    try testing.expectEqual(@as(i48, 4), (try elementAt(&fix.rt, r, 4)).asInteger());
}

test "elementAt/first box an element past i48 as a heap Long, not a float" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // start past ±2^47 → every element is a heap Long (big_int origin .long).
    const base: i64 = @as(i64, 1) << 55; // 36028797018963968
    const r = try make(&fix.rt, base, 1, 4);

    const e0 = try first(&fix.rt, r);
    try testing.expectEqual(value_mod.Value.Tag.big_int, e0.tag());
    try testing.expectEqual(base, try big_int_mod.toI64(e0));
    try testing.expectEqual(big_int_mod.IntOrigin.long, big_int_mod.originOf(e0));

    const e3 = try elementAt(&fix.rt, r, 3);
    try testing.expectEqual(base + 3, try big_int_mod.toI64(e3));

    // a range that CROSSES the i48 boundary: the low elements stay inline
    // `.integer`, the ones past i48-max become heap Longs.
    const i48_max: i64 = (@as(i64, 1) << 47) - 1; // 140737488355327
    const cross = try make(&fix.rt, i48_max - 1, 1, 4); // max-1, max, max+1, max+2
    try testing.expectEqual(value_mod.Value.Tag.integer, (try elementAt(&fix.rt, cross, 0)).tag());
    try testing.expectEqual(value_mod.Value.Tag.integer, (try elementAt(&fix.rt, cross, 1)).tag());
    try testing.expectEqual(value_mod.Value.Tag.big_int, (try elementAt(&fix.rt, cross, 2)).tag());
    try testing.expectEqual(i48_max + 2, try big_int_mod.toI64(try elementAt(&fix.rt, cross, 3)));
}

test "countValue boxes a virtual count past i48 as a heap Long, not a float" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // a small count stays inline `.integer`.
    const small = try make(&fix.rt, 0, 1, 5);
    try testing.expectEqual(value_mod.Value.Tag.integer, (try countValue(&fix.rt, small)).tag());

    // a range wider than 2^47 (bounds fit i48, but the SPAN does not) has a
    // virtual count past i48 → heap-Long count, exact (the D-165 count-spill
    // the DA flagged: `(count (range huge-span))` must not float).
    const wide = try make(&fix.rt, 0, 1, @as(i64, 1) << 48);
    const cv = try countValue(&fix.rt, wide);
    try testing.expectEqual(value_mod.Value.Tag.big_int, cv.tag());
    try testing.expectEqual(@as(i64, 1) << 48, try big_int_mod.toI64(cv));
}

test "fromBounds matches boundsCount + element math" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const r = try fromBounds(&fix.rt, 2, 5, 1); // (2 3 4)
    try testing.expectEqual(@as(i64, 3), countOf(r));
    try testing.expectEqual(@as(i48, 2), (try elementAt(&fix.rt, r, 0)).asInteger());
    try testing.expectEqual(@as(i48, 4), (try elementAt(&fix.rt, r, 2)).asInteger());

    const neg = try fromBounds(&fix.rt, 10, 0, -2); // (10 8 6 4 2)
    try testing.expectEqual(@as(i64, 5), countOf(neg));
    try testing.expectEqual(@as(i48, 10), (try first(&fix.rt, neg)).asInteger());
    try testing.expectEqual(@as(i48, 2), (try elementAt(&fix.rt, neg, 4)).asInteger());
}

test "seqChunk: <=32 in one chunk, next nil; >32 chains to a smaller range" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const small = try make(&fix.rt, 0, 1, 5);
    const c1 = try seqChunk(&fix.rt, small);
    try testing.expectEqual(@as(u32, 5), chunked_cons.count(c1));
    try testing.expectEqual(@as(i48, 0), chunked_cons.first(c1).asInteger());

    const big = try make(&fix.rt, 0, 1, 40);
    const c2 = try seqChunk(&fix.rt, big);
    // chunk holds 32; chunked_cons.count walks chunk(32) + next is a .range
    // (NOT a chunked_cons) so the chain count stops at the chunk boundary.
    const cc = c2.decodePtr(*const chunked_cons.ChunkedCons);
    try testing.expectEqual(@as(u32, 32), cc.chunk.?.count);
    try testing.expectEqual(@as(i64, 8), countOf(cc.next)); // remainder range
    try testing.expectEqual(@as(i48, 32), (try first(&fix.rt, cc.next)).asInteger());
}
