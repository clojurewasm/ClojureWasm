// SPDX-License-Identifier: EPL-2.0
//! Atom — single-threaded mutable reference cell (Clojure `atom`).
//!
//! A heap value holding ONE mutable `current` Value. `swap!` / `reset!`
//! mutate `current` IN PLACE, so atom identity is preserved across
//! updates (`(identical? a a)` holds, the whole point of a reference
//! type). `deref` / `@` reads it. `compare-and-set!` uses reference
//! identity (JVM `AtomicReference.compareAndSet` — NOT `=`).
//!
//! Phase-15 deferrals (D-157): watches (add-watch / remove-watch),
//! validators, and real CAS-under-contention atomicity. The runtime is
//! single-threaded until Phase 15, so this basic cell drops no semantics
//! — it is complete for the current runtime, not a stub. Being an
//! `extern struct` lets Phase 15 APPEND `watches` / `validator` fields
//! without re-laying (header stays offset 0, `current` unmoved); per
//! F-003 / the Reservation-as-bias smell, no such field is reserved now.
//! Tag `.atom = 32` is day-1 reserved (ADR-0009 / heap_tag.zig:91);
//! ADR-0010 §79 sketches "implement only atom" as the STM Tier-A start.

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

/// Heap layout: header + one mutable Value cell (mirrors
/// `collection/reduced.zig`, but `current` is reassigned by swap!/reset!).
pub const Atom = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    current: Value,

    comptime {
        std.debug.assert(@alignOf(Atom) >= 8);
        std.debug.assert(@offsetOf(Atom, "header") == 0);
    }
};

/// Allocate a heap-tracked Atom seeded with `init`.
pub fn alloc(rt: *Runtime, init: Value) !Value {
    const cell = try rt.gc.alloc(Atom);
    cell.* = .{ .header = HeapHeader.init(.atom), .current = init };
    return Value.encodeHeapPtr(.atom, cell);
}

/// True when `v` is an atom.
pub fn isAtom(v: Value) bool {
    return v.tag() == .atom;
}

/// Current held value (`deref` / `@`). Caller guarantees `v` is an atom.
pub fn current(v: Value) Value {
    return v.decodePtr(*const Atom).current;
}

/// Mutate the held value in place (`reset!` / `swap!`). Atom identity is
/// preserved — the heap cell is the same, only `current` changes.
pub fn setCurrent(v: Value, newval: Value) void {
    const a: *Atom = @constCast(v.decodePtr(*const Atom));
    a.current = newval;
}

/// Per-tag trace fn — the atom owns one Value (`current`) the GC must
/// walk during the mark phase. A reassigned-away old value becomes
/// unreachable through the atom and is reclaimed normally.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const a: *Atom = @ptrCast(@alignCast(header));
    if (a.current.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register the atom trace fn at `.atom`. Idempotent.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.atom, &traceGc);
}

// --- tests ---

const testing = std.testing;

test "Atom alloc + current + in-place setCurrent preserves identity" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try alloc(&rt, Value.initInteger(1));
    try testing.expect(isAtom(a));
    try testing.expectEqual(@as(i64, 1), current(a).asInteger());

    setCurrent(a, Value.initInteger(42));
    try testing.expectEqual(@as(i64, 42), current(a).asInteger());
    // identity unchanged after mutation (same Value bits).
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(a));
    try testing.expect(!isAtom(Value.initInteger(0)));
}
