// SPDX-License-Identifier: EPL-2.0
//! Volatile — an unsynchronized mutable reference cell (Clojure
//! `volatile!`). Identical shape to `atom.zig`'s cell (a single mutable
//! `current` Value), but the ops are lighter: `vreset!` / `vswap!` carry
//! NO compare-and-set, NO watches, NO validators (a Java `volatile`
//! field, used mostly inside stateful transducers). Single-threaded now,
//! so the distinction from atom is purely API surface + intent.
//!
//! Tag `.@"volatile" = 35` is day-1 reserved (heap_tag.zig:94, Group C3).

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

/// Heap layout: header + one mutable Value cell (mirrors atom.zig).
pub const Volatile = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    current: Value,

    comptime {
        std.debug.assert(@alignOf(Volatile) >= 8);
        std.debug.assert(@offsetOf(Volatile, "header") == 0);
    }
};

/// Allocate a heap-tracked Volatile seeded with `init`.
pub fn alloc(rt: *Runtime, init: Value) !Value {
    const cell = try rt.gc.alloc(Volatile);
    cell.* = .{ .header = HeapHeader.init(.@"volatile"), .current = init };
    return Value.encodeHeapPtr(.@"volatile", cell);
}

/// True when `v` is a volatile.
pub fn isVolatile(v: Value) bool {
    return v.tag() == .@"volatile";
}

/// Current held value (`deref` / `@`). Caller guarantees `v` is a volatile.
/// Atomic-acquire for cross-thread VISIBILITY (a volatile is JMM-volatile: a
/// write on one thread is visible on another). Volatiles give visibility, NOT
/// atomic compound updates — `vswap!` is intentionally a plain read-modify-write
/// per clj (use an atom when you need atomic compound mutation).
pub fn current(v: Value) Value {
    const cell = v.decodePtr(*const Volatile);
    return @atomicLoad(Value, &cell.current, .acquire);
}

/// Mutate the held value in place (`vreset!` / `vswap!`), atomic-release for
/// cross-thread visibility (not an atomic compound op — see `current`).
pub fn setCurrent(v: Value, newval: Value) void {
    const cell: *Volatile = @constCast(v.decodePtr(*const Volatile));
    @atomicStore(Value, &cell.current, newval, .release);
}

/// Per-tag trace fn — the volatile owns one Value (`current`).
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const cell: *Volatile = @ptrCast(@alignCast(header));
    if (cell.current.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register the volatile trace fn at `.@"volatile"`. Idempotent.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.@"volatile", &traceGc);
}

// --- tests ---

const testing = std.testing;

test "Volatile alloc + current + in-place setCurrent" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const v = try alloc(&rt, Value.initInteger(3));
    try testing.expect(isVolatile(v));
    try testing.expectEqual(@as(i64, 3), current(v).asInteger());
    setCurrent(v, Value.initInteger(8));
    try testing.expectEqual(@as(i64, 8), current(v).asInteger());
    try testing.expect(!isVolatile(Value.initInteger(0)));
}
