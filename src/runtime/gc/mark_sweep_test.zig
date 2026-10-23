// SPDX-License-Identifier: EPL-2.0
//! Unit tests for `mark_sweep.zig` and the collect-side of `gc_trigger.zig`:
//! mark bits, sweep, collect rooting (pins, transactions), the adaptive
//! threshold, page release, payload charging, and deep-graph marking.

const std = @import("std");
const testing = std.testing;

const gc_heap_mod = @import("gc_heap.zig");
const page_heap_mod = @import("page_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const mark_sweep = @import("mark_sweep.zig");

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;
const mark = mark_sweep.mark;
const drainGray = mark_sweep.drainGray;
const clearMarks = mark_sweep.clearMarks;
const sweep = mark_sweep.sweep;
const collect = mark_sweep.collect;

const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

test "mark sets gc_mark bit 0 on a leaf header" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.symbol) };
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
    a.* = .{ .header = HeapHeader.init(.symbol) };
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
    c.* = .{ .header = HeapHeader.init(.symbol) };
    c.header.gc_and_lock.gc_mark = 0b101010101; // arbitrary non-bit-0 pattern + bit 0

    clearMarks(&gc);
    try testing.expectEqual(@as(u30, 0b101010100), c.header.gc_and_lock.gc_mark);
}

test "sweep removes unmarked allocations + frees their backing memory" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.symbol) };
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
    cell_kept.* = .{ .header = HeapHeader.init(.symbol) };
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

test "collect: in-transaction vals values survive (#4a' self-tx rooting)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const value_mod_test = @import("../value/value.zig");
    const lock_tx_mod = @import("../concurrency/lock_tx.zig");
    const Ref = @import("../stm/ref.zig").Ref;

    // A heap value that lives ONLY in the transaction's vals cache: on no
    // operand stack, not pinned. Without the #4a' tx-rooting it would be swept.
    const in_tx_cell = try gc.alloc(Cell);
    in_tx_cell.* = .{ .header = HeapHeader.init(.vector) };
    const in_tx_val = value_mod_test.Value.encodeHeapPtr(.vector, in_tx_cell);

    var tx: lock_tx_mod.LockingTransaction = .{ .read_point = 0, .gpa = testing.allocator };
    defer tx.vals.deinit(testing.allocator);
    // A fake (never-dereferenced) Ref key: markRoots reads only the VALUES.
    const fake_ref: *Ref = @ptrFromInt(@alignOf(Ref) * 4096);
    try tx.vals.put(testing.allocator, fake_ref, in_tx_val);

    lock_tx_mod.current_tx = &tx;
    defer lock_tx_mod.current_tx = null;

    collect(&gc, .{ .envs = &.{}, .gc = &gc });

    var found = false;
    for (gc.allocations.items) |a| {
        if (a.header == @as(*HeapHeader, @ptrCast(in_tx_cell))) found = true;
    }
    try testing.expect(found); // survived ONLY via the in-transaction rooting
}

test "collect: a registered worker's transaction roots survive (#4a' worker-tx)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const value_mod_test = @import("../value/value.zig");
    const lock_tx_mod = @import("../concurrency/lock_tx.zig");
    const root_set_test = @import("root_set.zig");
    const env_mod_test = @import("../env.zig");
    const Ref = @import("../stm/ref.zig").Ref;

    const in_tx_cell = try gc.alloc(Cell);
    in_tx_cell.* = .{ .header = HeapHeader.init(.vector) };
    const in_tx_val = value_mod_test.Value.encodeHeapPtr(.vector, in_tx_cell);

    var worker_tx: lock_tx_mod.LockingTransaction = .{ .read_point = 0, .gpa = testing.allocator };
    defer worker_tx.vals.deinit(testing.allocator);
    const fake_ref: *Ref = @ptrFromInt(@alignOf(Ref) * 4096);
    try worker_tx.vals.put(testing.allocator, fake_ref, in_tx_val);

    // A registered worker whose current_tx is worker_tx (the MAIN thread's
    // current_tx stays null, so only the worker-tx pass can root in_tx_cell).
    var worker_current_tx: ?*lock_tx_mod.LockingTransaction = &worker_tx;
    var ctx: root_set_test.ThreadGcContext = .{
        .frame_slot = &env_mod_test.current_frame,
        .analysis_frame_slot = &root_set_test.analysis_frame_head,
        .eval_frame_slot = &root_set_test.eval_frame_head,
        .self_guard_slot = &root_set_test.gc_self_guard,
        .tx_slot = @ptrCast(&worker_current_tx),
    };
    try root_set_test.registerThread(&ctx);
    defer root_set_test.unregisterThread(&ctx);

    collect(&gc, .{ .envs = &.{}, .gc = &gc });

    var found = false;
    for (gc.allocations.items) |a| {
        if (a.header == @as(*HeapHeader, @ptrCast(in_tx_cell))) found = true;
    }
    try testing.expect(found); // survived via the registered worker's tx rooting
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

test "collect: dead cells' pages go back to the OS past the retention budget (CLJW-GC-HEAP-RETURN)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    // 200k unrooted 16-byte cells: ~49 pages, past the 16-page minimum budget.
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        const c = try gc.alloc(Cell);
        c.* = .{ .header = HeapHeader.init(.symbol) };
    }
    const mapped = gc.pages.page_count;
    try testing.expect(mapped * page_heap_mod.page_bytes > gc_heap_mod.min_retained_bytes);
    try testing.expect(gc.committedBytes() >= 200_000 * @sizeOf(Cell));

    // An automatic collect keeps one threshold's worth of empty pages warm.
    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try testing.expect(gc.pages.mappedBytes() <= @max(gc.threshold_bytes, gc_heap_mod.min_retained_bytes));

    // A requested collect gives back all but the minimum.
    gc.release_requested = true;
    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expect(!gc.release_requested);
    try testing.expect(gc.pages.mappedBytes() <= gc_heap_mod.min_retained_bytes);
    try testing.expect(gc.pages.pages_released_total >= mapped - gc_heap_mod.min_retained_bytes / page_heap_mod.page_bytes);

    // The retained pages serve the next allocations without mapping more.
    const kept = gc.pages.page_count;
    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.symbol) };
    try testing.expectEqual(kept, gc.pages.page_count);
}

test "collect trigger counts charged payload bytes, and collect resets them" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    try testing.expectEqual(@as(usize, 0), gc.pressureBytes());
    gc.noteOwnedAlloc(gc.threshold_bytes + 1);
    try testing.expect(gc.pressureBytes() > gc.threshold_bytes);
    try gc.chargeInfraBytes(8);
    try testing.expectEqual(gc.threshold_bytes + 9, gc.pressureBytes());
    collect(&gc, .{ .envs = &.{}, .gc = &gc });
    try testing.expectEqual(@as(usize, 0), gc.pressureBytes());
}

test "sweep iterating backward keeps swap-remove indices valid" {
    // Allocate 5 cells; mark only the middle one (index 2). Sweep
    // should leave exactly that one allocation in place.
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var survivor_addr: *HeapHeader = undefined;
    for (0..5) |idx| {
        const cell = try gc.alloc(Cell);
        cell.* = .{ .header = HeapHeader.init(.symbol) };
        if (idx == 2) {
            mark(&gc, &cell.header);
            survivor_addr = &cell.header;
        }
    }

    sweep(&gc);
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(survivor_addr, gc.allocations.items[0].header);
}

test "mark bounds native stack on a deep cons chain (explicit worklist)" {
    // A ~1M-deep cons chain: per-child recursive descent would need ~1M
    // native frames and SIGSEGVs (the `(count (repeat 1000000 1))` crash);
    // the explicit worklist keeps mark's stack depth O(1).
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();
    const list_mod = @import("../collection/list.zig");
    const value_mod = @import("../value/value.zig");
    const Value = value_mod.Value;
    list_mod.registerGcHooks();

    var tail: Value = .nil_val;
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        const cell = try gc.alloc(list_mod.Cons);
        cell.* = .{
            .header = HeapHeader.init(.list),
            .first = .nil_val,
            .rest = tail,
            .meta = .nil_val,
            .count = i + 1,
        };
        tail = Value.encodeHeapPtr(.list, cell);
    }

    mark(&gc, tail.heapHeader().?);
    drainGray(&gc);
    // The deep end (first-allocated cell) must have been reached.
    try testing.expectEqual(@as(u30, 1), gc.allocations.items[0].header.gc_and_lock.gc_mark & 1);
}

test "sweep counts finaliser-owned bytes via the per-tag hook (D-573)" {
    // Register the real string hook, as Runtime.init does.
    const string_mod = @import("../collection/string.zig");
    string_mod.registerGcHooks();

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const payload_len = 1000;
    const payload = try gc.infra.alloc(u8, payload_len);
    const s = try gc.alloc(string_mod.String);
    s.* = .{
        .header = HeapHeader.init(.string),
        .bytes_ptr = payload.ptr,
        .bytes_len = payload_len,
    };

    mark(&gc, &s.header);
    sweep(&gc);

    // The record block alone was the OLD number: the 4.6x under-report. The
    // honest number includes the byte payload the finaliser would free.
    try testing.expectEqual(@sizeOf(string_mod.String) + payload_len, gc.stats.last_live_bytes);
}

test "persistent bytes are measured but NOT folded into last_live (D-573)" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var waypoint: extern struct { header: HeapHeader = HeapHeader.init(.symbol), payload: u64 = 0 } = .{};
    try gc.registerPersistentMark(@ptrCast(&waypoint), 4096);
    try testing.expectEqual(@as(usize, 4096), gc.persistent_bytes);

    const a = try gc.alloc(Cell);
    a.* = .{ .header = HeapHeader.init(.symbol) };
    mark(&gc, &a.header);
    sweep(&gc);

    // The byte arm sizes against the SWEPT heap only; the waypoints' cost
    // belongs to the time-share arm (see sweep()'s comment: folding them in
    // was measured to starve the free pool and regress gc_alloc_rate ~11%).
    try testing.expectEqual(@sizeOf(Cell), gc.stats.last_live_bytes);

    gc.unregisterLastPersistentMark();
    try testing.expectEqual(@as(usize, 0), gc.persistent_bytes);
}
