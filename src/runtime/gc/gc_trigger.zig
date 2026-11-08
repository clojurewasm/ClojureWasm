// SPDX-License-Identifier: EPL-2.0
//! Collect-trigger policy for the mark-sweep heap: WHEN a collection runs and
//! how much of the freed heap it keeps mapped afterwards (ADR-0028 §1,
//! ADR-0164, D-573, CLJW-GC-HEAP-RETURN).
//!
//! `gc_heap.zig` owns the allocator state and `mark_sweep.zig` owns the
//! collection itself; this file owns the numbers that connect them:
//!   - the pressure counters (`noteOwnedAlloc`, `chargeInfraBytes`,
//!     `pressureBytes`) the trigger compares to `threshold_bytes`,
//!   - the two collect entry points the runtime calls (`maybeAutoCollect` at
//!     the alloc boundary and the VM back-edge, `requestCollect` for
//!     `System/gc`),
//!   - the post-sweep threshold recompute and the time-share floor steering,
//!   - the empty-page retention budget handed to `PageHeap.release`.
//!
//! `GcHeap` re-exposes the mutator-facing functions as methods (decl aliases),
//! so callers write `rt.gc.noteOwnedAlloc(n)`.

const std = @import("std");
const builtin = @import("builtin");
const gc_heap_mod = @import("gc_heap.zig");
const root_set_mod = @import("root_set.zig");

const GcHeap = gc_heap_mod.GcHeap;

/// Default GC trigger threshold (bytes since last collection), and the default
/// floor of the per-heap adaptive threshold. Adaptive at runtime:
/// `threshold = max(threshold_floor_bytes, last_live_bytes)` (ADR-0028 §1,
/// growth factor amended 2x to 1x by CLJW-PERF-GC-RETAIN, see `afterSweep`).
/// Raised 1MB to 4MB by ADR-0164/D-519: for a churn workload `last_live` is
/// about 0, so the floor IS the operative cadence; 4MB is a quarter of the
/// collects (same total sweep work, fewer STW fences) at ~3MB extra peak. Tune
/// via `CLJW_GC_THRESHOLD_MB`.
pub const default_gc_threshold_bytes: usize = 4 * 1024 * 1024;

/// Ceiling for the ramping floor (D-573). 64 MB is where the measured curve
/// knees: on the Rush Hour BFS, 4 MB -> 17.7 s, 16 MB -> 9.6 s, 64 MB -> 7.6 s,
/// 256 MB -> 7.1 s. Past 64 MB the remaining 6% costs 4x the resident heap,
/// which is the wrong trade for a runtime whose selling point is a small
/// footprint. `CLJW_GC_THRESHOLD_MB` still overrides the STARTING floor.
pub const max_threshold_floor_bytes: usize = 64 * 1024 * 1024;

/// Target share of wall clock spent collecting, as a percent (D-573).
///
/// The floor is steered by the MEASURED ratio rather than by a byte constant or
/// a collection count, because that ratio is the thing anyone cares about, and
/// because it is the quantity the theory is written in: for a mark-sweep
/// collector, GC share is `mark_cost(live) / bytes_between_collects`, so
/// raising the trigger lowers the share directly, independent of live size.
///
/// The JVM exposes exactly this as `-XX:GCTimeRatio` (about 1 % by default in
/// the throughput collector). 10 % is deliberately laxer: cljw's collector is
/// non-generational, so it re-marks the whole live set every time and cannot
/// reach 1 % without letting the heap grow far past what a small runtime
/// should hold. Measured motivation: a Rush Hour BFS with a 747 KB live set
/// spent 10.1 s of 17.9 s collecting, the 4 MB floor firing 755 times.
pub const gc_time_target_percent: u64 = 10;

/// Empty pages a collect always keeps mapped (CLJW-GC-HEAP-RETURN): 1 MiB, 16
/// pages, so a program that allocates a little after every `System/gc` does
/// not map and unmap the same pages each time.
pub const min_retained_bytes: usize = 1024 * 1024;

/// Charge `n` bytes of a cell's payload, allocated on `infra` outside the
/// cell, to the collect trigger (see `GcHeap.owned_since_last_gc`). An owner
/// whose payload can be large calls this where it allocates the payload. One
/// relaxed atomic add, no lock.
pub fn noteOwnedAlloc(gc: *GcHeap, n: usize) void {
    _ = gc.owned_since_last_gc.fetchAdd(n, .monotonic);
}

/// Allocation pressure since the last collect: cell bytes plus charged payload
/// bytes. The quantity the trigger compares to `threshold_bytes`.
pub fn pressureBytes(gc: *const GcHeap) usize {
    return gc.bytes_since_last_gc +| gc.owned_since_last_gc.load(.monotonic);
}

/// D-361: enforce the per-eval live-heap ceiling against a BULK `infra`
/// allocation that bypasses `alloc` (the transient vector's element buffer
/// grows via `gc.infra.realloc` and can reach hundreds of MB before
/// `persistent!` runs). On a memory-tight host that uncapped buffer
/// OS-OOM-kills the process first (the D-361 Linux symptom) instead of
/// surfacing the catchable `eval_heap_exceeded`. A bulk-infra site calls this
/// BEFORE allocating `infra_bytes`; it refuses (hook + OutOfMemory) when that
/// plus the current live gc bytes would exceed the cap. Per-eval is
/// single-threaded, so the read needs no gc_mutex. Admitted bytes are charged
/// to the collect trigger.
pub fn chargeInfraBytes(gc: *GcHeap, infra_bytes: usize) error{OutOfMemory}!void {
    if (gc.heap_ceiling) |cap| {
        const live = gc.stats.bytes_allocated - gc.stats.bytes_freed;
        if (live + infra_bytes > cap) {
            if (gc.heap_exceeded_hook) |hook| hook(cap);
            return error.OutOfMemory;
        }
    }
    noteOwnedAlloc(gc, infra_bytes);
}

/// Empty-page budget a collect keeps mapped after its sweep, the hysteresis
/// against map/unmap thrash. An automatic collect keeps up to one threshold's
/// worth: the next cycle allocates at most `threshold_bytes` before it
/// collects again, so that is the most fresh space it can use, and a page
/// beyond it would sit idle until the next release anyway. A steady-state
/// burst therefore refills its predecessor's pages instead of faulting in new
/// ones. A requested collect (`System/gc`) keeps only `min_retained_bytes`:
/// the program asked for the memory back.
pub fn retainBytesAfterCollect(gc: *const GcHeap, requested: bool) usize {
    if (requested) return min_retained_bytes;
    return @max(min_retained_bytes, gc.threshold_bytes);
}

/// The trigger for the next cycle: `max(floor, last_live)`, so the heap may
/// grow by one live set between collects (Go's `GOGC=100`). Peak committed
/// heap is about `live + threshold`, so the growth factor is the RSS lever:
/// at the former `2 * live`, a 482 MB live set peaked at 1.73 GB RSS; at
/// `1 * live` it peaks at 1.15 GB for 4 % more instructions. A smaller
/// share of the threshold RETAINED changes nothing (measured: the next cycle
/// maps the released pages again), because the peak is the fresh space the
/// cycle allocates, not the empty pages it keeps.
pub fn adaptiveThreshold(floor: usize, live: usize) usize {
    return @max(floor, live);
}

/// D-519 (ADR-0164): threshold-driven auto-collect during eval. Runs a STW
/// collect when pressure has passed `threshold_bytes`, at a quiescent-roots
/// boundary. Called from BOTH the `alloc` boundary (the completeness floor for
/// a bulk Zig-primitive allocation that never crosses a VM back-edge) AND the
/// VM back-edge poll (a `recur` loop back-edges every iteration but allocs
/// once). A collect resets the pressure counters, which keeps the two sites
/// idempotent. The guard set + collect are the `CLJW_GC_TORTURE_ALLOC` path,
/// gated on bytes instead of a torture period.
pub fn maybeAutoCollect(gc: *GcHeap) void {
    if (pressureBytes(gc) <= gc.threshold_bytes) return;
    collectIfSafe(gc);
}

/// `(System/gc)`: a user-REQUESTED collect (ADR-0174 D5). Same safety gates
/// as `maybeAutoCollect` without the byte threshold. The no-op arm is
/// JVM-faithful: `System.gc()` is specified as a hint, so a skipped collect
/// inside a fabrication region or off-worker context is correct. A requested
/// collect also returns the empty pages an automatic one keeps warm
/// (`retainBytesAfterCollect`); `collect` consumes the flag.
pub fn requestCollect(gc: *GcHeap) void {
    if (!collectSafeHere()) return;
    gc.release_requested = true;
    collectIfSafe(gc);
}

/// Allocation pressure below which `collectBeforeIdle` does nothing, so an
/// idle loop that allocates little pays no mark.
pub const idle_collect_min_bytes: usize = 1024 * 1024;

/// Collect while the mutator waits for input (a server between requests),
/// then hand freed malloc memory back to the OS. A no-op below
/// `idle_collect_min_bytes` of pressure. Same safety gates and page
/// release as `requestCollect`.
pub fn collectBeforeIdle(gc: *GcHeap) void {
    if (pressureBytes(gc) < idle_collect_min_bytes) return;
    requestCollect(gc);
    trimProcessHeap();
}

extern "c" fn malloc_trim(pad: usize) c_int;

/// Return glibc's free arena memory to the OS. Other allocators unmap large
/// frees themselves, so this is a no-op off glibc.
fn trimProcessHeap() void {
    if (comptime builtin.link_libc and builtin.target.abi.isGnu()) _ = malloc_trim(0);
}

/// True iff a stop-the-world collect may run on this thread right now: no
/// multi-alloc builder is mid-bracket (its intermediate nodes are
/// live-but-unrooted), this is not a registered worker, the collector is not
/// already running, and an env exists to root from.
fn collectSafeHere() bool {
    if (root_set_mod.fabrication_depth > 0) return false;
    if (root_set_mod.is_registered_worker or gc_heap_mod.in_alloc_torture) return false;
    return root_set_mod.active_env != null;
}

// `noinline`: maybeAutoCollect is inlined into the VM's per-op loop, and an
// inlined collect would put its whole frame on every `eval` re-entry's native
// stack (ADR-0195 budget). The call happens only past the threshold.
noinline fn collectIfSafe(gc: *GcHeap) void {
    if (!collectSafeHere()) return;
    const e = root_set_mod.active_env.?;
    const mark_sweep = @import("mark_sweep.zig");
    // Reentrancy guard: the collect's own bookkeeping must not re-trigger.
    gc_heap_mod.in_alloc_torture = true;
    defer gc_heap_mod.in_alloc_torture = false;
    mark_sweep.collectStopTheWorld(gc, .{ .envs = &.{e}, .gc = gc }, false);
}

/// End-of-collect bookkeeping, after sweep set `last_live_bytes`: recompute
/// the threshold, reset the pressure counters, release empty pages past the
/// retention budget (after the recompute, since the budget is one threshold's
/// worth).
///
/// The threshold is `adaptiveThreshold`, `max(threshold_floor_bytes,
/// last_live)`. The floor is the per-heap value (default, or
/// `CLJW_GC_THRESHOLD_MB`) so the knob survives this recompute; `steerFloor`
/// moves it between collects. For a churn workload `last_live` is about 0 and
/// the floor governs (ADR-0164); once the live set grows past the floor, the
/// adaptive arm takes over.
/// Measured on a Rush Hour BFS (3.17 GB over 26.2M allocations): 4 MB floor
/// 755 collections 17.7 s, 64 MB floor 47 collections 7.6 s, about 13 ms of
/// fixed cost per collect paid to reclaim a heap that was nearly all garbage.
pub fn afterSweep(gc: *GcHeap) void {
    gc.threshold_bytes = adaptiveThreshold(gc.threshold_floor_bytes, gc.stats.last_live_bytes);
    gc.bytes_since_last_gc = 0;
    gc.owned_since_last_gc.store(0, .monotonic);
    gc.stats.collect_count += 1;
    _ = gc.pages.release(retainBytesAfterCollect(gc, gc.release_requested));
    gc.release_requested = false;
}

/// Move `threshold_floor_bytes` toward whatever keeps the measured GC share at
/// `gc_time_target_percent` (D-573).
///
/// The share is `gc_ns_total / (now - first_collect_ns)`: wall clock since the
/// program first had to collect, the window the floor can influence. Over
/// target, double the floor, so twice as much garbage accumulates per
/// collection and the share roughly halves. Under target with room to spare,
/// ease back down, so a program whose live set shrank stops holding a floor it
/// no longer needs. Doubling/halving rather than solving: the share is a
/// lagging average, so a single-step solve would oscillate.
pub fn steerFloor(gc: *GcHeap, now_ns: i64) void {
    const elapsed = now_ns - gc.stats.first_collect_ns;
    // Below this there is no meaningful ratio yet: a first collection is 100 %
    // of the time since the first collection.
    if (elapsed < 50 * std.time.ns_per_ms) return;
    const share_pct = gc.stats.gc_ns_total * 100 / @as(u64, @intCast(elapsed));
    if (share_pct > gc_time_target_percent) {
        if (gc.threshold_floor_bytes < max_threshold_floor_bytes) {
            gc.threshold_floor_bytes = @min(max_threshold_floor_bytes, gc.threshold_floor_bytes *| 2);
        }
    } else if (share_pct * 4 < gc_time_target_percent and
        gc.threshold_floor_bytes > gc.base_threshold_floor_bytes)
    {
        gc.threshold_floor_bytes = @max(gc.base_threshold_floor_bytes, gc.threshold_floor_bytes / 2);
    }
}
