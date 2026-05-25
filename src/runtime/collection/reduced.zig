// SPDX-License-Identifier: EPL-2.0
//! Reduced — early-termination sentinel for `reduce` / `transduce`.
//!
//! Wraps an inner value so reducing fns can return `(reduced x)` to
//! terminate the reduction with the value `x`. Per Clojure semantics:
//! `(reduce f init (range 100))` walking a transducer that returns
//! `(reduced 42)` halts immediately and yields `42`.
//!
//! Tag `.reduced` is day-1 reserved (ADR-0004 + ADR-0012, value.zig
//! line 85). This file lands the heap layout + alloc/unwrap helpers
//! required by Phase 6.16.a-3.1's `reduce` (and downstream
//! `transduce`/`reduced?`/`unreduced` at Phase 7+).

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Heap layout for a Reduced sentinel. Single field wrapping the
/// inner value — Clojure's `(reduced x)` just remembers `x` and the
/// "stop reducing now" intent.
pub const Reduced = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    inner: Value,

    comptime {
        std.debug.assert(@alignOf(Reduced) >= 8);
        std.debug.assert(@offsetOf(Reduced, "header") == 0);
    }
};

/// Allocate a heap-tracked Reduced wrapping `inner`. Mirrors the cons
/// allocation pattern in list.zig.
pub fn alloc(rt: *Runtime, inner: Value) !Value {
    const cell = try rt.gc.alloc(Reduced);
    cell.* = .{
        .header = HeapHeader.init(.reduced),
        .inner = inner,
    };
    return Value.encodeHeapPtr(.reduced, cell);
}

/// True when `v` is a `(reduced x)` sentinel.
pub fn isReduced(v: Value) bool {
    return v.tag() == .reduced;
}

/// Extract the inner value from a Reduced. Returns `v` itself if `v`
/// is not a Reduced (per Clojure `(unreduced x)` semantics).
pub fn unreduce(v: Value) Value {
    if (v.tag() != .reduced) return v;
    return v.decodePtr(*const Reduced).inner;
}

/// Per-tag trace fn — Reduced owns one Value (`inner`) that the GC
/// must walk during the mark phase.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Reduced = @ptrCast(@alignCast(header));
    if (r.inner.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register Reduced's trace fn at `.reduced`. Idempotent.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.reduced, &traceGc);
}

// --- tests ---

const testing = std.testing;

test "Reduced alloc + isReduced + unreduce round-trip" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const r = try alloc(&rt, Value.initInteger(42));
    try testing.expect(isReduced(r));
    try testing.expectEqual(@as(i64, 42), unreduce(r).asInteger());
    // unreduce on non-Reduced is identity.
    try testing.expectEqual(@as(i64, 99), unreduce(Value.initInteger(99)).asInteger());
}
