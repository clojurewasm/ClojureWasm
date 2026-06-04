// SPDX-License-Identifier: EPL-2.0
//! Mark + sweep phases for cw v1 mark-sweep GC per ADR-0028 §1 + §4 + §5.
//!
//! Two stop-the-world phases plus the `collect()` orchestrator:
//!   - `mark(gc, header)` — visits a root, recursively traces through
//!     GC-managed pointers via `tag_ops.tag_trace_table`, sets
//!     `HeapHeader.gc_and_lock.gc_mark` (bit 0) on every reached
//!     object. Mark recursion checks the bit before descending —
//!     cycle-mark invariant per ADR-0028 §5.
//!   - `sweep(gc)` — walks the live list. For every object with
//!     `mark == 0`: call per-tag finaliser via
//!     `tag_ops.tag_finaliser_table` (no-alloc invariant per ADR-0028
//!     §4), push onto the matching free pool (rawFree fallback),
//!     swap-remove from the live list. For every object with
//!     `mark == 1`: clear the bit and keep.
//!   - `collect(gc, ctx)` — enumerates roots via `root_set.enumerate`,
//!     marks each transitively, sweeps, then recomputes the adaptive
//!     `threshold_bytes` per ADR-0028 §1.
//!
//! `clearMarks(gc)` resets every live object's mark bit (used by tests
//! and reserved for an explicit clear pass). All four are landed.

const std = @import("std");
const testing = std.testing;

const gc_heap_mod = @import("gc_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const tag_ops = @import("tag_ops.zig");
const free_pool_mod = @import("free_pool.zig");
const root_set_mod = @import("root_set.zig");
const io_default = @import("../concurrency/io_default.zig");

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;

/// Visit a heap object + recursively trace through its GC-managed
/// pointers. Sets `header.gc_and_lock.gc_mark` bit 0 on every reached
/// object.
///
/// Cycle invariant (per ADR-0028 §5 Mark cycle invariant): if the
/// header's mark bit is already set, return immediately — the bit
/// doubles as a visited flag during the mark phase. Cycles
/// (e.g. `LazySeq` whose `thunk` captures another `LazySeq` whose
/// `seq_cache` points back) terminate at the second visit.
///
/// Per-tag trace dispatch: `tag_ops.tag_trace_table[hdr.tag]` returns
/// the type-specific outgoing-pointer walker, registered per-tag via
/// `tag_ops.registerTrace`. A `null` entry means a genuine leaf node
/// (e.g. `string`, `big_int` limb data) — mark sets the bit and
/// returns without descending.
pub fn mark(gc: *GcHeap, header: *HeapHeader) void {
    if (header.gc_and_lock.gc_mark & 1 == 1) return; // cycle invariant
    header.gc_and_lock.gc_mark |= 1;
    if (tag_ops.tag_trace_table[header.tag]) |trace_fn| {
        trace_fn(@ptrCast(gc), header);
    }
}

/// Reset the mark bit on every live allocation. `collect()` already
/// clears marks on surviving objects inline during `sweep`, so this
/// stands alone for tests and an explicit clear-pass caller.
pub fn clearMarks(gc: *GcHeap) void {
    for (gc.allocations.items) |rec| {
        rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
    }
}

/// Walk the live list, finalise + recycle unreached objects, clear
/// marks on reached ones. Iterates `gc.allocations` backward (so
/// swap-remove indices stay valid). For each record:
///   - mark bit 0 == 0 (dead): call per-tag finaliser via
///     `tag_ops.tag_finaliser_table` (no-alloc invariant per
///     ADR-0028 §4), push the backing memory onto the matching free
///     pool (`FreePoolMap.push`; rawFree fallback on push failure),
///     swap-remove from allocations, bump `bytes_freed` + `sweep_count`.
///   - mark bit 0 == 1 (live): clear the bit, sum into
///     `last_live_bytes` for the next adaptive-threshold cycle.
pub fn sweep(gc: *GcHeap) void {
    var live_bytes: usize = 0;
    var i: usize = gc.allocations.items.len;
    while (i > 0) {
        i -= 1;
        const rec = gc.allocations.items[i];
        const mark_bit: u30 = rec.header.gc_and_lock.gc_mark & 1;
        if (mark_bit == 0) {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(@ptrCast(gc), rec.header);
            }
            const mem: [*]u8 = @ptrCast(rec.header);
            const key = free_pool_mod.FreePoolKey{ .size = rec.size, .alignment = rec.alignment };
            // Push onto the matching free pool for reuse; fall through
            // to direct rawFree only if push fails (e.g. infra OOM
            // during HashMap getOrPut for a never-before-seen key).
            gc.free_pools.push(key, mem) catch {
                gc.infra.rawFree(mem[0..rec.size], rec.alignment, @returnAddress());
            };
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

/// Full mark-sweep collection cycle: enumerate every root via
/// `root_set.enumerate(ctx)`, mark each transitively (per-tag trace
/// dispatch handles outgoing pointers), sweep the live list
/// (per-tag finaliser → push onto free pool / direct rawFree
/// fallback), then update the adaptive threshold per ADR-0028 §1
/// (`threshold_bytes = max(default, last_live_bytes * 2)`) and
/// reset `bytes_since_last_gc`.
///
/// Callers invoke this directly rather than through a method on
/// `GcHeap` because the cycle traverses `root_set.zig` which itself
/// imports `gc_heap.zig` — the entry point lives here in
/// `mark_sweep.zig` to keep the import graph acyclic.
///
/// Adaptive-threshold semantics (per ADR-0028 §1 Load-bearing
/// concern #2 disposition): after sweep updates `stats.last_live_bytes`,
/// the next-trigger threshold is recomputed so it doubles on each
/// growth cycle. Prevents the "first def triggers a full GC mid-
/// load on a 4 MiB Clojure source" failure mode.
pub fn collect(gc: *GcHeap, ctx: root_set_mod.WalkContext) void {
    // Whole collection runs under the global heap lock (ADR-0090 §2): no
    // mutator can allocate while mark+sweep run. Not reentrant — mark/sweep
    // never allocate, so they do not re-take `gc_mutex`.
    io_default.lockMutex(&gc.gc_mutex);
    defer io_default.unlockMutex(&gc.gc_mutex);
    var it = root_set_mod.enumerate(ctx);
    while (it.next()) |root_header| {
        mark(gc, root_header);
    }
    sweep(gc);
    gc.threshold_bytes = @max(
        gc_heap_mod.default_gc_threshold_bytes,
        gc.stats.last_live_bytes *| 2,
    );
    gc.bytes_since_last_gc = 0;
    gc.stats.collect_count += 1;
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

test "collect: pinned roots survive; unpinned allocations get swept" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const cell_kept = try gc.alloc(Cell);
    cell_kept.* = .{ .header = HeapHeader.init(.string) };
    const cell_dropped = try gc.alloc(Cell);
    cell_dropped.* = .{ .header = HeapHeader.init(.vector) };

    const value_mod_test = @import("../value/value.zig");
    try gc.pin(value_mod_test.Value.encodeHeapPtr(.string, cell_kept));

    const before_alloc_count = gc.allocations.items.len;
    try testing.expectEqual(@as(usize, 2), before_alloc_count);

    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, 1), gc.stats.collect_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.last_live_bytes);
    try testing.expectEqual(@as(usize, 0), gc.bytes_since_last_gc);
    try testing.expectEqual(@as(*HeapHeader, @ptrCast(cell_kept)), gc.allocations.items[0].header);
}

test "collect: adaptive threshold = max(default, last_live_bytes * 2)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    // No live allocations → last_live_bytes = 0 → threshold stays at default.
    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(gc_heap_mod.default_gc_threshold_bytes, gc.threshold_bytes);

    // Pin a heap Value so it survives the cycle. last_live_bytes = sizeOf(Cell);
    // since 2 * sizeOf(Cell) is far below default, threshold still stays at default.
    const cell = try gc.alloc(Cell);
    cell.* = .{ .header = HeapHeader.init(.list) };
    const value_mod_test = @import("../value/value.zig");
    try gc.pin(value_mod_test.Value.encodeHeapPtr(.list, cell));

    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.last_live_bytes);
    try testing.expectEqual(gc_heap_mod.default_gc_threshold_bytes, gc.threshold_bytes);
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
