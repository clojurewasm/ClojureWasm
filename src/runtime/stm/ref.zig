// SPDX-License-Identifier: EPL-2.0
//! STM Ref — Tier A reference cell with MVCC history ring.
//!
//! Ref started as a single `current: Value` cell (ADR-0010
//! amendment 3); D-102 + ADR-0010 amendment 4 landed the
//! JVM-faithful doubly-linked self-loop history ring:
//!
//!   Ref { header, lock, _pad, tvals: *TVal,
//!         min_history: u32 = 0, max_history: u32 = 10 }
//!
//! `tvals` is the ring head (newest committed value). `current(v)`
//! reads `tvals.val`. `(ref init)` seeds a 1-node self-loop ring at
//! `point = 0, msecs = 0`; commits at Phase B splice a new TVal
//! between `tvals` and `tvals.next` per JVM `Ref.java:64-69` and
//! advance the head.
//!
//! `lock` is a per-Ref commit lock reserved for the Phase B
//! transaction engine; it extends Ref's surface without re-laying
//! the struct. The commit path's lock discipline (spin vs blocking)
//! is a real F-009 divergence point from JVM's blocking lock
//! (ADR-0010 amendment 4 records the rationale); the concrete
//! Zig-0.16 locking primitive is chosen at Phase B entry (the
//! pre-0.16 plan referenced removed APIs).
//!
//! `deref` outside a transaction returns `tvals.val` (= JVM's
//! "currentVal reads the newest TVal when no transaction is
//! active"). `alter` / `commute` / `ensure` / `ref-set` /
//! `dosync` still raise their staged Codes until Phase B wires
//! `LockingTransaction`.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const tval_mod = @import("tval.zig");
const TVal = tval_mod.TVal;

/// Heap layout for an STM Ref. Carries the ring head + ring-growth
/// machinery + commit lock. The lock lives at the natural offset
/// after the header (1 byte aligned), with explicit `_pad` to keep
/// the rest of the layout 8-byte aligned for `*TVal` + i64-class
/// fields.
pub const Ref = extern struct {
    header: HeapHeader,
    lock: std.atomic.Mutex = .unlocked,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    tvals: *TVal,
    min_history: u32 = 0,
    max_history: u32 = 10,
    /// Process-unique id, assigned at construction. The STM commit acquires
    /// each written Ref's lock in ascending-id order so concurrent multi-ref
    /// transactions cannot deadlock (a total order on lock acquisition —
    /// clj keys its lock TreeMap by this id; ADR-0090 §3 / #5-ii).
    id: u64 = 0,

    comptime {
        std.debug.assert(@alignOf(Ref) >= 8);
        std.debug.assert(@offsetOf(Ref, "header") == 0);
        // `std.atomic.Mutex` is `enum(u8)` per /nix/store/.../lib/std/atomic.zig:507.
        // If a future Zig release widens it, the assertion fires and
        // forces a re-layout decision (e.g., split the field, or
        // collapse `_pad`).
        std.debug.assert(@sizeOf(std.atomic.Mutex) == 1);
    }
};

/// Allocate a heap-tracked Ref seeded with `init`. Materialises the
/// initial 1-node self-loop ring (`tvals.prior == tvals == tvals.next`).
/// Phase B takes the lock + splices a new TVal on each commit.
/// Monotonic Ref-id source for the STM lock-ordering (see `Ref.id`).
var next_ref_id: std.atomic.Value(u64) = .init(0);

pub fn alloc(rt: *Runtime, init: Value) !Value {
    const seed = try tval_mod.allocSelfLoop(rt, init, 0, 0);
    const cell = try rt.gc.alloc(Ref);
    cell.* = .{
        .header = HeapHeader.init(.ref),
        .tvals = seed,
        .id = next_ref_id.fetchAdd(1, .monotonic),
    };
    return Value.encodeHeapPtr(.ref, cell);
}

/// True when `v` is an STM Ref.
pub fn isRef(v: Value) bool {
    return v.tag() == .ref;
}

/// Current committed value of a Ref (`deref` outside a transaction).
/// Reads the ring head's `val` UNDER the commit lock so the read synchronizes-
/// with the last committer's release (an unsynchronized read can see a stale
/// ring head under relaxed ordering, or a node mid-recycle). Caller guarantees
/// `v` is a Ref. Mirrors the in-transaction `lock_tx.doGet` read discipline.
pub fn current(v: Value) Value {
    const r: *Ref = @constCast(v.decodePtr(*const Ref));
    while (!r.lock.tryLock()) std.atomic.spinLoopHint();
    defer r.lock.unlock();
    return r.tvals.val;
}

/// Per-tag trace fn — Ref owns the ring head pointer. The ring
/// itself is traced by TVal's `traceGc` (recursion + mark-bitmap
/// cycle detection); marking `tvals.header` triggers the chain.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Ref = @ptrCast(@alignCast(header));
    mark_sweep.mark(gc, &r.tvals.header);
}

/// Register Ref's trace fn at `.ref`. Idempotent.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.ref, &traceGc);
}

// --- tests ---

const testing = std.testing;

test "Ref alloc + isRef + current round-trip (Phase 14 ring head)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const r = try alloc(&rt, Value.initInteger(42));
    try testing.expect(isRef(r));
    try testing.expectEqual(@as(i64, 42), current(r).asInteger());
    try testing.expect(!isRef(Value.initInteger(99)));
}

test "Ref initial ring is 1-node self-loop" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const rv = try alloc(&rt, Value.initInteger(7));
    const ref = rv.decodePtr(*const Ref);
    const head = ref.tvals;
    try testing.expect(head.prior == head);
    try testing.expect(head.next == head);
    try testing.expectEqual(@as(i64, 0), head.point);
    try testing.expectEqual(@as(u32, 0), ref.min_history);
    try testing.expectEqual(@as(u32, 10), ref.max_history);
}

test "Ref lock is initially unlocked + tryLock/unlock round-trip" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const rv = try alloc(&rt, Value.initInteger(0));
    const ref: *Ref = @constCast(rv.decodePtr(*const Ref));
    try testing.expect(ref.lock == .unlocked);
    try testing.expect(ref.lock.tryLock());
    try testing.expect(ref.lock == .locked);
    // A second tryLock without unlock returns false.
    try testing.expect(!ref.lock.tryLock());
    ref.lock.unlock();
    try testing.expect(ref.lock == .unlocked);
}
