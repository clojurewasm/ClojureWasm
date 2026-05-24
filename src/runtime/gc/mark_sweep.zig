// SPDX-License-Identifier: EPL-2.0
//! Mark + sweep phases for cw v1 mark-sweep GC per ADR-0028 §1 + §4 + §5.
//!
//! **Phase 5 row 5.3.a skeleton.** Two stop-the-world phases declared:
//!   - `mark(gc, roots)` — visits every root, recursively traces
//!     through GC-managed pointers via `tag_ops.tag_trace_table`,
//!     sets `HeapHeader.gc_and_lock.mark` (bit 0) on every reached
//!     object. Mark recursion checks `header.gc_and_lock.mark == 1`
//!     before descending — cycle-mark invariant per ADR-0028 §5.
//!   - `sweep(gc)` — walks the live list. For every object with
//!     `mark == 0`: call per-tag finaliser via
//!     `tag_ops.tag_finaliser_table` (no-alloc invariant per ADR-0028
//!     §4), unlink from the live list, push onto the matching free
//!     pool. For every object with `mark == 1`: clear the bit and
//!     keep.
//!
//! Bodies are stubs at 5.3.a; 5.3.b lands the mark phase + root walk;
//! 5.3.c lands the sweep phase + finaliser dispatch + free-pool push.
//! `Code.gc_mark_not_supported` / `Code.gc_sweep_not_supported` are
//! the staged catalog Codes that 5.15 removes at the
//! `build_options.phase_at_least_5` flip per ADR-0017 amendment 1.

const std = @import("std");
const testing = std.testing;

const gc_heap_mod = @import("gc_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const tag_ops = @import("tag_ops.zig");

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;

/// Visit a heap object + recursively trace through its GC-managed
/// pointers. Sets `header.gc_and_lock.gc_mark` bit 0 on every reached
/// object. **Phase 5.3.b.2 body.**
///
/// Cycle invariant (per ADR-0028 §5 Mark cycle invariant): if the
/// header's mark bit is already set, return immediately — the bit
/// doubles as a visited flag during the mark phase. Cycles
/// (e.g. `LazySeq` whose `thunk` captures another `LazySeq` whose
/// `seq_cache` points back) terminate at the second visit.
///
/// Per-tag trace dispatch: `tag_ops.tag_trace_table[hdr.tag]` returns
/// the type-specific outgoing-pointer walker. Trace entries are
/// `null` at 5.3.b.2 (all entries get filled at 5.3.b.3 + during
/// the per-Tag activation rows 5.4–5.12), so mark behaves as a
/// leaf-node visit for every tag today — bit set + return.
pub fn mark(gc: *GcHeap, header: *HeapHeader) void {
    if (header.gc_and_lock.gc_mark & 1 == 1) return; // cycle invariant
    header.gc_and_lock.gc_mark |= 1;
    if (tag_ops.tag_trace_table[header.tag]) |trace_fn| {
        trace_fn(@ptrCast(gc), header);
    }
}

/// Reset the mark bit on every live allocation. Called by `collect()`
/// after sweep, so the next mark phase starts from a known-clean
/// state. (5.3.b.4 wires this into `GcHeap.collect()`; for now it
/// stands alone for test + the eventual call site.)
pub fn clearMarks(gc: *GcHeap) void {
    for (gc.allocations.items) |rec| {
        rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
    }
}

/// Walk the live list, finalise + recycle unreached objects, clear
/// marks on reached ones. **Phase 5.3.c.1 body.** Iterates
/// `gc.allocations` backward (so swap-remove indices stay valid).
/// For each record:
///   - mark bit 0 == 0 (dead): call per-tag finaliser via
///     `tag_ops.tag_finaliser_table` (no-alloc invariant per
///     ADR-0028 §4), `rawFree` the backing memory, swap-remove
///     from allocations, bump `bytes_freed` + `sweep_count`.
///   - mark bit 0 == 1 (live): clear the bit, sum into
///     `last_live_bytes` for the next adaptive-threshold cycle.
///
/// Direct rawFree at 5.3.c.1; 5.3.c.2 inserts the free-pool push
/// fast-path (`FreePoolMap.push`) before rawFree fallback, plus the
/// pop fast-path in `GcHeap.alloc`.
pub fn sweep(gc: *GcHeap) void {
    var live_bytes: usize = 0;
    var i: usize = gc.allocations.items.len;
    while (i > 0) {
        i -= 1;
        const rec = gc.allocations.items[i];
        const mark_bit: u30 = rec.header.gc_and_lock.gc_mark & 1;
        if (mark_bit == 0) {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(rec.header);
            }
            const mem = @as([*]u8, @ptrCast(rec.header))[0..rec.size];
            gc.infra.rawFree(mem, rec.alignment, @returnAddress());
            gc.stats.bytes_freed += rec.size;
            _ = gc.allocations.swapRemove(i);
        } else {
            rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
            live_bytes += rec.size;
        }
    }
    gc.stats.sweep_count += 1;
    gc.stats.last_live_bytes = live_bytes;
}

// --- tests ---

const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

test "mark sets gc_mark bit 0 on a leaf header" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.string) };
    try testing.expectEqual(@as(u30, 0), c.header.gc_and_lock.gc_mark);

    mark(&gc, &c.header);
    try testing.expectEqual(@as(u30, 1), c.header.gc_and_lock.gc_mark & 1);
}

test "mark cycle invariant: double-mark is idempotent" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    mark(&gc, &c.header);
    const after_first = c.header.gc_and_lock.gc_mark;
    mark(&gc, &c.header);
    const after_second = c.header.gc_and_lock.gc_mark;
    try testing.expectEqual(after_first, after_second);
}

test "clearMarks resets bit 0 on every live allocation" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.string) };
    const b = try gc.alloc(Cell);
    b.* = .{ .header = HeapHeader.init(.vector) };

    mark(&gc, &a.header);
    mark(&gc, &b.header);
    try testing.expect(a.header.gc_and_lock.gc_mark & 1 == 1);
    try testing.expect(b.header.gc_and_lock.gc_mark & 1 == 1);

    clearMarks(&gc);
    try testing.expectEqual(@as(u30, 0), a.header.gc_and_lock.gc_mark & 1);
    try testing.expectEqual(@as(u30, 0), b.header.gc_and_lock.gc_mark & 1);
}

test "clearMarks preserves bits 1..29 (only bit 0 is the mark)" {
    // Bits 1..29 are reserved per ADR-0028 §6 for tri-colour upgrade +
    // size_class (5.3 owner picks split). clearMarks must not touch
    // them; 5.3.b.2 only resets bit 0.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.string) };
    c.header.gc_and_lock.gc_mark = 0b101010101; // arbitrary non-bit-0 pattern + bit 0

    clearMarks(&gc);
    try testing.expectEqual(@as(u30, 0b101010100), c.header.gc_and_lock.gc_mark);
}

test "sweep removes unmarked allocations + frees their backing memory" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.string) };
    const b = try gc.alloc(Cell);
    b.* = .{ .header = HeapHeader.init(.vector) };
    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    // Mark only `a` and `c` as reachable; `b` is dead.
    mark(&gc, &a.header);
    mark(&gc, &c.header);

    sweep(&gc);

    try testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, 1), gc.stats.sweep_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.bytes_freed);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Cell)), gc.stats.last_live_bytes);

    // Survivors retain their tag and have mark bit reset to 0 (ready
    // for the next mark phase per the sweep contract).
    for (gc.allocations.items) |rec| {
        try testing.expectEqual(@as(u30, 0), rec.header.gc_and_lock.gc_mark & 1);
    }
}

test "sweep on empty heap is a no-op (bumps sweep_count, no panics)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    sweep(&gc);
    try testing.expectEqual(@as(u64, 1), gc.stats.sweep_count);
    try testing.expectEqual(@as(usize, 0), gc.stats.last_live_bytes);
}

test "sweep iterating backward keeps swap-remove indices valid" {
    // Allocate 5 cells; mark only the middle one (index 2). Sweep
    // should leave exactly that one allocation in place.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var survivor_addr: *HeapHeader = undefined;
    for (0..5) |idx| {
        const cell = try gc.alloc(Cell);
        cell.* = .{ .header = HeapHeader.init(.string) };
        if (idx == 2) {
            mark(&gc, &cell.header);
            survivor_addr = &cell.header;
        }
    }

    sweep(&gc);
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(survivor_addr, gc.allocations.items[0].header);
}
