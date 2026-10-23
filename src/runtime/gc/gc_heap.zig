// SPDX-License-Identifier: EPL-2.0
//! Mark-sweep GC heap for cw v1: the `gc_alloc` layer of the 3-layer
//! allocator boundary per ADR-0028 §2 + F-006.
//!
//! Struct shape:
//!   - `allocations`: side-table of live heap-object records (header + size +
//!     alignment); see the `GcHeap` docstring for why a side-table beats an
//!     intrusive next-pointer.
//!   - `permanent_roots`: embedder-pinned root Values (`pin` / `unpin`).
//!   - `pages`: the size-classed page heap small cells live in, owned by
//!     `page_heap.zig` (empty pages go back to the OS after a collect).
//!   - `stats`: counters, shapes in `gc_types.zig`.
//!   - `infra`: backing GPA allocator (F-006 §2 layer 1).
//!   - the pressure counters + `threshold_bytes`: the collect trigger, whose
//!     policy lives in `gc_trigger.zig` (re-exposed here as methods).
//!
//! The `collect()` orchestrator lives in `mark_sweep.zig` to keep the import
//! graph acyclic (it reaches `root_set.zig`, which imports this file). Unit
//! tests are in `gc_heap_test.zig`.
//!
//! Thread-safety (ADR-0090 §2, F-006): `gc_mutex` (a `std.Io.Mutex`, locked
//! through the `io_default` singleton because the allocator API takes no `io`
//! arg) serializes `alloc` / `pin` / `unpin` and the whole `collect()` cycle.
//! Not reentrant: `alloc` never calls `collect` under the lock, and `collect`
//! never allocates through `alloc`, so the two lock-takers never nest.

const std = @import("std");

const heap_header = @import("../value/heap_header.zig");
const page_heap_mod = @import("page_heap.zig");
const value_mod = @import("../value/value.zig");
const io_default = @import("../concurrency/io_default.zig");
const safepoint = @import("../concurrency/safepoint.zig");
const root_set_mod = @import("root_set.zig");
const gc_types = @import("gc_types.zig");
const trigger = @import("gc_trigger.zig");

/// Reentrancy guard for the alloc-driven GC torture (D-386) and the trigger's
/// collects: a collect must not re-enter itself if the collector's own
/// bookkeeping reaches `alloc`. Threadlocal: each thread's cadence is
/// independent.
pub threadlocal var in_alloc_torture: bool = false;

// Fabrication no-collect region depth (D-244 #4, ADR-0150): the canonical
// docs + the variable live in `root_set.zig` (`fabrication_depth`).

const HeapHeader = heap_header.HeapHeader;
const PageHeap = page_heap_mod.PageHeap;
const Value = value_mod.Value;

pub const default_gc_threshold_bytes = trigger.default_gc_threshold_bytes;
pub const max_threshold_floor_bytes = trigger.max_threshold_floor_bytes;
pub const gc_time_target_percent = trigger.gc_time_target_percent;
pub const min_retained_bytes = trigger.min_retained_bytes;
pub const min_alloc_bytes = gc_types.min_alloc_bytes;
pub const PersistentMark = gc_types.PersistentMark;
pub const Stats = gc_types.Stats;
pub const AllocRecord = gc_types.AllocRecord;

/// Mark-sweep GC heap. Owns a list of tracked heap objects + the page heap;
/// the trigger threshold adapts to the last live-set measurement.
///
/// Live-list shape (5.3.b.1, depth 1): a **side-table**
/// `ArrayList(AllocRecord)` rather than an intrusive `next: ?*HeapHeader`
/// field. It (1) preserves ADR-0009's 8-byte HeapHeader invariant; (2)
/// matches cw v0 (only the mark BIT goes inline per ADR-0028 §6); (3) keeps
/// the sweep walk sequential through ArrayList memory. Each record carries
/// (size, alignment) so the free paths match what was allocated.
pub const GcHeap = struct {
    /// Backing allocator for raw heap memory: the process-lifetime GPA
    /// (`infra_alloc`, F-006 §2).
    infra: std.mem.Allocator,
    /// Side-table of live heap-object records. Append at alloc time;
    /// swap-remove during sweep for dead objects.
    allocations: std.ArrayList(gc_types.AllocRecord) = .empty,
    /// Embedder-pinned root Values per ADR-0028 §5 row 10 (FFI, test
    /// fixtures, the REPL buffer). The root walker yields each entry's
    /// `Value.heapHeader()`, skipping immediates.
    permanent_roots: std.ArrayList(Value) = .empty,
    /// D-556: analysis-produced Values persisted past their bracket (the
    /// literal pool of every analyzed form whose Nodes outlive the form).
    /// Appended by `root_set.endAnalysisPersist`; walked after
    /// `permanent_roots`.
    persisted_analysis_roots: std.ArrayList(Value) = .empty,
    /// Process-lifetime mark-waypoints (D-251): headers of `trackHeap`'d
    /// objects (`Function` / `ProtocolDescriptor` / `TypeDescriptorRef`) NOT
    /// in `allocations` and so never swept. Sweep never clears their mark
    /// bit, so `collect()` clears it at mark-phase start; otherwise `mark()`
    /// short-circuits from the 2nd collect on and strands their children.
    persistent_marks: std.ArrayList(gc_types.PersistentMark) = .empty,
    /// Total bytes registered with the persistent marks (D-573).
    persistent_bytes: usize = 0,
    /// Size-classed pages small cells live in (`page_heap.zig`). Sweep frees
    /// a dead small cell onto its page; after sweep, `collect` hands empty
    /// pages beyond `retainBytesAfterCollect` back to the OS.
    pages: PageHeap = .{},
    /// Bytes of live cells too large (or too aligned) for the page heap, held
    /// on `infra`. With `pages.mappedBytes()` this is the committed cell heap.
    large_live_bytes: usize = 0,
    /// Bytes of non-cell payload (a String's bytes, an array's elements, a
    /// transient vector's buffer, a BigInt's limbs) allocated on `infra` since
    /// the last collect, charged through `noteOwnedAlloc`. Counts toward the
    /// trigger beside `bytes_since_last_gc`: a 24 MB buffer behind a 40-byte
    /// cell is 24 MB of pressure. Atomic: a payload is allocated outside
    /// `gc_mutex`.
    owned_since_last_gc: std.atomic.Value(usize) = .init(0),
    /// Set by `requestCollect` (`System/gc`) so its collect releases empty
    /// pages down to `min_retained_bytes`. `collect` clears it.
    release_requested: bool = false,
    /// Gray worklist for the mark phase (ADR-0028 amendment 3): an explicit
    /// worklist so an arbitrarily deep graph marks with O(1) native stack.
    /// `collect()` reserves capacity up front; retained across collects.
    mark_worklist: std.ArrayList(*HeapHeader) = .empty,
    /// Allocation + collection counters.
    stats: gc_types.Stats = .{},
    /// Adaptive GC trigger threshold (pressure bytes since last collect).
    /// Recomputed at the end of each `collect()` (`gc_trigger.afterSweep`).
    threshold_bytes: usize = trigger.default_gc_threshold_bytes,
    /// D-519 (ADR-0164): persistent floor for the adaptive `threshold_bytes`,
    /// so a `CLJW_GC_THRESHOLD_MB` knob survives each collect's recompute.
    threshold_floor_bytes: usize = trigger.default_gc_threshold_bytes,
    /// The floor the steering may not go BELOW (default or the env knob).
    /// Steering moves `threshold_floor_bytes` between this and
    /// `max_threshold_floor_bytes`.
    base_threshold_floor_bytes: usize = trigger.default_gc_threshold_bytes,
    /// Cell bytes allocated since the last `collect()`.
    bytes_since_last_gc: usize = 0,
    /// True iff this heap is the `gc` field embedded in a `Runtime` (set by
    /// `Runtime.init`). `collect()` then reaches the Runtime via
    /// `@fieldParentPtr` to walk the descriptor registries (ADR-0184 B).
    runtime_embedded: bool = false,
    /// ADR-0125 / D-352: per-eval LIVE-heap ceiling in bytes. When non-null,
    /// `alloc` REFUSES any allocation that would push live bytes past it.
    /// Set by `runner.runSource` from `CLJW_EVAL_MAX_HEAP_MB`.
    heap_ceiling: ?usize = null,
    /// Installed by a higher layer (eval_budget, which may import the error
    /// catalog; gc_heap may not) to SET the catalog `eval_heap_exceeded` Info
    /// before the breach surfaces as `error.OutOfMemory`.
    heap_exceeded_hook: ?*const fn (cap: usize) void = null,
    /// Global heap lock (ADR-0090 §2).
    gc_mutex: std.Io.Mutex = .init,
    /// The heap's owning main thread (D-566, ADR-0175): the OS thread that ran
    /// `init`. Every other thread must be a registered worker before it
    /// allocates; `allocSized` asserts it.
    owner_thread_id: std.Thread.Id,

    pub const noteOwnedAlloc = trigger.noteOwnedAlloc;
    pub const pressureBytes = trigger.pressureBytes;
    pub const chargeInfraBytes = trigger.chargeInfraBytes;
    pub const retainBytesAfterCollect = trigger.retainBytesAfterCollect;
    pub const maybeAutoCollect = trigger.maybeAutoCollect;
    pub const requestCollect = trigger.requestCollect;
    pub const collectBeforeIdle = trigger.collectBeforeIdle;

    pub fn init(infra: std.mem.Allocator) GcHeap {
        const owner = root_set_mod.currentThreadId();
        root_set_mod.noteHeapOwner(owner);
        var g = GcHeap{ .infra = infra, .owner_thread_id = owner };
        // D-519 (ADR-0164): CLJW_GC_THRESHOLD_MB tunes the auto-collect floor.
        // Invalid / unset / 0 keeps the 4MB default. Process env is published
        // at startup (cli.zig) before the runtime is built.
        if (@import("../process_env.zig").get("CLJW_GC_THRESHOLD_MB")) |raw| {
            if (std.fmt.parseInt(usize, raw, 10) catch null) |mb| {
                if (mb > 0) {
                    g.threshold_floor_bytes = mb * 1024 * 1024;
                    g.base_threshold_floor_bytes = g.threshold_floor_bytes;
                    g.threshold_bytes = g.threshold_floor_bytes;
                }
            }
        }
        return g;
    }

    pub fn deinit(self: *GcHeap) void {
        // Diagnostic (D-450): CLJW_GC_STATS=1 prints the alloc/collect tallies
        // at teardown. Load-independent counts. Off by default.
        if (@import("../process_env.zig").get("CLJW_GC_STATS") != null) {
            const s = self.stats;
            std.debug.print("[gc-stats] allocs={d} small={d} large={d} collects={d} sweeps={d} bytes_alloc={d} last_live={d} floor_mb={d} gc_ms={d}\n", .{
                s.alloc_count,     s.small_allocs,                             s.alloc_count - s.small_allocs,
                s.collect_count,   s.sweep_count,                              s.bytes_allocated,
                s.last_live_bytes, self.threshold_floor_bytes / (1024 * 1024), s.gc_ns_total / std.time.ns_per_ms,
            });
            std.debug.print("[gc-stats] pages_now={d} pages_mapped={d} pages_released={d} large_live={d}\n", .{ self.pages.page_count, self.pages.pages_mapped_total, self.pages.pages_released_total, self.large_live_bytes });
            std.debug.print("[gc-stats] persistent_marks={d} persistent_bytes={d}\n", .{ self.persistent_marks.items.len, self.persistent_bytes });
        }
        // Finalise every live allocation (types owning non-GC resources get
        // their cleanup, the sweep contract of ADR-0028 §4), then free large
        // cells. Small cells need no per-cell free: their pages go back whole
        // in `pages.deinit`.
        const tag_ops = @import("tag_ops.zig");
        for (self.allocations.items) |rec| {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(@ptrCast(self), rec.header);
            }
            if (!page_heap_mod.isSmall(rec.size, rec.alignment)) {
                const mem = @as([*]u8, @ptrCast(rec.header))[0..rec.size];
                self.infra.rawFree(mem, rec.alignment, @returnAddress());
            }
        }
        self.allocations.deinit(self.infra);
        self.permanent_roots.deinit(self.infra);
        self.persisted_analysis_roots.deinit(self.infra);
        self.persistent_marks.deinit(self.infra);
        self.pages.deinit();
        self.mark_worklist.deinit(self.infra);
    }

    /// Register a process-lifetime mark-waypoint header (D-251), called by
    /// `Runtime.trackHeap` for every gpa-created, never-swept object whose
    /// trace may reach GC children. Header must be at offset 0 of `obj`.
    // GC-ROOT: D4 — process-lifetime trackHeap'd mark-waypoints (off gc.allocations); highest-risk moving-GC site [ref: .dev/gc_rooting.md §D]
    pub fn registerPersistentMark(self: *GcHeap, obj: *anyopaque, size: usize) !void {
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        try self.persistent_marks.append(self.infra, .{ .obj = obj, .size = size });
        self.persistent_bytes += size;
    }

    /// Roll back the most recent `registerPersistentMark` (`trackHeap`'s
    /// two-list atomicity on a failed second append).
    pub fn unregisterLastPersistentMark(self: *GcHeap) void {
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        if (self.persistent_marks.pop()) |m| self.persistent_bytes -= m.size;
    }

    /// Clear the mark bit on every registered process-lifetime waypoint, at
    /// mark-phase start (D-251). The cast happens here, not at registration,
    /// so a registration never alignment-checks a non-Value pointer.
    pub fn clearPersistentMarks(self: *GcHeap) void {
        for (self.persistent_marks.items) |m| {
            const hdr: *HeapHeader = @ptrCast(@alignCast(m.obj));
            hdr.gc_and_lock.gc_mark &= ~@as(u30, 1);
        }
    }

    /// Pin a Value so it stays alive across `collect()` cycles. Every `pin`
    /// pairs with an `unpin`. Immediates may be pinned; the walker filters.
    pub fn pin(self: *GcHeap, v: Value) !void {
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        try self.permanent_roots.append(self.infra, v);
    }

    /// Unpin the first matching Value. `false` if it was not pinned.
    pub fn unpin(self: *GcHeap, v: Value) bool {
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        for (self.permanent_roots.items, 0..) |entry, i| {
            if (entry == v) {
                _ = self.permanent_roots.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Enter a fabrication no-collect region (D-244 #4): a multi-alloc
    /// builder brackets its alloc sequence with this and `exitFabrication`.
    /// Nests. One threadlocal increment.
    pub fn enterFabrication(_: *GcHeap) void {
        root_set_mod.fabrication_depth += 1;
    }

    /// Leave a fabrication no-collect region.
    pub fn exitFabrication(_: *GcHeap) void {
        root_set_mod.fabrication_depth -= 1;
    }

    /// Allocate a typed heap object: page heap for a small cell, infra for a
    /// large one, with a comptime HeapHeader-at-offset-0 check. The caller
    /// initialises the value. The prologue CAN collect BEFORE the new object
    /// exists (peer STW park, D-386 torture, D-519 auto-collect), so a value
    /// held only in a Zig local across an `alloc` must be published as a root
    /// (`.dev/gc_rooting.md`). Size rounds up to `min_alloc_bytes`.
    pub fn alloc(self: *GcHeap, comptime T: type) !*T {
        return self.allocSized(T, @sizeOf(T));
    }

    /// ADR-0184: allocate `T` plus `tail_bytes` of trailing storage as ONE GC
    /// cell (a Function's methods + closure_bindings inline after the
    /// struct), so sweep frees a single allocation. `@sizeOf(T)` must be
    /// 8-aligned so a Value-bearing tail starts aligned.
    pub fn allocWithTail(self: *GcHeap, comptime T: type, tail_bytes: usize) !*T {
        comptime std.debug.assert(@sizeOf(T) % 8 == 0);
        return self.allocSized(T, @sizeOf(T) + tail_bytes);
    }

    /// True iff the calling thread may mutate this heap (D-566): a registered
    /// GC worker or the heap's owning main thread.
    pub fn mutatorAllowed(self: *const GcHeap) bool {
        return root_set_mod.is_registered_worker or root_set_mod.currentThreadId() == self.owner_thread_id;
    }

    fn allocSized(self: *GcHeap, comptime T: type, size: usize) !*T {
        comptime gc_types.assertHeaderAtOffsetZero(T);
        // D-566: an unregistered, non-owner allocator is caught here instead
        // of as a rare GP fault in a peer's root walk.
        std.debug.assert(self.mutatorAllowed());
        // Worker safe point (ADR-0090 Alt B / D-244 #4): if a peer is
        // collecting, park HERE, before contending on `gc_mutex`, so the
        // collector counts us parked. Our live Values are published and the
        // new obj does not exist yet. D-559 (ADR-0150 am1): the park honors
        // the fabrication region, since mid-bracket builder nodes live in
        // unrooted Zig locals; the thread parks at its next safepoint outside.
        if (root_set_mod.fabrication_depth == 0 and safepoint.gc_requested.load(.acquire)) safepoint.park();
        // D-386 alloc-driven GC torture (validation only; inert unless
        // CLJW_GC_TORTURE_ALLOC is armed). Forces a STW collect at the
        // mid-op alloc boundary so a VM op that did not publish its roots
        // before allocating surfaces as a deterministic UAF.
        torture: {
            const gc_torture = @import("gc_torture.zig");
            if (gc_torture.alloc_period == 0) break :torture;
            if (root_set_mod.fabrication_depth > 0) break :torture;
            if (root_set_mod.is_registered_worker or in_alloc_torture) break :torture;
            const e = root_set_mod.active_env orelse break :torture;
            if (!gc_torture.allocTick()) break :torture;
            const mark_sweep = @import("mark_sweep.zig");
            in_alloc_torture = true;
            defer in_alloc_torture = false;
            mark_sweep.collectStopTheWorld(self, .{ .envs = &.{e}, .gc = self }, false);
        }
        // D-519 (ADR-0164): threshold-driven auto-collect, the completeness
        // floor for a bulk Zig-primitive allocation that never crosses a VM
        // back-edge.
        self.maybeAutoCollect();
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        const align_t: std.mem.Alignment = .fromByteUnits(@alignOf(T));
        const effective_size: usize = @max(size, gc_types.min_alloc_bytes);

        // D-352: per-eval LIVE-heap ceiling, checked at the alloc boundary
        // because a Zig primitive can allocate megabytes without an eval
        // back-edge.
        if (self.heap_ceiling) |cap| {
            const live = self.stats.bytes_allocated - self.stats.bytes_freed;
            if (live + effective_size > cap) {
                if (self.heap_exceeded_hook) |hook| hook(cap);
                return error.OutOfMemory;
            }
        }

        const raw = try self.cellAlloc(effective_size, align_t);
        errdefer self.cellFree(raw, effective_size, align_t);

        const obj: *T = @ptrCast(@alignCast(raw));
        const hdr: *HeapHeader = @ptrCast(@alignCast(raw));
        try self.allocations.append(self.infra, .{
            .header = hdr,
            .size = effective_size,
            .alignment = align_t,
        });
        self.stats.bytes_allocated += effective_size;
        self.stats.alloc_count += 1;
        self.bytes_since_last_gc += effective_size;
        return obj;
    }

    /// Backing memory for one cell: a page-heap slot when the cell is small,
    /// an `infra` block otherwise. Caller holds `gc_mutex`.
    fn cellAlloc(self: *GcHeap, size: usize, alignment: std.mem.Alignment) error{OutOfMemory}![*]u8 {
        if (page_heap_mod.isSmall(size, alignment)) {
            self.stats.small_allocs += 1;
            return self.pages.alloc(size) orelse error.OutOfMemory;
        }
        const mem = self.infra.rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
        self.large_live_bytes += size;
        return mem;
    }

    /// Give one dead cell's memory back: to its page, or to `infra`. Called by
    /// sweep (inside the stop-the-world collect) and by `allocSized`'s errdefer.
    pub fn cellFree(self: *GcHeap, mem: [*]u8, size: usize, alignment: std.mem.Alignment) void {
        if (page_heap_mod.isSmall(size, alignment)) {
            self.pages.free(mem);
        } else {
            self.large_live_bytes -= size;
            self.infra.rawFree(mem[0..size], alignment, @returnAddress());
        }
    }

    /// The committed cell heap: mapped pages (live cells, free slots and
    /// retained empty pages) plus live large cells. `(.totalMemory r)` reports
    /// it; it shrinks when a collect releases pages.
    pub fn committedBytes(self: *const GcHeap) usize {
        return self.pages.mappedBytes() + self.large_live_bytes;
    }
};
