// SPDX-License-Identifier: EPL-2.0
//! STM Ref — Tier A reference cell, read-only path (Phase 13).
//!
//! Phase 13 (ADR-0010 amendment 3, Devil's-advocate Alt 3) lands a
//! `Ref` as a single `current: Value` heap cell — lock-free, no
//! `TVal` history ring. `(ref init)` seeds `current`; `deref`
//! **outside a transaction** returns `current` (JVM `Ref.deref`
//! collapses to `currentVal()` reading the newest TVal when no
//! transaction runs). `dosync` / `alter` / `commute` / `ensure` /
//! `ref-set` keep raising their staged Codes — none lands here.
//!
//! Phase-14 ring-rewrite contract (D-102): Phase 14 introduces the
//! `TVal` { val / point / msecs / prior } history ring; `current`
//! becomes the ring head and `deref` reads `tvals.?.val`. The lock
//! returns at Phase 15.1 as `std.Io.Mutex` (NOT the Zig-0.16-removed
//! `std.Thread.Mutex`). This is a bounded, expected field-swap — not
//! a silent surprise. Wiring modelled on `collection/reduced.zig`.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Heap layout for an STM Ref. Phase 13 holds only the newest value
/// inline (`current`); the TVal history ring lands in Phase 14 per
/// D-102, when `current` becomes the ring head.
pub const Ref = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    current: Value,

    comptime {
        std.debug.assert(@alignOf(Ref) >= 8);
        std.debug.assert(@offsetOf(Ref, "header") == 0);
    }
};

/// Allocate a heap-tracked Ref seeded with `init`.
pub fn alloc(rt: *Runtime, init: Value) !Value {
    const cell = try rt.gc.alloc(Ref);
    cell.* = .{
        .header = HeapHeader.init(.ref),
        .current = init,
    };
    return Value.encodeHeapPtr(.ref, cell);
}

/// True when `v` is an STM Ref.
pub fn isRef(v: Value) bool {
    return v.tag() == .ref;
}

/// Current committed value of a Ref. Caller guarantees `v` is a Ref.
pub fn current(v: Value) Value {
    return v.decodePtr(*const Ref).current;
}

/// Per-tag trace fn — Ref owns one Value (`current`) the GC marks.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Ref = @ptrCast(@alignCast(header));
    if (r.current.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register Ref's trace fn at `.ref`. Idempotent.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.ref, &traceGc);
}

// --- tests ---

const testing = std.testing;

test "Ref alloc + isRef + current round-trip" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const r = try alloc(&rt, Value.initInteger(42));
    try testing.expect(isRef(r));
    try testing.expectEqual(@as(i64, 42), current(r).asInteger());
    // isRef on a non-Ref is false.
    try testing.expect(!isRef(Value.initInteger(99)));
}
