// SPDX-License-Identifier: EPL-2.0
//! PersistentVector — Clojure-shape HAMT (shift=5 = 32-way) + 32-element
//! tail array per ROADMAP §9.7 row 5.4.
//!
//! Structure (matches clojure JVM `clojure.lang.PersistentVector`,
//! re-typed in Zig 0.16 `extern struct` shape for the 5.3 GC
//! integration — header at offset 0, slots inlined as fixed-size
//! arrays, all allocations through `rt.gc.alloc`):
//!
//!   ```
//!   Vector { count, shift, root: ?*HamtNode, tail: ?*TailNode, meta }
//!     ├── root → HamtNode { slots: [32]Value }
//!     │            ├── slots[i] → HamtNode (interior at shift > 5)
//!     │            └── slots[i] → leaf HamtNode (shift == 5, slot = Value)
//!     └── tail → TailNode { len, slots: [32]Value }
//!   ```
//!
//! The first `tailoff() = (count - 1) & ~31` Values live in `root` —
//! 32 leaves per interior level, `shift` levels deep. The remaining
//! `count - tailoff()` Values live in `tail` (≤ 32). `nth(v, i)`:
//! if `i >= tailoff()` → `tail.slots[i - tailoff()]`; else walk
//! `root` via `(i >>> level) & 0x1F` at each level until shift==5,
//! then `leaf.slots[i & 0x1F]`.
//!
//! 5.4.a (this file's first landing): struct shapes + EMPTY singleton
//! + nth + count read-side ops. 5.4.b lands conj + pop (pushTail /
//! popTail patterns); 5.4.c lands assoc; 5.4.d lands subvec.
//!
//! Per-tag trace fns + Runtime.init registration are deferred to
//! 5.4.b alongside the first allocation site — at 5.4.a EMPTY is a
//! comptime const singleton (no GC trace needed because it never
//! lives on the GC heap).

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const HeapTag = value_mod.HeapTag;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Number of branch bits per HAMT level (Clojure JVM = 5; matches
/// the cache-line-friendly 32-way branching factor).
pub const SHIFT_BITS: u5 = 5;
/// Branch factor per level (2^SHIFT_BITS = 32).
pub const BRANCH_FACTOR: u8 = 1 << SHIFT_BITS;
/// Index mask for one level (`& MASK` picks the low SHIFT_BITS).
pub const MASK: u32 = BRANCH_FACTOR - 1;

/// Top-level PersistentVector. extern struct so declaration order is
/// preserved + HeapHeader lands at offset 0 (required by
/// `gc.alloc(T)` per the comptime check).
pub const Vector = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// O(1) element count. Capped at `std.math.maxInt(u32)`.
    count: u32 = 0,
    /// Trie depth in branch bits — `shift = SHIFT_BITS * (depth - 1)`
    /// where depth is the number of node levels in `root`. shift = 0
    /// means root is a leaf HamtNode (or null for empty).
    shift: u32 = 0,
    /// Root of the HAMT trie (null for vectors with ≤ 32 elements
    /// where everything lives in `tail`).
    root: ?*HamtNode = null,
    /// Tail array — the last ≤ 32 elements live here for O(1) conj
    /// per the canonical clojure JVM pattern.
    tail: ?*TailNode = null,
    /// Optional metadata map (Clojure `with-meta` / `meta`).
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(Vector) >= 8);
        std.debug.assert(@offsetOf(Vector, "header") == 0);
    }
};

/// HAMT interior / leaf node — 32 Value slots inlined. At leaf level
/// (shift == 0 in the parent Vector's terms) the slots are Clojure
/// element Values; at interior levels they are `Value`-encoded
/// `*HamtNode` pointers (via `encodeHeapPtr(.hamt_node, child)`).
///
/// Why `slots` is 32 Values and not 32 raw pointers: the GC trace
/// fn walks per-slot via `Value.heapHeader()` which uniformly
/// handles both element Values and HamtNode-pointer Values. The
/// extra encoding cost is zero (Values are u64 already).
pub const HamtNode = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    slots: [BRANCH_FACTOR]Value = @splat(Value.nil_val),

    comptime {
        std.debug.assert(@alignOf(HamtNode) >= 8);
        std.debug.assert(@offsetOf(HamtNode, "header") == 0);
    }
};

/// 32-element tail array. `len` tracks the populated prefix (1..32);
/// `slots[0..len]` are the live Values. When `len` reaches 32 the
/// tail promotes to a leaf HamtNode under `root` (5.4.b conj).
pub const TailNode = extern struct {
    header: HeapHeader,
    _pad: [2]u8 = .{ 0, 0 },
    len: u32 = 0,
    slots: [BRANCH_FACTOR]Value = @splat(Value.nil_val),

    comptime {
        std.debug.assert(@alignOf(TailNode) >= 8);
        std.debug.assert(@offsetOf(TailNode, "header") == 0);
    }
};

/// Empty PersistentVector singleton — comptime const, lives forever
/// in the binary's read-only segment. The Value form `EMPTY_VALUE`
/// encodes a pointer at the singleton; the GC never sweeps it
/// because `nil` heap-pointers / immediate-band pointers are filtered
/// out by `Value.heapHeader()` before the live-list walk would see
/// them.
pub var EMPTY: Vector align(8) = .{
    .header = HeapHeader.init(.vector),
    .count = 0,
    .shift = 0,
    .root = null,
    .tail = null,
    .meta = Value.nil_val,
};

/// Pointer to the EMPTY singleton, wrapped as a heap-tagged Value.
/// Use this as the starting point for `conj`-built vectors (5.4.b).
pub fn empty() Value {
    return Value.encodeHeapPtr(.vector, &EMPTY);
}

/// HamtNode.dupe — shallow copy with a fresh header. Used inside
/// popTail's recursion when descending into a slot that already
/// exists but isn't being modified at this level.
fn dupeHamt(parent: *const HamtNode, rt: *Runtime) !*HamtNode {
    const c = try rt.gc.alloc(HamtNode);
    c.* = .{ .header = HeapHeader.init(.hamt_node) };
    @memcpy(&c.slots, &parent.slots);
    return c;
}

/// Per-tag trace fns (called by mark phase to walk outgoing GC-managed
/// pointers per ADR-0028 §5). Vector trace walks root + tail + meta;
/// HamtNode trace walks all 32 slots; TailNode trace walks slots[0..len].
pub fn traceVector(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const vec: *Vector = @ptrCast(@alignCast(header));
    if (vec.root) |r| mark_sweep.mark(gc, @ptrCast(r));
    if (vec.tail) |t| mark_sweep.mark(gc, @ptrCast(t));
    if (vec.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

pub fn traceHamtNode(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const node: *HamtNode = @ptrCast(@alignCast(header));
    for (node.slots) |slot| {
        if (slot.heapHeader()) |h| mark_sweep.mark(gc, h);
    }
}

pub fn traceTailNode(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const t: *TailNode = @ptrCast(@alignCast(header));
    for (t.slots[0..t.len]) |slot| {
        if (slot.heapHeader()) |h| mark_sweep.mark(gc, h);
    }
}

/// Register the three vector-related trace fns into
/// `tag_ops.tag_trace_table`. Idempotent at the same fn pointers
/// (`tag_ops.registerTrace`); called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.vector, &traceVector);
    tag_ops.registerTrace(.hamt_node, &traceHamtNode);
    tag_ops.registerTrace(.tail_node, &traceTailNode);
}

/// O(1) element count. Per Clojure semantics, `(count nil) = 0`.
pub fn count(v: Value) u32 {
    return switch (v.tag()) {
        .vector => v.decodePtr(*const Vector).count,
        .nil => 0,
        else => 0,
    };
}

/// `tailoff = first index that lives in tail (= 0 when tail-only)`.
/// Per clojure JVM `PersistentVector.tailoff()`.
inline fn tailoff(c: u32) u32 {
    if (c < BRANCH_FACTOR) return 0;
    return ((c - 1) >> SHIFT_BITS) << SHIFT_BITS;
}

/// Append `x` to the vector. **Phase 5.4.b body**: tail fast path
/// (copy + append when tail has < 32 elements) or root push (when
/// tail is full — promote tail to a new HAMT leaf, install in root,
/// new tail = `[x]`). Per clojure JVM `PersistentVector.cons()`.
pub fn conj(rt: *Runtime, v: Value, x: Value) !Value {
    std.debug.assert(v.tag() == .vector);
    const old = v.decodePtr(*const Vector);

    // Fast path: tail has space (< BRANCH_FACTOR elements).
    const tail_size = if (old.tail) |t| t.len else 0;
    if (tail_size < BRANCH_FACTOR) {
        const new_tail = try rt.gc.alloc(TailNode);
        new_tail.* = .{ .header = HeapHeader.init(.tail_node), .len = tail_size + 1 };
        if (old.tail) |t| {
            @memcpy(new_tail.slots[0..tail_size], t.slots[0..tail_size]);
        }
        new_tail.slots[tail_size] = x;
        return try newVector(rt, old.count + 1, old.shift, old.root, new_tail, old.meta);
    }

    // Tail-full path: promote the old tail to a leaf HamtNode under
    // root; new tail holds just `x`. The promoted leaf goes into the
    // root trie via pushTail, possibly growing the trie depth.
    const tail_as_leaf = try rt.gc.alloc(HamtNode);
    tail_as_leaf.* = .{ .header = HeapHeader.init(.hamt_node) };
    @memcpy(&tail_as_leaf.slots, &old.tail.?.slots);

    const old_count = old.count;
    var new_shift = old.shift;
    var new_root: *HamtNode = undefined;

    // Root overflow check: at the current depth the trie can hold up
    // to `1 << (shift + SHIFT_BITS)` elements before tail (cnt is
    // tailoff = `old_count - BRANCH_FACTOR` elements). If pushing one
    // more leaf would exceed capacity, grow the trie one level.
    const tailoff_old = tailoff(old_count);
    const capacity_at_shift: u64 = @as(u64, 1) << @intCast(old.shift + SHIFT_BITS);
    if (tailoff_old + BRANCH_FACTOR > capacity_at_shift) {
        // Overflow — wrap old root in a new root + push tail-as-leaf
        // down a new branch.
        const wrapped = try rt.gc.alloc(HamtNode);
        wrapped.* = .{ .header = HeapHeader.init(.hamt_node) };
        if (old.root) |r| wrapped.slots[0] = Value.encodeHeapPtr(.hamt_node, r);
        wrapped.slots[1] = Value.encodeHeapPtr(.hamt_node, try newPath(rt, old.shift, tail_as_leaf));
        new_shift = old.shift + SHIFT_BITS;
        new_root = wrapped;
    } else if (old.root) |r| {
        new_root = try pushTail(rt, old.shift, r, tailoff_old, tail_as_leaf);
    } else {
        // First time root populates — old vector was tail-only.
        new_root = tail_as_leaf;
        new_shift = 0;
    }

    const new_tail = try rt.gc.alloc(TailNode);
    new_tail.* = .{ .header = HeapHeader.init(.tail_node), .len = 1 };
    new_tail.slots[0] = x;
    return try newVector(rt, old_count + 1, new_shift, new_root, new_tail, old.meta);
}

/// Remove the last element. Per clojure JVM `PersistentVector.pop()`.
/// Errors when called on the empty vector (matches Clojure semantics —
/// `(pop [])` throws `IllegalStateException`; cw v1 maps to
/// `Code.feature_not_supported` until the catalog Code lands).
pub fn pop(rt: *Runtime, v: Value) !Value {
    std.debug.assert(v.tag() == .vector);
    const old = v.decodePtr(*const Vector);
    if (old.count == 0) return error.PopEmpty;

    // Singleton: drop to EMPTY.
    if (old.count == 1) return empty();

    // Fast path: tail has > 1 element — copy tail with len-1.
    const tail_size = if (old.tail) |t| t.len else 0;
    if (tail_size > 1) {
        const new_tail = try rt.gc.alloc(TailNode);
        new_tail.* = .{ .header = HeapHeader.init(.tail_node), .len = tail_size - 1 };
        @memcpy(new_tail.slots[0 .. tail_size - 1], old.tail.?.slots[0 .. tail_size - 1]);
        return try newVector(rt, old.count - 1, old.shift, old.root, new_tail, old.meta);
    }

    // Tail has exactly 1 element — pull the last leaf out of root to
    // become the new tail. May collapse trie depth if the root's
    // first slot is empty after the pull.
    const new_tail_leaf = arrayFor(old, old.count - 2);
    const new_tail = try rt.gc.alloc(TailNode);
    new_tail.* = .{ .header = HeapHeader.init(.tail_node), .len = BRANCH_FACTOR };
    @memcpy(&new_tail.slots, &new_tail_leaf.slots);

    var new_root: ?*HamtNode = null;
    var new_shift = old.shift;
    if (old.root) |r| {
        new_root = try popTail(rt, old.shift, r, old.count - 1);
        // Collapse: if shift > 0 and root has only one branch left,
        // drop a level by hoisting the lone child.
        if (new_root != null and old.shift > 0 and new_root.?.slots[1].isNil()) {
            const lone = new_root.?.slots[0];
            if (!lone.isNil()) {
                new_root = lone.decodePtr(*HamtNode);
                new_shift -= SHIFT_BITS;
            }
        }
    }
    return try newVector(rt, old.count - 1, new_shift, new_root, new_tail, old.meta);
}

/// Replace the element at `i` with `x`. Per clojure JVM `assocN`:
///   - `i == count` is equivalent to `conj` (append semantics)
///   - `i in [0, tailoff)` walks root, copy-on-writes the path
///   - `i in [tailoff, count)` copies tail with slot[i - tailoff] = x
///   - `i > count` returns `error.AssocOutOfBounds` (Clojure's
///     IndexOutOfBoundsException maps to a runtime error catalog
///     Code at the analyzer level later)
pub fn assoc(rt: *Runtime, v: Value, i: u32, x: Value) !Value {
    std.debug.assert(v.tag() == .vector);
    const old = v.decodePtr(*const Vector);
    if (i == old.count) return try conj(rt, v, x);
    if (i > old.count) return error.AssocOutOfBounds;

    if (i >= tailoff(old.count)) {
        const tail_size = if (old.tail) |t| t.len else 0;
        const new_tail = try rt.gc.alloc(TailNode);
        new_tail.* = .{ .header = HeapHeader.init(.tail_node), .len = tail_size };
        @memcpy(new_tail.slots[0..tail_size], old.tail.?.slots[0..tail_size]);
        new_tail.slots[i - tailoff(old.count)] = x;
        return try newVector(rt, old.count, old.shift, old.root, new_tail, old.meta);
    }

    // In-root path: recursive copy-on-write descent.
    const new_root = try assocInRoot(rt, old.shift, old.root.?, i, x);
    return try newVector(rt, old.count, old.shift, new_root, old.tail, old.meta);
}

/// Recursive helper for assoc's in-root path. Copy-on-write descent:
/// duplicate the node at each level, overwrite the slot on the path
/// to `i`, recurse until shift==0 then overwrite the leaf slot.
fn assocInRoot(rt: *Runtime, level: u32, node: *const HamtNode, i: u32, x: Value) !*HamtNode {
    const dup = try rt.gc.alloc(HamtNode);
    dup.* = .{ .header = HeapHeader.init(.hamt_node) };
    @memcpy(&dup.slots, &node.slots);

    if (level == 0) {
        dup.slots[i & MASK] = x;
        return dup;
    }
    const sub_index = (i >> @as(u5, @intCast(level))) & MASK;
    const child = node.slots[sub_index].decodePtr(*const HamtNode);
    const new_child = try assocInRoot(rt, level - SHIFT_BITS, child, i, x);
    dup.slots[sub_index] = Value.encodeHeapPtr(.hamt_node, new_child);
    return dup;
}

/// Slice a vector to `[start, end)`. Per clojure JVM `subvec`:
///   - 0 ≤ start ≤ end ≤ count v (else error.SubvecOutOfBounds)
///   - subvec v 0 (count v) is equivalent to v (we copy structurally
///     anyway for simplicity; the result is a fresh Vector)
///
/// **5.4.d implementation choice**: eager copy via repeated `conj`.
/// Lazy SubVector wrapper (clojure JVM's actual approach with
/// structural sharing of the parent) is deferred to a Phase 7+
/// follow-up — it requires a new SubVector type + Tag slot +
/// polymorphic op dispatch, which is genuinely substantial. Eager
/// copy is O(n) where n = end - start; typical subvec call sites
/// (small ranges over large vectors) keep the cost bounded.
/// Recorded as D-044 candidate at row 5.4 close handover.
pub fn subvec(rt: *Runtime, v: Value, start: u32, end: u32) !Value {
    std.debug.assert(v.tag() == .vector);
    const old = v.decodePtr(*const Vector);
    if (start > end or end > old.count) return error.SubvecOutOfBounds;
    var out = empty();
    var i: u32 = start;
    while (i < end) : (i += 1) {
        out = try conj(rt, out, nth(v, i));
    }
    return out;
}

/// Allocate a new Vector with the given fields. Helper to keep conj /
/// pop / assoc bodies tight.
fn newVector(
    rt: *Runtime,
    new_count: u32,
    new_shift: u32,
    new_root: ?*HamtNode,
    new_tail: ?*TailNode,
    new_meta: Value,
) !Value {
    const v = try rt.gc.alloc(Vector);
    v.* = .{
        .header = HeapHeader.init(.vector),
        .count = new_count,
        .shift = new_shift,
        .root = new_root,
        .tail = new_tail,
        .meta = new_meta,
    };
    return Value.encodeHeapPtr(.vector, v);
}

/// `pushTail` — recursive descent that installs a tail-promoted leaf
/// at the right slot. Returns the new root for the subtree.
fn pushTail(
    rt: *Runtime,
    level: u32,
    parent: *const HamtNode,
    tail_offset: u32,
    tail_leaf: *HamtNode,
) !*HamtNode {
    const sub_index = (tail_offset >> @as(u5, @intCast(level))) & MASK;
    const new_parent = try rt.gc.alloc(HamtNode);
    new_parent.* = .{ .header = HeapHeader.init(.hamt_node) };
    @memcpy(&new_parent.slots, &parent.slots);

    if (level == SHIFT_BITS) {
        // Parent is one above leaf level — slot it directly.
        new_parent.slots[sub_index] = Value.encodeHeapPtr(.hamt_node, tail_leaf);
    } else {
        // Recurse: either descend into existing child or grow a fresh
        // path of empty interiors down to where the leaf will sit.
        const existing = parent.slots[sub_index];
        const sub_node: *HamtNode = if (existing.isNil())
            try newPath(rt, level - SHIFT_BITS, tail_leaf)
        else
            try pushTail(rt, level - SHIFT_BITS, existing.decodePtr(*const HamtNode), tail_offset, tail_leaf);
        new_parent.slots[sub_index] = Value.encodeHeapPtr(.hamt_node, sub_node);
    }
    return new_parent;
}

/// `newPath` — build a chain of empty interior nodes from `level` down
/// to a leaf, with `leaf` at the bottom in slot 0. Used by conj's
/// overflow / pushTail's grow-path-from-nil branch.
fn newPath(rt: *Runtime, level: u32, leaf: *HamtNode) !*HamtNode {
    if (level == 0) return leaf;
    const interior = try rt.gc.alloc(HamtNode);
    interior.* = .{ .header = HeapHeader.init(.hamt_node) };
    interior.slots[0] = Value.encodeHeapPtr(.hamt_node, try newPath(rt, level - SHIFT_BITS, leaf));
    return interior;
}

/// `popTail` — recursive descent that removes the last leaf from the
/// trie. Returns the new root for the subtree, or null if the entire
/// subtree collapsed.
fn popTail(rt: *Runtime, level: u32, parent: *const HamtNode, new_count: u32) !?*HamtNode {
    const sub_index = ((new_count - 1) >> @as(u5, @intCast(level))) & MASK;
    if (level > SHIFT_BITS) {
        const child = parent.slots[sub_index];
        if (child.isNil()) return try dupeHamt(parent, rt);
        const new_child = try popTail(rt, level - SHIFT_BITS, child.decodePtr(*const HamtNode), new_count);
        if (new_child == null and sub_index == 0) {
            return null; // whole subtree gone
        }
        const new_parent = try rt.gc.alloc(HamtNode);
        new_parent.* = .{ .header = HeapHeader.init(.hamt_node) };
        @memcpy(&new_parent.slots, &parent.slots);
        new_parent.slots[sub_index] = if (new_child) |c| Value.encodeHeapPtr(.hamt_node, c) else Value.nil_val;
        return new_parent;
    }
    if (sub_index == 0) return null;
    const new_parent = try rt.gc.alloc(HamtNode);
    new_parent.* = .{ .header = HeapHeader.init(.hamt_node) };
    @memcpy(&new_parent.slots, &parent.slots);
    new_parent.slots[sub_index] = Value.nil_val;
    return new_parent;
}

/// Decode-only helper: returns the leaf HamtNode that contains index
/// `i` (in-root indices only; tail handled separately). Used by pop's
/// tail-replacement path.
fn arrayFor(vec: *const Vector, i: u32) *const HamtNode {
    std.debug.assert(i < tailoff(vec.count));
    var node: *const HamtNode = vec.root.?;
    var level: u32 = vec.shift;
    while (level > 0) : (level -= SHIFT_BITS) {
        const idx = (i >> @as(u5, @intCast(level))) & MASK;
        node = node.slots[idx].decodePtr(*const HamtNode);
    }
    return node;
}

/// O(log32 n) random access. Returns `nil` for out-of-bounds (matches
/// Clojure `(nth v i nil)` — the 2-arg `(nth v i)` throws but the
/// 3-arg variant returns the not-found sentinel; our Day-1 surface
/// goes through the analyzer which decides which variant to call).
pub fn nth(v: Value, i: u32) Value {
    if (v.tag() != .vector) return Value.nil_val;
    const vec = v.decodePtr(*const Vector);
    if (i >= vec.count) return Value.nil_val;

    if (i >= tailoff(vec.count)) {
        // In-tail path: trivial index into the 32-slot tail.
        const t = vec.tail orelse return Value.nil_val;
        return t.slots[i - tailoff(vec.count)];
    }

    // In-root path: walk down the HAMT via `(i >>> level) & MASK` at
    // each level. shift = SHIFT_BITS * (depth - 1); we descend until
    // shift reaches 0.
    var node: *const HamtNode = vec.root orelse return Value.nil_val;
    var level: u32 = vec.shift;
    while (level > 0) : (level -= SHIFT_BITS) {
        const idx = (i >> @as(u5, @intCast(level))) & MASK;
        const child_val = node.slots[idx];
        node = child_val.decodePtr(*const HamtNode);
    }
    return node.slots[i & MASK];
}

// --- tests ---

const testing = std.testing;

test "EMPTY singleton: count = 0, nth out-of-bounds = nil" {
    const v = empty();
    try testing.expect(v.tag() == .vector);
    try testing.expectEqual(@as(u32, 0), count(v));
    try testing.expect(nth(v, 0).isNil());
    try testing.expect(nth(v, 100).isNil());
}

test "count on nil = 0; count on non-vector = 0" {
    try testing.expectEqual(@as(u32, 0), count(Value.nil_val));
    try testing.expectEqual(@as(u32, 0), count(Value.initInteger(42)));
    try testing.expectEqual(@as(u32, 0), count(Value.initFloat(3.14)));
}

test "tailoff edge cases" {
    try testing.expectEqual(@as(u32, 0), tailoff(0));
    try testing.expectEqual(@as(u32, 0), tailoff(1));
    try testing.expectEqual(@as(u32, 0), tailoff(31));
    try testing.expectEqual(@as(u32, 0), tailoff(32)); // first 32 fit in tail
    try testing.expectEqual(@as(u32, 32), tailoff(33));
    try testing.expectEqual(@as(u32, 32), tailoff(63));
    try testing.expectEqual(@as(u32, 32), tailoff(64));
    try testing.expectEqual(@as(u32, 64), tailoff(65));
}

test "Vector struct layout: HeapHeader at offset 0, 8-byte aligned" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(Vector, "header"));
    try testing.expect(@alignOf(Vector) >= 8);
}

test "HamtNode struct layout: header at 0, 32 slots inlined" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(HamtNode, "header"));
    const default_node: HamtNode = .{ .header = HeapHeader.init(.hamt_node) };
    try testing.expectEqual(@as(usize, BRANCH_FACTOR), default_node.slots.len);
    try testing.expect(@alignOf(HamtNode) >= 8);
}

test "TailNode struct layout: header at 0, 32 slots + len" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(TailNode, "header"));
    const default_tail: TailNode = .{ .header = HeapHeader.init(.tail_node) };
    try testing.expectEqual(@as(usize, BRANCH_FACTOR), default_tail.slots.len);
    try testing.expect(@alignOf(TailNode) >= 8);
}

test "nth in-tail path: handcrafted vector of 3 elements" {
    var tail = TailNode{
        .header = HeapHeader.init(.tail_node),
        .len = 3,
        .slots = blk: {
            var s: [BRANCH_FACTOR]Value = @splat(Value.nil_val);
            s[0] = Value.initInteger(10);
            s[1] = Value.initInteger(20);
            s[2] = Value.initInteger(30);
            break :blk s;
        },
    };
    var vec = Vector{
        .header = HeapHeader.init(.vector),
        .count = 3,
        .shift = 0,
        .root = null,
        .tail = &tail,
    };
    const v = Value.encodeHeapPtr(.vector, &vec);

    try testing.expectEqual(@as(u32, 3), count(v));
    try testing.expectEqual(@as(i48, 10), nth(v, 0).asInteger());
    try testing.expectEqual(@as(i48, 20), nth(v, 1).asInteger());
    try testing.expectEqual(@as(i48, 30), nth(v, 2).asInteger());
    try testing.expect(nth(v, 3).isNil()); // out-of-bounds
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

test "conj from empty: count = 1, tail-only" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v0 = empty();
    const v1 = try conj(&fix.rt, v0, Value.initInteger(42));

    try testing.expectEqual(@as(u32, 1), count(v1));
    try testing.expectEqual(@as(i48, 42), nth(v1, 0).asInteger());
    try testing.expect(nth(v1, 1).isNil()); // out-of-bounds
}

test "conj 32 elements: fills tail, no root yet" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..BRANCH_FACTOR) |i| {
        v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    }
    try testing.expectEqual(@as(u32, BRANCH_FACTOR), count(v));
    try testing.expectEqual(@as(i48, 0), nth(v, 0).asInteger());
    try testing.expectEqual(@as(i48, BRANCH_FACTOR - 1), nth(v, BRANCH_FACTOR - 1).asInteger());

    const vec = v.decodePtr(*const Vector);
    try testing.expect(vec.root == null); // first 32 fit in tail
    try testing.expectEqual(@as(u32, 0), vec.shift);
}

test "conj 33 elements: promotes tail to root, new tail = [33rd]" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..33) |i| {
        v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    }
    try testing.expectEqual(@as(u32, 33), count(v));
    for (0..33) |i| {
        try testing.expectEqual(@as(i48, @intCast(i)), nth(v, @intCast(i)).asInteger());
    }
    const vec = v.decodePtr(*const Vector);
    try testing.expect(vec.root != null); // tail promoted
    try testing.expectEqual(@as(u32, 0), vec.shift); // single-level root
}

test "conj 1024 elements: HAMT depth increases past one level" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    const n: u32 = 1024;
    for (0..n) |i| {
        v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    }
    try testing.expectEqual(@as(u32, n), count(v));
    // Spot-check at several positions: edges + interior.
    try testing.expectEqual(@as(i48, 0), nth(v, 0).asInteger());
    try testing.expectEqual(@as(i48, 31), nth(v, 31).asInteger());
    try testing.expectEqual(@as(i48, 32), nth(v, 32).asInteger());
    try testing.expectEqual(@as(i48, 500), nth(v, 500).asInteger());
    try testing.expectEqual(@as(i48, n - 1), nth(v, n - 1).asInteger());
}

test "pop from 1-element: returns empty" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v1 = try conj(&fix.rt, empty(), Value.initInteger(42));
    const v0 = try pop(&fix.rt, v1);
    try testing.expectEqual(@as(u32, 0), count(v0));
}

test "pop from tail-fast path: decrements count, preserves preceding elems" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..5) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const v_popped = try pop(&fix.rt, v);
    try testing.expectEqual(@as(u32, 4), count(v_popped));
    try testing.expectEqual(@as(i48, 3), nth(v_popped, 3).asInteger());
    try testing.expect(nth(v_popped, 4).isNil());
}

test "pop from 33-element: tail-replace path collapses root" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..33) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const v32 = try pop(&fix.rt, v);
    try testing.expectEqual(@as(u32, 32), count(v32));
    for (0..32) |i| {
        try testing.expectEqual(@as(i48, @intCast(i)), nth(v32, @intCast(i)).asInteger());
    }
}

test "pop on empty: returns error.PopEmpty" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    try testing.expectError(error.PopEmpty, pop(&fix.rt, empty()));
}

test "assoc in-tail: replaces slot, preserves count" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..5) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const v2 = try assoc(&fix.rt, v, 2, Value.initInteger(99));

    try testing.expectEqual(@as(u32, 5), count(v2));
    try testing.expectEqual(@as(i48, 99), nth(v2, 2).asInteger());
    try testing.expectEqual(@as(i48, 1), nth(v2, 1).asInteger()); // adjacent unchanged
    try testing.expectEqual(@as(i48, 2), nth(v, 2).asInteger()); // original unchanged
}

test "assoc in-root: copy-on-write path to leaf, structural sharing of siblings" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..100) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const v2 = try assoc(&fix.rt, v, 0, Value.initInteger(-1));

    try testing.expectEqual(@as(u32, 100), count(v2));
    try testing.expectEqual(@as(i48, -1), nth(v2, 0).asInteger());
    try testing.expectEqual(@as(i48, 99), nth(v2, 99).asInteger());
    try testing.expectEqual(@as(i48, 0), nth(v, 0).asInteger()); // immutable
}

test "assoc at count = conj (append semantics)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..3) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const v2 = try assoc(&fix.rt, v, 3, Value.initInteger(99));

    try testing.expectEqual(@as(u32, 4), count(v2));
    try testing.expectEqual(@as(i48, 99), nth(v2, 3).asInteger());
}

test "assoc out-of-bounds: returns error.AssocOutOfBounds" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try conj(&fix.rt, empty(), Value.initInteger(1));
    try testing.expectError(error.AssocOutOfBounds, assoc(&fix.rt, v, 5, Value.nil_val));
}

test "subvec inner range: preserves slice values + new count" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..10) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const sv = try subvec(&fix.rt, v, 2, 7);

    try testing.expectEqual(@as(u32, 5), count(sv));
    try testing.expectEqual(@as(i48, 2), nth(sv, 0).asInteger());
    try testing.expectEqual(@as(i48, 6), nth(sv, 4).asInteger());
    try testing.expect(nth(sv, 5).isNil()); // out-of-bounds of subvec
    // Parent unchanged
    try testing.expectEqual(@as(u32, 10), count(v));
}

test "subvec full range: equivalent to original vector" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..5) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const sv = try subvec(&fix.rt, v, 0, count(v));

    try testing.expectEqual(@as(u32, 5), count(sv));
    for (0..5) |i| {
        try testing.expectEqual(nth(v, @intCast(i)), nth(sv, @intCast(i)));
    }
}

test "subvec empty range: returns empty vector" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var v = empty();
    for (0..5) |i| v = try conj(&fix.rt, v, Value.initInteger(@intCast(i)));
    const sv = try subvec(&fix.rt, v, 3, 3);

    try testing.expectEqual(@as(u32, 0), count(sv));
}

test "subvec out-of-bounds: errors" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try conj(&fix.rt, empty(), Value.initInteger(1));
    try testing.expectError(error.SubvecOutOfBounds, subvec(&fix.rt, v, 0, 5));
    try testing.expectError(error.SubvecOutOfBounds, subvec(&fix.rt, v, 5, 0));
}

test "nth in-root path: handcrafted shift=5 vector with 33 elements" {
    // 33 elements: first 32 in root (leaf node 0), 33rd in tail.
    var leaf0 = HamtNode{
        .header = HeapHeader.init(.hamt_node),
        .slots = blk: {
            var s: [BRANCH_FACTOR]Value = @splat(Value.nil_val);
            for (0..BRANCH_FACTOR) |idx| s[idx] = Value.initInteger(@intCast(idx + 100));
            break :blk s;
        },
    };
    var tail = TailNode{
        .header = HeapHeader.init(.tail_node),
        .len = 1,
        .slots = blk: {
            var s: [BRANCH_FACTOR]Value = @splat(Value.nil_val);
            s[0] = Value.initInteger(132); // index 32 = first tail elem
            break :blk s;
        },
    };
    var vec = Vector{
        .header = HeapHeader.init(.vector),
        .count = 33,
        .shift = 0, // root IS the leaf (1 level)
        .root = &leaf0,
        .tail = &tail,
    };
    const v = Value.encodeHeapPtr(.vector, &vec);

    try testing.expectEqual(@as(u32, 33), count(v));
    try testing.expectEqual(@as(i48, 100), nth(v, 0).asInteger());
    try testing.expectEqual(@as(i48, 131), nth(v, 31).asInteger());
    try testing.expectEqual(@as(i48, 132), nth(v, 32).asInteger());
    try testing.expect(nth(v, 33).isNil());
}
