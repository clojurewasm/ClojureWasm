// SPDX-License-Identifier: EPL-2.0
//! SubVector (D11 `.sub_vector`) — an O(1) index-range VIEW into a
//! PersistentVector, a first-class IPersistentVector standing in for the
//! JVM's `clojure.lang.APersistentVector$SubVector`.
//!
//! `(subvec v start end)` used to eager-copy `end - start` elements through
//! repeated conj (measured 7480x slower than clj at n=16000). Clojure never
//! copies — `subvec` is O(1) and shares the parent's structure. This is that
//! view: a fixed 32-byte cell `{start, end, parent, meta}` whatever the span.
//!
//! ## Invariants
//!
//! - `parent` is ALWAYS a plain `.vector`. Constructing a view whose parent is
//!   itself a `.sub_vector` FLATTENS one level (offsets added, grandparent
//!   adopted), exactly as `APersistentVector.SubVector`'s constructor does, so
//!   every consumer's parent access is single-hop.
//! - A `.sub_vector` is NEVER empty. `make` returns the EMPTY plain vector when
//!   `start == end` (matching `RT.subvec`), so `count >= 1` always holds and
//!   `first`/`peek` are total.
//!
//! ## Ops (all via the parent, JVM SubVector semantics)
//!
//! - `count = end - start` (O(1)); `nth(i) = parent.nth(start + i)`.
//! - Write ops stay SubVectors — they never materialize:
//!   `conj(x) = SubVector(parent.assocN(end, x), start, end+1)`,
//!   `assoc(i,x) = SubVector(parent.assocN(start+i, x), start, end)` (i==count ⇒
//!   conj), `pop() = end-1==start ? EMPTY : SubVector(parent, start, end-1)`.
//!   `parent.assocN` at index == parent.count appends; below it copy-on-writes
//!   the one slot in a fresh parent (structural sharing).
//! - `seq`/`rest`/`next` route through `array_seq` (its backing switches carry a
//!   `.sub_vector` arm), so a subvec's seq is an O(1) indexed view too.
//!
//! ## GC
//!
//! Holds two `Value` children (`parent`, `meta`); registers a trace fn. The
//! write ops compute a fresh parent before allocating the view cell, so they
//! run inside a fabrication region (ADR-0150) — the fresh parent is unrooted
//! across the view alloc. `make`/`withMeta` are single-alloc builders whose
//! `parent`/`meta` are rooted by the caller's frame, so they need no bracket
//! (same reasoning as `array_seq.make`). [ref: .dev/gc_rooting.md §A]

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const vector = @import("vector.zig");

/// SubVector (D11) — `parent` viewed over the half-open index range
/// `[start, end)`. `parent` is always a plain `.vector` (flattened on nest).
pub const SubVector = extern struct {
    header: HeapHeader,
    /// First parent index in the view (inclusive).
    start: u32 = 0,
    /// One past the last parent index in the view (exclusive).
    /// Invariant: `end > start` — a live SubVector is never empty.
    end: u32 = 0,
    /// The viewed vector — always a `.vector`, never a `.sub_vector`.
    parent: Value = Value.nil_val,
    /// Optional metadata map (IObj; `with-meta` round-trips).
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(SubVector) >= 8);
        std.debug.assert(@offsetOf(SubVector, "header") == 0);
    }
};

/// `(subvec v start end)` — the O(1) view. `start`/`end` must already satisfy
/// `0 <= start <= end <= count(v)` (the `clojure.core/subvec` wrapper bounds-
/// checks and throws `IndexOutOfBoundsException`). Flattens a `.sub_vector`
/// parent; returns the EMPTY plain vector for an empty range so a live view is
/// never empty.
// PERF: O(1) view over the parent vs the eager take/drop rebuild [refs: O-059, D-583]
pub fn make(rt: *Runtime, parent: Value, start: u32, end: u32) !Value {
    var p = parent;
    var s = start;
    var e = end;
    if (p.tag() == .sub_vector) {
        const sp = p.decodePtr(*const SubVector);
        s += sp.start;
        e += sp.start;
        p = sp.parent;
    }
    if (s == e) return vector.empty();
    return makeRaw(rt, p, s, e, Value.nil_val);
}

/// Allocate a view cell over an already-plain, non-empty range. `parent` must
/// be a `.vector` and `end > start`. Used by `make` and the write ops (which
/// preserve meta and keep a plain parent).
fn makeRaw(rt: *Runtime, parent: Value, start: u32, end: u32, meta: Value) !Value {
    std.debug.assert(parent.tag() == .vector);
    std.debug.assert(end > start);
    const sv = try rt.gc.alloc(SubVector);
    sv.* = .{
        .header = HeapHeader.init(.sub_vector),
        .start = start,
        .end = end,
        .parent = parent,
        .meta = meta,
    };
    return Value.encodeHeapPtr(.sub_vector, sv);
}

pub fn parentOf(v: Value) Value {
    return v.decodePtr(*const SubVector).parent;
}

pub fn startOf(v: Value) u32 {
    return v.decodePtr(*const SubVector).start;
}

pub fn endOf(v: Value) u32 {
    return v.decodePtr(*const SubVector).end;
}

/// `(count sv)` — O(1).
pub fn count(v: Value) u32 {
    const sv = v.decodePtr(*const SubVector);
    return sv.end - sv.start;
}

/// `(nth sv i)` — O(log32 n) into the parent, no walk of the view. Out-of-range
/// `i` returns nil (matching `vector.nth`), NOT a parent element past the view.
pub fn nth(v: Value, i: u32) Value {
    const sv = v.decodePtr(*const SubVector);
    if (i >= sv.end - sv.start) return Value.nil_val;
    return vector.nth(sv.parent, sv.start + i);
}

/// `(first sv)` / `(peek sv)` — total by the never-empty invariant.
pub fn first(v: Value) Value {
    const sv = v.decodePtr(*const SubVector);
    return vector.nth(sv.parent, sv.start);
}

pub fn peek(v: Value) Value {
    const sv = v.decodePtr(*const SubVector);
    return vector.nth(sv.parent, sv.end - 1);
}

/// `(conj sv x)` — append at the view's logical end. `parent.assocN(end, x)`
/// appends when the view sits at the parent's live end, else copy-on-writes the
/// one slot beyond the view (structural sharing). Result stays a SubVector.
pub fn conj(rt: *Runtime, v: Value, x: Value) !Value {
    // The fresh parent from `vector.assoc` is unrooted across the view alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const sv = v.decodePtr(*const SubVector);
    const start = sv.start;
    const end = sv.end;
    const meta = sv.meta;
    const new_parent = try vector.assoc(rt, sv.parent, end, x);
    return makeRaw(rt, new_parent, start, end + 1, meta);
}

/// `(assoc sv i x)` — replace the view's `i`-th element; `i == count` appends
/// (conj). `i > count` is `error.AssocOutOfBounds`.
pub fn assoc(rt: *Runtime, v: Value, i: u32, x: Value) !Value {
    const sv0 = v.decodePtr(*const SubVector);
    if (i == sv0.end - sv0.start) return try conj(rt, v, x);
    if (i > sv0.end - sv0.start) return error.AssocOutOfBounds;
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const sv = v.decodePtr(*const SubVector);
    const start = sv.start;
    const end = sv.end;
    const meta = sv.meta;
    const new_parent = try vector.assoc(rt, sv.parent, start + i, x);
    return makeRaw(rt, new_parent, start, end, meta);
}

/// `(pop sv)` — drop the last element. A one-element view pops to the EMPTY
/// plain vector (JVM `SubVector.pop`). `error.PopEmpty` on a (never-occurring)
/// empty view, kept for parity with `vector.pop`'s contract.
pub fn pop(rt: *Runtime, v: Value) !Value {
    const sv = v.decodePtr(*const SubVector);
    if (sv.end <= sv.start) return error.PopEmpty;
    if (sv.end - 1 == sv.start) return vector.empty();
    return makeRaw(rt, sv.parent, sv.start, sv.end - 1, sv.meta);
}

/// Metadata of the view (or nil).
pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const SubVector).meta;
}

/// `(with-meta sv m)` — a fresh view over the same parent/range, meta set.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const sv = v.decodePtr(*const SubVector);
    return makeRaw(rt, sv.parent, sv.start, sv.end, m);
}

/// Per-tag trace fn — the `parent` and `meta` children.
pub fn traceSubVector(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const sv: *SubVector = @ptrCast(@alignCast(header));
    if (sv.parent.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (sv.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register the SubVector trace fn. Idempotent; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.sub_vector, &traceSubVector);
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

fn vecOf(rt: *Runtime, comptime n: u32) !Value {
    var items: [n]Value = undefined;
    for (0..n) |i| items[i] = Value.initInteger(@intCast(i));
    return vector.fromSlice(rt, &items);
}

test "SubVector struct layout: header at offset 0, 8-byte aligned, 32 bytes" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(SubVector, "header"));
    try testing.expect(@alignOf(SubVector) >= 8);
    try testing.expectEqual(@as(usize, 32), @sizeOf(SubVector));
    try testing.expectEqual(@as(usize, 16), @offsetOf(SubVector, "parent"));
}

test "make: inner range shares parent, count and nth are the view's" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 10);

    const sv = try make(&fix.rt, v, 2, 7);
    try testing.expectEqual(Value.Tag.sub_vector, sv.tag());
    try testing.expectEqual(@as(u32, 5), count(sv));
    try testing.expectEqual(@as(i48, 2), nth(sv, 0).asInteger());
    try testing.expectEqual(@as(i48, 6), nth(sv, 4).asInteger());
    // Past the view end is nil, NOT parent[7].
    try testing.expect(nth(sv, 5).isNil());
    // Shares the parent, does not copy it.
    try testing.expectEqual(@intFromEnum(v), @intFromEnum(parentOf(sv)));
    try testing.expectEqual(@as(i48, 2), first(sv).asInteger());
    try testing.expectEqual(@as(i48, 6), peek(sv).asInteger());
}

test "make: empty range is the EMPTY plain vector, never an empty view" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 5);

    const sv = try make(&fix.rt, v, 3, 3);
    try testing.expectEqual(Value.Tag.vector, sv.tag());
    try testing.expectEqual(@as(u32, 0), vector.count(sv));
}

test "make: nested subvec FLATTENS to the grandparent with added offsets" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 20);

    const outer = try make(&fix.rt, v, 5, 15); // [5..15) -> 10 elems
    const inner = try make(&fix.rt, outer, 2, 6); // [2..6) of outer -> parent [7..11)
    try testing.expectEqual(Value.Tag.sub_vector, inner.tag());
    // Parent is the ORIGINAL vector, not `outer`.
    try testing.expectEqual(@intFromEnum(v), @intFromEnum(parentOf(inner)));
    try testing.expectEqual(@as(u32, 7), startOf(inner));
    try testing.expectEqual(@as(u32, 11), endOf(inner));
    try testing.expectEqual(@as(u32, 4), count(inner));
    try testing.expectEqual(@as(i48, 7), nth(inner, 0).asInteger());
    try testing.expectEqual(@as(i48, 10), nth(inner, 3).asInteger());
}

test "conj: appends at the view end, stays a SubVector, parent untouched" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 10);
    const sv = try make(&fix.rt, v, 2, 7); // [2 3 4 5 6]

    const c = try conj(&fix.rt, sv, Value.initInteger(99));
    try testing.expectEqual(Value.Tag.sub_vector, c.tag());
    try testing.expectEqual(@as(u32, 6), count(c));
    try testing.expectEqual(@as(i48, 2), nth(c, 0).asInteger());
    try testing.expectEqual(@as(i48, 99), nth(c, 5).asInteger());
    // The original view and parent are unchanged (COW).
    try testing.expectEqual(@as(u32, 5), count(sv));
    try testing.expectEqual(@as(i48, 7), vector.nth(v, 7).asInteger());
}

test "conj at the parent's live end appends onto the parent (no overwrite)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 5); // [0 1 2 3 4]
    const sv = try make(&fix.rt, v, 1, 5); // view sits at the parent's end

    const c = try conj(&fix.rt, sv, Value.initInteger(42));
    try testing.expectEqual(@as(u32, 5), count(c)); // [1 2 3 4 42]
    try testing.expectEqual(@as(i48, 1), nth(c, 0).asInteger());
    try testing.expectEqual(@as(i48, 42), nth(c, 4).asInteger());
}

test "assoc: in-range replace and append-at-count (= conj)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 10);
    const sv = try make(&fix.rt, v, 2, 7); // [2 3 4 5 6]

    const a = try assoc(&fix.rt, sv, 0, Value.initInteger(-1));
    try testing.expectEqual(Value.Tag.sub_vector, a.tag());
    try testing.expectEqual(@as(u32, 5), count(a));
    try testing.expectEqual(@as(i48, -1), nth(a, 0).asInteger());
    try testing.expectEqual(@as(i48, 6), nth(a, 4).asInteger());
    // assoc at count appends.
    const a2 = try assoc(&fix.rt, sv, 5, Value.initInteger(77));
    try testing.expectEqual(@as(u32, 6), count(a2));
    try testing.expectEqual(@as(i48, 77), nth(a2, 5).asInteger());
    // out of bounds
    try testing.expectError(error.AssocOutOfBounds, assoc(&fix.rt, sv, 6, Value.nil_val));
    // Original unchanged.
    try testing.expectEqual(@as(i48, 2), nth(sv, 0).asInteger());
}

test "pop: shrinks the view; a one-element view pops to EMPTY" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 10);
    const sv = try make(&fix.rt, v, 2, 7); // [2 3 4 5 6]

    const p = try pop(&fix.rt, sv);
    try testing.expectEqual(Value.Tag.sub_vector, p.tag());
    try testing.expectEqual(@as(u32, 4), count(p)); // [2 3 4 5]
    try testing.expectEqual(@as(i48, 5), nth(p, 3).asInteger());
    try testing.expect(nth(p, 4).isNil());

    const one = try make(&fix.rt, v, 4, 5); // [4]
    const empty_pop = try pop(&fix.rt, one);
    try testing.expectEqual(Value.Tag.vector, empty_pop.tag());
    try testing.expectEqual(@as(u32, 0), vector.count(empty_pop));
}

test "withMeta: fresh view, same parent/range, meta set; receiver untouched" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    const v = try vecOf(&fix.rt, 10);
    const sv = try make(&fix.rt, v, 2, 7);
    try testing.expect(metaOf(sv).isNil());

    const m = try vecOf(&fix.rt, 1); // any heap Value stands in
    const tagged = try withMeta(&fix.rt, sv, m);
    try testing.expectEqual(@intFromEnum(m), @intFromEnum(metaOf(tagged)));
    try testing.expectEqual(@intFromEnum(v), @intFromEnum(parentOf(tagged)));
    try testing.expectEqual(@as(u32, 5), count(tagged));
    try testing.expect(metaOf(sv).isNil());
}
