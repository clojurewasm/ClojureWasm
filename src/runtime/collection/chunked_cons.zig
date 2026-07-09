// SPDX-License-Identifier: EPL-2.0
//! ChunkedCons + ChunkBuffer — chunked lazy-seq backing per ROADMAP
//! §9.7 row 5.8 + ADR-0027 §2 Group A (A10 = chunked_cons, A11 =
//! chunk_buffer).
//!
//! ## Why chunked?
//!
//! Clojure's `(range)`, `(map f coll)`, etc. produce sequences that
//! callers consume one element at a time. A naive `Cons` chain
//! allocates one cell per element — bad for `(reduce + (range 1e6))`
//! which would create 1M Cons cells. ChunkedCons amortises the
//! allocation: a 32-element `ChunkBuffer` (one cache line × 4 worth)
//! holds 32 consecutive realised values; `ChunkedCons` is a tiny
//! header that points at the chunk + an offset + the next
//! ChunkedCons. So 1M elements need ~31K ChunkedCons cells + ~31K
//! ChunkBuffer cells = 60K allocations, not 1M.
//!
//! ## Shapes
//!
//! - `ChunkBuffer` (A11) — extern struct with `count: u32 + slots:
//!   [32]Value`. Mutable during construction (range / map fill the
//!   chunk slot-by-slot before sealing); immutable after publishing
//!   as a `ChunkedCons.chunk` pointer.
//! - `ChunkedCons` (A10) — extern struct with `header + offset: u32
//!   + chunk: *ChunkBuffer + next: Value`. `count(cc)` = chunk.count -
//!   offset + count(next). `first(cc)` = chunk.slots[offset].
//!   `rest(cc)` = either a new ChunkedCons with offset+1 (within
//!   chunk) or `next` (chunk exhausted).
//!
//! These shapes back the range + lazy-seq realisation paths (the
//! chunk-builder surface; ADR-0065 / D-163).

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const HeapTag = value_mod.HeapTag;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Chunk size — 32 elements per ChunkBuffer. Matches the JVM
/// PersistentVector / PersistentHashMap branching factor; one
/// cache-line-friendly chunk amortises allocation across 32 values.
pub const CHUNK_SIZE: u32 = 32;

/// ChunkBuffer (A11) — 32-slot mutable-during-construction array.
/// Once published as a `ChunkedCons.chunk` pointer, treat as
/// immutable (sharing is structural). `count` tracks the populated
/// prefix; the chunk is "full" when count == CHUNK_SIZE.
pub const ChunkBuffer = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    count: u32 = 0,
    slots: [CHUNK_SIZE]Value = @splat(Value.nil_val),

    comptime {
        std.debug.assert(@alignOf(ChunkBuffer) >= 8);
        std.debug.assert(@offsetOf(ChunkBuffer, "header") == 0);
    }
};

/// ChunkedCons (A10) — chunked seq cell. `offset` is the read-cursor
/// within `chunk.slots[offset..count]`; `next` is the continuation
/// (typically another ChunkedCons or a LazySeq for unrealised tail,
/// nil for end-of-seq).
pub const ChunkedCons = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    /// Read cursor within `chunk.slots`. Valid range: [0, chunk.count).
    offset: u32 = 0,
    /// Backing chunk pointer. Encoded as a raw pointer (not a Value)
    /// because ChunkBuffer lives on the GC heap alongside ChunkedCons
    /// and the trace fn walks it via `@ptrCast` rather than Value
    /// decode.
    chunk: ?*ChunkBuffer = null,
    /// Continuation seq — another ChunkedCons / LazySeq / Cons / nil.
    next: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(ChunkedCons) >= 8);
        std.debug.assert(@offsetOf(ChunkedCons, "header") == 0);
    }
};

/// `count(v)` — total remaining element count across this chunk +
/// every subsequent chunk in `next`. Walks the chunk chain
/// iteratively (not recursive on next — handles long chains
/// without stack pressure).
pub fn count(v: Value) u32 {
    if (v.tag() != .chunked_cons) return 0;
    var total: u32 = 0;
    var current = v;
    while (current.tag() == .chunked_cons) {
        const cc = current.decodePtr(*const ChunkedCons);
        const c = cc.chunk orelse break;
        total += c.count - cc.offset;
        current = cc.next;
    }
    return total;
}

/// `first(v)` — current head element at `chunk.slots[offset]`. Returns
/// nil when the cursor has advanced past the chunk's count (which
/// should not happen if `rest` is used correctly to roll into `next`).
pub fn first(v: Value) Value {
    if (v.tag() != .chunked_cons) return Value.nil_val;
    const cc = v.decodePtr(*const ChunkedCons);
    const c = cc.chunk orelse return Value.nil_val;
    if (cc.offset >= c.count) return Value.nil_val;
    return c.slots[cc.offset];
}

/// `rest(rt, v)` — advance the cursor by 1. If the chunk still has
/// values past the new cursor, returns a fresh ChunkedCons pointing
/// at the same chunk with `offset + 1`. If the chunk is exhausted,
/// returns `next` (which may itself be a ChunkedCons, LazySeq, Cons,
/// or nil).
pub fn rest(rt: *Runtime, v: Value) !Value {
    if (v.tag() != .chunked_cons) return Value.nil_val;
    const cc = v.decodePtr(*const ChunkedCons);
    const c = cc.chunk orelse return Value.nil_val;
    if (cc.offset + 1 >= c.count) return cc.next;

    // The input cursor is routinely a Zig local on NO root — a fresh
    // `range.seqChunk` result (`(rest (range n))`), or a seq-walk cursor
    // being advanced in a loop. A collect inside THIS alloc would sweep the
    // shared ChunkBuffer and the input cell, leaving `new_cc.chunk` dangling
    // (reads recycled memory — the rush-hour BFS corruption class).
    // Bracket the single alloc in the ADR-0150 fabrication no-collect region
    // (pure Zig, bounded, no eval reentry) so the advance is atomic w.r.t.
    // collection; the caller publishes the result before its next alloc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const new_cc = try rt.gc.alloc(ChunkedCons);
    new_cc.* = .{
        .header = HeapHeader.init(.chunked_cons),
        .offset = cc.offset + 1,
        .chunk = cc.chunk,
        .next = cc.next,
    };
    return Value.encodeHeapPtr(.chunked_cons, new_cc);
}

// --- chunk-builder surface (ADR-0065, D-163) ------------------------
// Thin primitives that let the `.clj` `map`/`filter`/`keep`/`remove`
// bodies preserve chunking (JVM `chunk-cons` shape): a chunked source is
// transformed one whole 32-chunk at a time into a fresh chunk, so the
// per-element lazy-seq machinery (cons + lazy_seq alloc + body tree-walk,
// ~408µs/element measured) is paid once per 32 elements instead of once
// per element. The fill loop stays in `.clj` (cljw measured a tree-walk
// loop at ~2µs/iter — negligible vs the 408µs it amortises).

/// `chunked-seq?` — is `v` a chunked_cons (eligible for the fast path)?
pub fn isChunked(v: Value) bool {
    return v.tag() == .chunked_cons;
}

/// `-chunk-count` — element count of `v`'s CURRENT chunk from the read
/// cursor (`chunk.count - offset`); 0 for non-chunked / exhausted.
pub fn currentChunkCount(v: Value) u32 {
    if (v.tag() != .chunked_cons) return 0;
    const cc = v.decodePtr(*const ChunkedCons);
    const c = cc.chunk orelse return 0;
    if (cc.offset >= c.count) return 0;
    return c.count - cc.offset;
}

/// `-chunk-nth` — element `i` (relative to the read cursor) of `v`'s
/// current chunk: `chunk.slots[offset + i]`.
pub fn currentChunkNth(v: Value, i: u32) Value {
    if (v.tag() != .chunked_cons) return Value.nil_val;
    const cc = v.decodePtr(*const ChunkedCons);
    const c = cc.chunk orelse return Value.nil_val;
    const idx = cc.offset + i;
    if (idx >= c.count) return Value.nil_val;
    return c.slots[idx];
}

/// `chunk-rest` — the seq after `v`'s ENTIRE current chunk (= `next`,
/// skipping the whole chunk). The chunk-preserving counterpart to `rest`.
pub fn chunkRest(v: Value) Value {
    if (v.tag() != .chunked_cons) return Value.nil_val;
    return v.decodePtr(*const ChunkedCons).next;
}

/// `chunk-buffer` — a fresh empty ChunkBuffer to fill via `chunk-append`
/// (≤ CHUNK_SIZE appends; the backing array is always CHUNK_SIZE).
pub fn newChunkBuffer(rt: *Runtime) !Value {
    const cb = try rt.gc.alloc(ChunkBuffer);
    cb.* = .{ .header = HeapHeader.init(.chunk_buffer), .count = 0 };
    return Value.encodeHeapPtr(.chunk_buffer, cb);
}

/// `chunk-append` — push `x` into the buffer's next slot, return the
/// buffer (mutated in place during construction).
pub fn chunkAppend(bufv: Value, x: Value) Value {
    const cb = bufv.decodePtr(*ChunkBuffer);
    cb.slots[cb.count] = x;
    cb.count += 1;
    return bufv;
}

/// `chunk-cons` — wrap a filled ChunkBuffer + continuation seq into a
/// chunked_cons (offset 0). An EMPTY chunk is skipped (returns `next`
/// directly) — matches JVM `chunk-cons`, so a `filter` chunk where every
/// element was dropped does not leave a 0-count chunk in the chain.
pub fn chunkCons(rt: *Runtime, bufv: Value, next: Value) !Value {
    const cb = bufv.decodePtr(*ChunkBuffer);
    if (cb.count == 0) return next;
    const cc = try rt.gc.alloc(ChunkedCons);
    cc.* = .{
        .header = HeapHeader.init(.chunked_cons),
        .offset = 0,
        .chunk = cb,
        .next = next,
    };
    return Value.encodeHeapPtr(.chunked_cons, cc);
}

/// Per-tag trace fns. ChunkBuffer walks every populated slot (slots
/// past `count` stay nil_val — Value.heapHeader filters). ChunkedCons
/// walks the chunk pointer (encoded as a raw *ChunkBuffer; cast +
/// mark per the gc_alloc invariant) + the `next` Value.
pub fn traceChunkBuffer(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const cb: *ChunkBuffer = @ptrCast(@alignCast(header));
    for (cb.slots[0..cb.count]) |slot| {
        if (slot.heapHeader()) |h| mark_sweep.mark(gc, h);
    }
}

pub fn traceChunkedCons(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const cc: *ChunkedCons = @ptrCast(@alignCast(header));
    if (cc.chunk) |c| mark_sweep.mark(gc, @ptrCast(c));
    if (cc.next.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register both chunked-related trace fns. Called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.chunk_buffer, &traceChunkBuffer);
    tag_ops.registerTrace(.chunked_cons, &traceChunkedCons);
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

test "ChunkBuffer + ChunkedCons layout: HeapHeader at offset 0, 32 slots" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(ChunkBuffer, "header"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ChunkedCons, "header"));
    const cb: ChunkBuffer = .{ .header = HeapHeader.init(.chunk_buffer) };
    try testing.expectEqual(@as(usize, CHUNK_SIZE), cb.slots.len);
    try testing.expect(@alignOf(ChunkBuffer) >= 8);
    try testing.expect(@alignOf(ChunkedCons) >= 8);
}

test "ChunkedCons count + first + rest: hand-built single chunk of 5 elements" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // Allocate ChunkBuffer with [10, 20, 30, 40, 50] populated.
    const cb = try fix.rt.gc.alloc(ChunkBuffer);
    cb.* = .{ .header = HeapHeader.init(.chunk_buffer), .count = 5 };
    for (0..5) |i| cb.slots[i] = Value.initInteger(@intCast(10 * (i + 1)));

    // Wrap in a ChunkedCons starting at offset 0, next = nil.
    const cc = try fix.rt.gc.alloc(ChunkedCons);
    cc.* = .{ .header = HeapHeader.init(.chunked_cons), .offset = 0, .chunk = cb, .next = Value.nil_val };
    var v = Value.encodeHeapPtr(.chunked_cons, cc);

    try testing.expectEqual(@as(u32, 5), count(v));
    try testing.expectEqual(@as(i48, 10), first(v).asInteger());

    v = try rest(&fix.rt, v);
    try testing.expectEqual(@as(u32, 4), count(v));
    try testing.expectEqual(@as(i48, 20), first(v).asInteger());

    // Skip to the last element.
    v = try rest(&fix.rt, v);
    v = try rest(&fix.rt, v);
    v = try rest(&fix.rt, v);
    try testing.expectEqual(@as(u32, 1), count(v));
    try testing.expectEqual(@as(i48, 50), first(v).asInteger());

    // Rest past the last element returns the next field (nil here).
    v = try rest(&fix.rt, v);
    try testing.expect(v.isNil());
}

test "ChunkedCons count walks the chain via next" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // Two chunks of 3 elements each, linked via next.
    const cb1 = try fix.rt.gc.alloc(ChunkBuffer);
    cb1.* = .{ .header = HeapHeader.init(.chunk_buffer), .count = 3 };
    for (0..3) |i| cb1.slots[i] = Value.initInteger(@intCast(i + 1));

    const cb2 = try fix.rt.gc.alloc(ChunkBuffer);
    cb2.* = .{ .header = HeapHeader.init(.chunk_buffer), .count = 3 };
    for (0..3) |i| cb2.slots[i] = Value.initInteger(@intCast(i + 4));

    const cc2 = try fix.rt.gc.alloc(ChunkedCons);
    cc2.* = .{ .header = HeapHeader.init(.chunked_cons), .offset = 0, .chunk = cb2, .next = Value.nil_val };
    const cc1 = try fix.rt.gc.alloc(ChunkedCons);
    cc1.* = .{ .header = HeapHeader.init(.chunked_cons), .offset = 0, .chunk = cb1, .next = Value.encodeHeapPtr(.chunked_cons, cc2) };
    const v = Value.encodeHeapPtr(.chunked_cons, cc1);

    try testing.expectEqual(@as(u32, 6), count(v));
    try testing.expectEqual(@as(i48, 1), first(v).asInteger());

    // Walk into the second chunk.
    var w = v;
    for (0..3) |_| w = try rest(&fix.rt, w); // exhaust first chunk → land on cc2
    try testing.expectEqual(@as(u32, 3), count(w));
    try testing.expectEqual(@as(i48, 4), first(w).asInteger());
}

test "count + first on nil / non-chunked = 0 / nil" {
    try testing.expectEqual(@as(u32, 0), count(Value.nil_val));
    try testing.expectEqual(@as(u32, 0), count(Value.initInteger(42)));
    try testing.expect(first(Value.nil_val).isNil());
}

test "chunk-builder round-trip: buffer → append → chunk-cons (ADR-0065)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // Fill a 3-element chunk via the builder surface.
    const b = try newChunkBuffer(&fix.rt);
    _ = chunkAppend(b, Value.initInteger(7));
    _ = chunkAppend(b, Value.initInteger(8));
    _ = chunkAppend(b, Value.initInteger(9));
    const v = try chunkCons(&fix.rt, b, Value.nil_val);

    try testing.expect(isChunked(v));
    try testing.expectEqual(@as(u32, 3), currentChunkCount(v));
    try testing.expectEqual(@as(i48, 7), currentChunkNth(v, 0).asInteger());
    try testing.expectEqual(@as(i48, 9), currentChunkNth(v, 2).asInteger());
    try testing.expectEqual(@as(u32, 3), count(v));
    try testing.expect(chunkRest(v).isNil());
}

test "chunk-cons of an empty buffer is skipped (returns next)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // An empty filtered chunk must NOT leave a 0-count chunk in the chain
    // (JVM chunk-cons semantics) — chunk-cons returns `next` directly.
    const empty_b = try newChunkBuffer(&fix.rt);
    const tail = Value.initInteger(99); // stand-in continuation
    const v = try chunkCons(&fix.rt, empty_b, tail);
    try testing.expect(!isChunked(v));
    try testing.expectEqual(@as(i48, 99), v.asInteger());
}
