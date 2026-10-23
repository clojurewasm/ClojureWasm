// SPDX-License-Identifier: EPL-2.0
//! Mark + sweep phases for cw v1 mark-sweep GC per ADR-0028 §1 + §4 + §5.
//!
//! Two stop-the-world phases plus the `collect()` orchestrator:
//!   - `mark(gc, header)`: shades an object gray: sets
//!     `HeapHeader.gc_and_lock.gc_mark` (bit 0) and pushes non-leaf headers
//!     onto `gc.mark_worklist` (ADR-0028 amendment 3: the prior recursive
//!     descent overflowed the native stack on deep cons chains). The bit
//!     doubles as the visited flag (cycle-mark invariant, ADR-0028 §5).
//!   - `drainGray(gc)`: blackens the worklist via the per-tag trace fns.
//!   - `sweep(gc)`: finalises and frees every unmarked object
//!     (`GcHeap.cellFree`: its page, or infra), clears the bit on the rest.
//!   - `collect(gc, ctx)`: roots, mark, drain, sweep, then the trigger
//!     bookkeeping (`gc_trigger.afterSweep`: threshold recompute, counter
//!     reset, empty-page release).
//!
//! The conservative native-stack scan is `conservative_scan.zig`; the trigger
//! policy is `gc_trigger.zig`; unit tests are `mark_sweep_test.zig`.

const std = @import("std");
const clock = @import("../clock.zig");

const gc_heap_mod = @import("gc_heap.zig");
const heap_header = @import("../value/heap_header.zig");
const tag_ops = @import("tag_ops.zig");
const root_set_mod = @import("root_set.zig");
const io_default = @import("../concurrency/io_default.zig");
const safepoint = @import("../concurrency/safepoint.zig");
const lock_tx = @import("../concurrency/lock_tx.zig");
const trigger = @import("gc_trigger.zig");
const ConservativeScan = @import("conservative_scan.zig").ConservativeScan;

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;

/// Adapter so `lock_tx.markRoots` can call back into `mark` with the GcHeap as
/// an opaque context (avoids a lock_tx -> mark_sweep import).
fn markTxHeader(ctx: *anyopaque, header: *HeapHeader) void {
    const gc: *GcHeap = @ptrCast(@alignCast(ctx));
    mark(gc, header);
}

/// Adapter for `root_set.markRegisteredTxs`: cast the opaque `current_tx`
/// back to a transaction and mark its in-txn roots, once per registered
/// worker thread during a collect (#4a' in-txn-map rooting).
fn markWorkerTx(ctx: *anyopaque, tx_opaque: ?*anyopaque) void {
    const gc: *GcHeap = @ptrCast(@alignCast(ctx));
    const tx_any = tx_opaque orelse return;
    const tx: *lock_tx.LockingTransaction = @ptrCast(@alignCast(tx_any));
    lock_tx.markRoots(tx, @ptrCast(gc), &markTxHeader);
}

// CLJW_GC_STATS=3: cumulative per-phase collect time, printed per collect.
// The diagnostic that attributed D-450's ~24ms-per-collect fixed cost to the
// prep phase; kept because the next attribution will want it. ~5 clock reads
// per collect.
var phase_prep_ns: u64 = 0;
var phase_roots_ns: u64 = 0;
var phase_scan_ns: u64 = 0;
var phase_drain_ns: u64 = 0;
var phase_sweep_ns: u64 = 0;

/// Shade a heap object gray: set mark bit 0 and push the header onto
/// `gc.mark_worklist` for `drainGray` to blacken.
///
/// Cycle invariant (ADR-0028 §5): an already-set bit returns immediately.
///
/// LOAD-BEARING ordering: the bit is set BEFORE the push. Push-before-bit
/// would let a failed push leave a marked-looking-but-untraced object, so a
/// live child could be swept (UAF). Bit-before-push also bounds the worklist:
/// each object enters at most once, so `collect()` reserves capacity up front
/// and the in-collect append never allocates.
///
/// A `null` `tag_trace_table` entry is a leaf (`string`, `big_int`): the bit
/// is set and nothing is pushed.
pub fn mark(gc: *GcHeap, header: *HeapHeader) void {
    if (header.gc_and_lock.gc_mark & 1 == 1) return; // cycle invariant
    header.gc_and_lock.gc_mark |= 1;
    if (tag_ops.tag_trace_table[header.tag] == null) return; // leaf
    // In-collect this never allocates (capacity reserved). A direct caller
    // outside collect (unit tests) may grow it; infra OOM here is
    // unrecoverable, since continuing would sweep unmarked live children.
    gc.mark_worklist.append(gc.infra, header) catch
        @panic("GC mark: gray worklist allocation failed");
}

/// Blacken the gray worklist: pop headers and run their per-tag trace fn
/// (which shades children gray via `mark`) until empty. Direct `mark()`
/// callers outside collect must call this to get transitive marking.
pub fn drainGray(gc: *GcHeap) void {
    while (gc.mark_worklist.pop()) |header| {
        // Only non-leaf headers are ever pushed, so the table entry is set.
        tag_ops.tag_trace_table[header.tag].?(@ptrCast(gc), header);
    }
}

/// Reset the mark bit on every live allocation. `sweep` already clears it on
/// survivors; this stands alone for tests and an explicit clear pass.
pub fn clearMarks(gc: *GcHeap) void {
    for (gc.allocations.items) |rec| {
        rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
    }
}

/// Walk the live list backward (swap-remove indices stay valid). Dead
/// (bit 0 clear): per-tag finaliser (no-alloc invariant, ADR-0028 §4), free
/// the cell, swap-remove, bump `bytes_freed`. Live: clear the bit and sum its
/// record + owned bytes into `last_live_bytes`.
pub fn sweep(gc: *GcHeap) void {
    // CLJW_GC_STATS=2: per-tag owned-bytes breakdown of the LIVE set, printed
    // per sweep (the diagnostic that found the D-573 numbers).
    const debug_owned = if (@import("../process_env.zig").get("CLJW_GC_STATS")) |v| std.mem.eql(u8, v, "2") else false;
    var owned_by_tag: [64]usize = @splat(0);
    var count_by_tag: [64]usize = @splat(0);
    var live_bytes: usize = 0;
    var i: usize = gc.allocations.items.len;
    while (i > 0) {
        i -= 1;
        const rec = gc.allocations.items[i];
        if (rec.header.gc_and_lock.gc_mark & 1 == 0) {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(@ptrCast(gc), rec.header);
            }
            // Never fails: a page free is a list push into memory the page
            // already owns.
            gc.cellFree(@ptrCast(rec.header), rec.size, rec.alignment);
            gc.stats.bytes_freed += rec.size;
            _ = gc.allocations.swapRemove(i);
        } else {
            rec.header.gc_and_lock.gc_mark &= ~@as(u30, 1);
            live_bytes += rec.size;
            // D-573: count what the object OWNS (a String's bytes, a BigInt's
            // limbs, an array's elements), not just its record block.
            if (tag_ops.tag_owned_bytes_table[rec.header.tag]) |owned| {
                const n = owned(rec.header);
                live_bytes += n;
                if (debug_owned) {
                    owned_by_tag[rec.header.tag] += n;
                    count_by_tag[rec.header.tag] += 1;
                }
            }
        }
    }
    if (debug_owned) {
        for (owned_by_tag, 0..) |n, tag| {
            if (n > 0) std.debug.print("[gc-owned] tag={d} count={d} bytes={d}\n", .{ tag, count_by_tag[tag], n });
        }
        std.debug.print("[gc-owned] persistent_bytes={d}\n", .{gc.persistent_bytes});
    }
    gc.stats.sweep_count += 1;
    // Deliberately EXCLUDES `gc.persistent_bytes`. The byte arm sizes the
    // threshold against the SWEPT heap; the time-share arm (ADR-0183
    // steerFloor) absorbs the cost of the re-traced process-lifetime
    // waypoints. Folding them in was measured to regress gc_alloc_rate ~11%
    // (ADR-0164's finding).
    gc.stats.last_live_bytes = live_bytes;
}

/// Full mark-sweep collection cycle: enumerate every root, mark
/// transitively, sweep, then `gc_trigger.afterSweep` (threshold
/// `max(floor, last_live * 2)`, counter reset, empty-page release).
///
/// The entry point lives here rather than on `GcHeap` because the cycle
/// traverses `root_set.zig`, which imports `gc_heap.zig`.
pub fn collect(gc: *GcHeap, ctx: root_set_mod.WalkContext) void {
    // The whole collection runs under the global heap lock (ADR-0090 §2).
    // Mark/sweep never allocate through `gc.alloc`; the gray worklist's
    // capacity is reserved here before any mark bit is set.
    const t_entry = clock.nanoTime(io_default.get());
    io_default.lockMutex(&gc.gc_mutex);
    defer io_default.unlockMutex(&gc.gc_mutex);
    // Bit-set-at-push bounds the worklist by `allocations + persistent_marks`
    // (infra-lifetime singletons add a handful; `mark`'s fallible append
    // absorbs them). A failed reserve aborts BEFORE any bit is set: heap
    // intact, the pressure resurfaces as OOM at the next `gc.alloc`.
    gc.mark_worklist.ensureTotalCapacity(
        gc.infra,
        gc.allocations.items.len + gc.persistent_marks.items.len,
    ) catch return;
    // D-251: re-trace the never-swept waypoints this cycle.
    gc.clearPersistentMarks();
    const t_prep = clock.nanoTime(io_default.get());
    phase_prep_ns +|= @intCast(@max(0, t_prep - t_entry));
    var it = root_set_mod.enumerate(ctx);
    while (it.next()) |root_header| {
        mark(gc, root_header);
    }
    // #4a' in-txn-map rooting: the collecting thread's `dosync` body may hold
    // live Values only in `current_tx`'s maps.
    if (lock_tx.current_tx) |tx| lock_tx.markRoots(tx, @ptrCast(gc), &markTxHeader);
    // ...and every registered WORKER thread's transaction (parked, quiescent).
    root_set_mod.markRegisteredTxs(@ptrCast(gc), &markWorkerTx);
    // ADR-0184 B: descriptor-registry roots, only on a Runtime-embedded heap.
    if (gc.runtime_embedded) {
        const rt: *@import("../runtime.zig").Runtime = @alignCast(@fieldParentPtr("gc", gc));
        @import("../type_descriptor.zig").markRegistryRoots(rt, gc);
    }
    // D-556: conservative native-stack scan of the COLLECTING thread (tree_walk
    // only). Parked workers need none: a park cannot fire inside a fabrication
    // bracket (D-559), so their Values are published. Residual: tree_walk eval
    // running ON A WORKER (the D-556 residual).
    const t_scan0 = clock.nanoTime(io_default.get());
    phase_roots_ns +|= @intCast(@max(0, t_scan0 - t_prep));
    ConservativeScan.run(gc);
    const t_scan1 = clock.nanoTime(io_default.get());
    drainGray(gc);
    const t_drain = clock.nanoTime(io_default.get());
    sweep(gc);
    const t_sweep = clock.nanoTime(io_default.get());
    phase_scan_ns +|= @intCast(@max(0, t_scan1 - t_scan0));
    phase_drain_ns +|= @intCast(@max(0, t_drain - t_scan1));
    phase_sweep_ns +|= @intCast(@max(0, t_sweep - t_drain));
    if (@import("../process_env.zig").get("CLJW_GC_STATS")) |v| {
        if (std.mem.eql(u8, v, "3"))
            std.debug.print("[gc-phases] prep_ms={d} roots_ms={d} scan_ms={d} drain_ms={d} sweep_ms={d} (cum)\n", .{ phase_prep_ns / 1_000_000, phase_roots_ns / 1_000_000, phase_scan_ns / 1_000_000, phase_drain_ns / 1_000_000, phase_sweep_ns / 1_000_000 });
    }
    trigger.afterSweep(gc);
}

/// Stop-the-world collect (ADR-0090 Alt B / D-244 #4): pause every other
/// registered worker at a safe point, run `collect` over the union root set,
/// resume them, then steer the floor by the measured GC share (D-573).
///
/// The caller MUST NOT hold `gc_mutex` (`collect` re-takes it; `Io.Mutex` is
/// not reentrant). `self_registered` excludes the calling thread from the
/// park target. With no other registered workers this is `collect` with a
/// no-op fence.
pub fn collectStopTheWorld(gc: *GcHeap, ctx: root_set_mod.WalkContext, self_registered: bool) void {
    const started = clock.nanoTime(io_default.get());
    safepoint.stopWorld(self_registered);
    collect(gc, ctx);
    safepoint.resumeWorld();
    const ended = clock.nanoTime(io_default.get());
    gc.stats.gc_ns_total +|= @intCast(@max(0, ended - started));
    if (gc.stats.first_collect_ns == 0) gc.stats.first_collect_ns = started;
    trigger.steerFloor(gc, ended);
}
