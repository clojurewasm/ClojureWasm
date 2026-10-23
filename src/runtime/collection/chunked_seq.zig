// SPDX-License-Identifier: EPL-2.0
//! The IChunkedSeq boundary: one place that answers "is this seq chunked, and
//! what is its current chunk" for every chunked representation (ADR-0205).
//!
//! clj has two native chunked seqs that matter here: `ChunkedCons` (range,
//! chunk-aware map/filter output) and `PersistentVector$ChunkedSeq` (the seq of
//! a vector, whose chunk is the 32-element leaf array holding the cursor). cljw
//! represents the first as `.chunked_cons` and the second as an `.array_seq`
//! view over a `.vector`. Before this module only `.chunked_cons` answered
//! `chunked-seq?`, so `(map f v)` over a vector realized one element per lazy
//! node while the JVM realizes a whole leaf at a time: an observable laziness
//! divergence (side-effecting `f`) and a 5x slowdown.
//!
//! Chunk geometry follows clj exactly: a vector seq at index `i` exposes the
//! leaf containing `i`, from `i` to the leaf end (`(i | 31) + 1`, bounded by
//! count), so the chunks are leaf-aligned whatever index the walk started at.
//! An array_seq over a `.sub_vector` or a Java array stays unchunked: clj's
//! `APersistentVector$Seq` (subvec) and `ArraySeq` (arrays) are not
//! IChunkedSeq.
//!
//! GC: `chunkRest` performs at most one allocation (an array_seq view) and
//! stores only the receiver's backing, which the caller roots through the
//! receiver. No fabrication bracket is needed for a single-alloc builder.

const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const chunked_cons = @import("chunked_cons.zig");
const array_seq = @import("array_seq.zig");
const vector = @import("vector.zig");

/// Elements per vector leaf (PersistentVector branching factor).
const LEAF: u32 = 32;

fn isVectorView(v: Value) bool {
    return v.tag() == .array_seq and array_seq.backingOf(v).tag() == .vector;
}

/// `chunked-seq?`: true for a chunked_cons and for the seq of a vector.
pub fn isChunked(v: Value) bool {
    return v.tag() == .chunked_cons or isVectorView(v);
}

/// End index (exclusive) of the leaf chunk holding the view's cursor.
fn leafEnd(v: Value) u32 {
    const i = array_seq.indexOf(v);
    const n = vector.count(array_seq.backingOf(v));
    const end = (i | (LEAF - 1)) + 1;
    return if (end < n) end else n;
}

/// Element count of the current chunk from the read cursor; 0 when `v` is not
/// chunked.
pub fn chunkCount(v: Value) u32 {
    if (v.tag() == .chunked_cons) return chunked_cons.currentChunkCount(v);
    if (isVectorView(v)) return leafEnd(v) - array_seq.indexOf(v);
    return 0;
}

/// Element `i` (relative to the cursor) of the current chunk. Callers satisfy
/// `i < chunkCount(v)`.
pub fn chunkNth(v: Value, i: u32) Value {
    if (v.tag() == .chunked_cons) return chunked_cons.currentChunkNth(v, i);
    if (isVectorView(v)) return vector.nth(array_seq.backingOf(v), array_seq.indexOf(v) + i);
    return Value.nil_val;
}

/// The seq after the WHOLE current chunk (clj `chunk-rest` minus the empty
/// list lift: nil at the end, which every caller seqs anyway).
pub fn chunkRest(rt: *Runtime, v: Value) !Value {
    if (v.tag() == .chunked_cons) return chunked_cons.chunkRest(v);
    if (isVectorView(v)) return try array_seq.make(rt, array_seq.backingOf(v), leafEnd(v));
    return Value.nil_val;
}

// --- tests ---

const std = @import("std");
const testing = std.testing;

test "vector view chunks are leaf-aligned and bounded by count (ADR-0205)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    var items: [70]Value = undefined;
    for (&items, 0..) |*it, k| it.* = Value.initInteger(@intCast(k));
    const v = try vector.fromSlice(&rt, &items);

    const s0 = try array_seq.make(&rt, v, 0);
    try testing.expect(isChunked(s0));
    try testing.expectEqual(@as(u32, 32), chunkCount(s0));
    try testing.expectEqual(@as(i48, 31), chunkNth(s0, 31).asInteger());

    // A cursor mid-leaf exposes only the rest of that leaf.
    const s5 = try array_seq.make(&rt, v, 5);
    try testing.expectEqual(@as(u32, 27), chunkCount(s5));
    try testing.expectEqual(@as(i48, 5), chunkNth(s5, 0).asInteger());

    const r1 = try chunkRest(&rt, s5);
    try testing.expectEqual(@as(u32, 32), array_seq.indexOf(r1));
    const r2 = try chunkRest(&rt, r1);
    try testing.expectEqual(@as(u32, 6), chunkCount(r2)); // 64..70
    try testing.expect((try chunkRest(&rt, r2)).isNil());

    // Non-chunked shapes answer 0 / false.
    try testing.expect(!isChunked(Value.nil_val));
    try testing.expectEqual(@as(u32, 0), chunkCount(Value.initInteger(1)));
}
