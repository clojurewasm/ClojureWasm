// SPDX-License-Identifier: EPL-2.0
//! ArraySeq (A14) — an O(1) INDEXED VIEW seq over an indexed collection or
//! Java array, standing in for the JVM's family of indexed seq views.
//!
//! `(seq v)` / `(rest v)` / `(next v)` on a vector used to build an EAGER
//! `PersistentList` copy (`sequence.zig` `vectorToList` / `vectorTailAsList`):
//! n `Cons` allocations plus n trie descents per call, which measured
//! 2184-3549x slower than clj on `.dev/bench/scaling_form.edn`. Clojure never
//! copies — its seq over a vector is a VIEW holding `(vector, index)`. This is
//! that view: a fixed-size cell (backing + cursor + meta), allocated once per
//! step whatever the length, and no element is ever moved.
//!
//! Tag: A14 `.array_seq` was a day-1 reservation already declared across every
//! protocol table (`interface_membership.zig` ISeq / Sequential / Counted /
//! IHashEq / java.util.List / java.util.Collection) and already named in
//! `class_name.zig`, but had NO producer — `equal.zig`'s header anticipated
//! exactly this ("...when a producer mints those tags"). So this costs no slot
//! from `heap_tag.unallocated`: the address and its protocol membership were
//! already spent, only the producer was missing.
//!
//! ## Invariant: an ArraySeq is never empty
//!
//! `make` returns nil when `index >= count(backing)`, mirroring `.range`
//! ("empty → nil at construction, so a count-0 LongRange never exists").
//! That is what makes `first` total and lets `countOf` be a subtraction.
//!
//! ## Backings
//!
//! `backing` is typed as a `Value` and read through `backingCount` / `elementAt`
//! switches, so a producer is a new arm, not a new type (OCP): `.vector`,
//! `.sub_vector` and, since ADR-0197, `.array`. A Java array is MUTABLE, so a
//! view over one aliases storage a caller can still write and `(seq arr)`
//! reflects later `aset`s: exactly the JVM `ArraySeq` (which holds the array),
//! and the one backing for which this type's name is the JVM's own (AD-066).
//!
//! ## GC
//!
//! Unlike `.range` this holds a `Value` child, so it registers a trace fn.
//! `make` performs exactly ONE allocation and stores `backing` after it, so a
//! collect inside `alloc` must not sweep `backing` — every call site passes a
//! value already rooted by its own caller (`args[0]` of seq/rest/next, or the
//! receiver ArraySeq whose trace reaches the same backing). No fabrication
//! bracket is needed for a single-alloc builder. [ref: .dev/gc_rooting.md §A]

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const vector = @import("vector.zig");
const sub_vector = @import("sub_vector.zig");
const java_array = @import("java_array.zig");

/// ArraySeq (A14) — `backing` viewed from `index` to its end.
pub const ArraySeq = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    /// Read cursor into `backing`. Invariant: `index < backingCount(backing)`.
    index: u32 = 0,
    /// The viewed collection: immutable `.vector`/`.sub_vector`, or mutable
    /// `.array` (the view shares its backing storage).
    backing: Value = Value.nil_val,
    /// Optional metadata map. A seq is IObj on the JVM (`ASeq` implements it),
    /// so `(with-meta (seq v) m)` must round-trip; dropping it would regress
    /// the eager list this replaced, which carried meta for free.
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(ArraySeq) >= 8);
        std.debug.assert(@offsetOf(ArraySeq, "header") == 0);
    }
};

/// Element count of a viewable backing collection. A tag with no arm is not
/// viewable and answers 0, which makes `make` return nil rather than mint an
/// ArraySeq whose `first` would be undefined.
fn backingCount(backing: Value) u32 {
    return switch (backing.tag()) {
        .vector => vector.count(backing),
        .sub_vector => sub_vector.count(backing),
        .array => java_array.alength(backing),
        else => 0,
    };
}

/// `backing[i]` for a viewable backing. Callers must satisfy
/// `i < backingCount(backing)`; the ArraySeq invariant guarantees it. Boxing a
/// primitive array's `long` element may allocate.
fn elementAt(rt: *Runtime, backing: Value, i: u32) !Value {
    if (backing.tag() == .array) return java_array.get(rt, java_array.asArray(backing), i);
    return peekAt(backing, i).?;
}

/// `elementAt` without allocating: null for the one element that needs a
/// heap box (a primitive `long` outside the immediate range).
fn peekAt(backing: Value, i: u32) ?Value {
    return switch (backing.tag()) {
        .vector => vector.nth(backing, i),
        .sub_vector => sub_vector.nth(backing, i),
        .array => java_array.peek(java_array.asArray(backing), i),
        else => Value.nil_val,
    };
}

/// True when `seq` over this collection can be served as a view rather than a
/// copy. The one predicate producers consult, so adding a backing type is a
/// single arm in `backingCount`/`elementAt` plus this.
pub fn viewable(backing: Value) bool {
    return switch (backing.tag()) {
        .vector, .sub_vector, .array => true,
        else => false,
    };
}

/// View `backing` from `index`. nil when the view would be empty — an ArraySeq
/// is never empty (see the header invariant).
pub fn make(rt: *Runtime, backing: Value, index: u32) !Value {
    if (index >= backingCount(backing)) return Value.nil_val;
    const as = try rt.gc.alloc(ArraySeq);
    as.* = .{
        .header = HeapHeader.init(.array_seq),
        .index = index,
        .backing = backing,
    };
    return Value.encodeHeapPtr(.array_seq, as);
}

pub fn backingOf(v: Value) Value {
    return v.decodePtr(*const ArraySeq).backing;
}

pub fn indexOf(v: Value) u32 {
    return v.decodePtr(*const ArraySeq).index;
}

/// `(first as)` — total, by the never-empty invariant.
pub fn first(rt: *Runtime, v: Value) !Value {
    const as = v.decodePtr(*const ArraySeq);
    return elementAt(rt, as.backing, as.index);
}

/// `(count as)` — O(1): the backing's count minus the cursor. This is the
/// whole point of the `count` field a copy would have had to recompute.
pub fn countOf(v: Value) u32 {
    const as = v.decodePtr(*const ArraySeq);
    return backingCount(as.backing) - as.index;
}

/// `(nth as i)` — O(1) into the backing, no walk.
pub fn nth(rt: *Runtime, v: Value, i: u32) !Value {
    const as = v.decodePtr(*const ArraySeq);
    return elementAt(rt, as.backing, as.index + i);
}

/// `nth` for the rt-free paths (print, key hashing): null where the element
/// needs a heap box (see `peekAt`).
pub fn peekNth(v: Value, i: u32) ?Value {
    const as = v.decodePtr(*const ArraySeq);
    return peekAt(as.backing, as.index + i);
}

/// The primitive array an ArraySeq views, or null (a vector backing or an
/// object array).
pub fn primitiveBacking(v: Value) ?*const java_array.JavaArray {
    const b = v.decodePtr(*const ArraySeq).backing;
    if (b.tag() != .array or java_array.asArray(b).kind == .object) return null;
    return java_array.asArray(b);
}

/// `(rest as)` / `(next as)` — the same view one step along, or nil at the end.
/// Callers apply the `rest`/`next` empty-tail convention (`rest` lifts nil to
/// the empty list at its own exit, `next` keeps nil).
pub fn rest(rt: *Runtime, v: Value) !Value {
    const as = v.decodePtr(*const ArraySeq);
    return try make(rt, as.backing, as.index + 1);
}

/// Drop `n` elements in ONE step — `(nthrest as n)` without walking n cells.
pub fn drop(rt: *Runtime, v: Value, n: u32) !Value {
    const as = v.decodePtr(*const ArraySeq);
    return try make(rt, as.backing, as.index +| n);
}

pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const ArraySeq).meta;
}

/// `(with-meta as m)` — a fresh view over the same backing at the same cursor.
/// Not routed through `make`, which carries no meta and would re-check an
/// invariant the receiver already satisfies. Meta does NOT propagate to `rest`,
/// matching the JVM: `ASeq.next()` returns a seq without the receiver's meta.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const src = v.decodePtr(*const ArraySeq);
    const as = try rt.gc.alloc(ArraySeq);
    as.* = .{
        .header = HeapHeader.init(.array_seq),
        .index = src.index,
        .backing = src.backing,
        .meta = m,
    };
    return Value.encodeHeapPtr(.array_seq, as);
}

/// Per-tag trace fn — the `backing` and `meta` children.
pub fn traceArraySeq(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const as: *ArraySeq = @ptrCast(@alignCast(header));
    if (as.backing.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (as.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register the ArraySeq trace fn. Idempotent; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.array_seq, &traceArraySeq);
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

test "ArraySeq struct layout: HeapHeader at offset 0, 8-byte aligned" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(ArraySeq, "header"));
    try testing.expect(@alignOf(ArraySeq) >= 8);
    // 8-byte HeapHeader + cursor + backing + meta. Fixed size no matter how
    // many elements the view spans — that constancy, not the absolute number,
    // is what replaces the n-cell copy.
    try testing.expectEqual(@as(usize, 32), @sizeOf(ArraySeq));
    try testing.expectEqual(@as(usize, 16), @offsetOf(ArraySeq, "backing"));
}

test "make: never mints an empty view; count is backing minus cursor (O-058)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var items: [4]Value = .{
        Value.initInteger(10), Value.initInteger(20),
        Value.initInteger(30), Value.initInteger(40),
    };
    const v = try vector.fromSlice(&fix.rt, &items);

    // An empty view is nil, not a count-0 ArraySeq — the invariant that makes
    // `first` total. Both the past-the-end and the exactly-at-the-end cases.
    try testing.expect((try make(&fix.rt, v, 4)).isNil());
    try testing.expect((try make(&fix.rt, v, 99)).isNil());
    // An empty vector has no view at all.
    try testing.expect((try make(&fix.rt, vector.empty(), 0)).isNil());
    // A non-viewable backing answers nil rather than minting a view whose
    // `first` would be undefined.
    try testing.expect((try make(&fix.rt, Value.initInteger(1), 0)).isNil());

    const s = try make(&fix.rt, v, 0);
    try testing.expectEqual(Value.Tag.array_seq, s.tag());
    try testing.expectEqual(@as(u32, 4), countOf(s));
    try testing.expectEqual(@as(i48, 10), (try first(&fix.rt, s)).asInteger());
    try testing.expectEqual(@as(i48, 30), (try nth(&fix.rt, s, 2)).asInteger());

    // The cursor is subtracted from the backing count at every offset — a view
    // that reported the BACKING's count would pass at offset 0 and fail here.
    const s2 = try make(&fix.rt, v, 2);
    try testing.expectEqual(@as(u32, 2), countOf(s2));
    try testing.expectEqual(@as(i48, 30), (try first(&fix.rt, s2)).asInteger());
    try testing.expectEqual(@as(i48, 40), (try nth(&fix.rt, s2, 1)).asInteger());
    // The view shares the backing rather than copying it.
    try testing.expectEqual(@intFromEnum(v), @intFromEnum(backingOf(s2)));
    try testing.expectEqual(@as(u32, 2), indexOf(s2));
}

test "rest / drop advance the cursor and terminate at the end (O-058)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var items: [3]Value = .{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const v = try vector.fromSlice(&fix.rt, &items);
    const s = try make(&fix.rt, v, 0);

    const r1 = try rest(&fix.rt, s);
    try testing.expectEqual(@as(i48, 2), (try first(&fix.rt, r1)).asInteger());
    const r2 = try rest(&fix.rt, r1);
    try testing.expectEqual(@as(i48, 3), (try first(&fix.rt, r2)).asInteger());
    // One step past the last element is nil — the walk terminates exactly, and
    // `rest` never yields a count-0 view for a caller to `first`.
    try testing.expect((try rest(&fix.rt, r2)).isNil());

    // `drop` reaches the same place in one step as repeated `rest`.
    try testing.expectEqual(@as(i48, 3), (try first(&fix.rt, try drop(&fix.rt, s, 2))).asInteger());
    try testing.expect((try drop(&fix.rt, s, 3)).isNil());
    // A saturating add, so a huge n cannot wrap into a valid-looking cursor.
    try testing.expect((try drop(&fix.rt, s, std.math.maxInt(u32))).isNil());
}

test "withMeta: fresh view, same backing and cursor, meta not shared (O-058)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var items: [3]Value = .{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const v = try vector.fromSlice(&fix.rt, &items);
    const s = try make(&fix.rt, v, 1);
    try testing.expect(metaOf(s).isNil());

    const m = try vector.fromSlice(&fix.rt, &items); // any heap Value stands in
    const tagged = try withMeta(&fix.rt, s, m);
    try testing.expectEqual(@intFromEnum(m), @intFromEnum(metaOf(tagged)));
    // The VALUE is untouched: same backing, same cursor, same elements.
    try testing.expectEqual(@intFromEnum(v), @intFromEnum(backingOf(tagged)));
    try testing.expectEqual(@as(u32, 1), indexOf(tagged));
    try testing.expectEqual(@as(u32, 2), countOf(tagged));
    try testing.expectEqual(@as(i48, 2), (try first(&fix.rt, tagged)).asInteger());
    // The receiver is unchanged — with-meta is not a mutation.
    try testing.expect(metaOf(s).isNil());
    // Meta does not ride along to the tail (clj's ASeq.next()).
    try testing.expect(metaOf(try rest(&fix.rt, tagged)).isNil());
}

test "viewable gates the producers to immutable backings" {
    // A vector is viewable; a Java array is deliberately NOT (it is mutable —
    // see the header). Locking this keeps the "seq is a snapshot" property from
    // being relaxed by accident rather than by decision.
    var fix = RuntimeFixture.init();
    defer fix.deinit();
    var items: [1]Value = .{Value.initInteger(1)};
    try testing.expect(viewable(try vector.fromSlice(&fix.rt, &items)));
    try testing.expect(!viewable(Value.nil_val));
    try testing.expect(!viewable(Value.initInteger(3)));
}
