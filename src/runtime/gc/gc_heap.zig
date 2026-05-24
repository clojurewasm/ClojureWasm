// SPDX-License-Identifier: EPL-2.0
//! Mark-sweep GC heap for cw v1 — `gc_alloc` layer of the 3-layer
//! allocator boundary per ADR-0028 §2 + F-006.
//!
//! **Phase 5 row 5.3.a skeleton.** The struct shape lands here:
//!   - `live_head` — singly-linked list of live heap objects, threaded
//!     through `HeapHeader._pad` (5.3.b wires the link field).
//!   - `free_pools` — per-(size, alignment) free pool head map, owned
//!     by `runtime/gc/free_pool.zig`.
//!   - `stats` — bytes_allocated / collect_count / sweep_count.
//!   - `infra` — backing GPA allocator (per F-006 §2 layer 1) for the
//!     raw heap pages this `GcHeap` operates over.
//!   - `bytes_since_last_gc` + `last_live_bytes` — drives the adaptive
//!     `collect()` trigger per ADR-0028 §1.
//!
//! Behaviour-bearing methods are stubs that raise
//! `Code.gc_alloc_not_supported` per `no_op_stub_forbidden.md`'s
//! explicit-error pattern. 5.3.b lands the mark phase + alloc body;
//! 5.3.c lands sweep + free-pool recycling; 5.3.d migrates Phase 1-4
//! alloc sites from `gpa.create(T)` to `gc.alloc(T)` and removes the
//! `gc_*_not_supported` Codes per ADR-0017 amendment 1.
//!
//! Thread-safety: Phase 5 single-threaded; the mutex hook lives behind
//! `gc_mutex: std.Io.Mutex = .init` (declared but not consulted) so
//! Phase 15 STM activation can flip the lock-bracket on without a
//! struct migration. See ADR-0028 §1 concurrency paragraph.

const std = @import("std");
const testing = std.testing;

const heap_header = @import("../value/heap_header.zig");
const free_pool_mod = @import("free_pool.zig");

const HeapHeader = heap_header.HeapHeader;
const FreePoolMap = free_pool_mod.FreePoolMap;

/// Default GC trigger threshold (bytes since last collection).
/// Adaptive at runtime: `threshold = max(default, last_live_bytes * 2)`
/// per ADR-0028 §1 Load-bearing-concern #2 disposition.
pub const default_gc_threshold_bytes: usize = 1 * 1024 * 1024;

/// Allocation + collection statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    alloc_count: u64 = 0,
    collect_count: u64 = 0,
    sweep_count: u64 = 0,
    last_live_bytes: usize = 0,
};

/// Mark-sweep GC heap. Owns a list of tracked heap objects + per-size
/// free pools; trigger threshold adapts based on the last live-set
/// measurement.
pub const GcHeap = struct {
    /// Backing allocator for raw heap pages. Per F-006 §2 this is the
    /// process-lifetime GPA (`infra_alloc`).
    infra: std.mem.Allocator,
    /// Singly-linked live list head — `null` when the heap is empty.
    /// Threaded through a `next: ?*HeapHeader` field that 5.3.b adds
    /// to the header's spare bytes; not present at 5.3.a skeleton.
    live_head: ?*HeapHeader = null,
    /// Per-(size, alignment) free pool heads. Phase 5.3.c lands the
    /// intrusive FreeNode at offset 8 + recycling fast-path.
    free_pools: FreePoolMap = .empty,
    /// Allocation + collection counters.
    stats: Stats = .{},
    /// Adaptive GC trigger threshold (bytes since last collect).
    /// Recomputed at end of each `collect()` cycle.
    threshold_bytes: usize = default_gc_threshold_bytes,
    /// Bytes allocated since the last `collect()` invocation. Trips
    /// collection when it exceeds `threshold_bytes`.
    bytes_since_last_gc: usize = 0,

    pub fn init(infra: std.mem.Allocator) GcHeap {
        return .{ .infra = infra };
    }

    pub fn deinit(self: *GcHeap) void {
        // 5.3.c lands the per-tag finaliser walk + free-pool drain. At
        // 5.3.a skeleton the live list is empty (no allocations have
        // landed) so deinit is a no-op safety check.
        std.debug.assert(self.live_head == null);
        self.free_pools.deinit(self.infra);
    }

    /// Allocate a typed heap object. **Phase 5.3.a stub** — raises
    /// `Code.gc_alloc_not_supported` per ADR-0017 amendment 1 +
    /// `no_op_stub_forbidden.md` explicit-error pattern. 5.3.b lands
    /// the body (free-pool fast-path → infra slow-path → adaptive
    /// trigger check) and 5.3.d migrates Phase 1-4 call sites.
    pub fn alloc(self: *GcHeap, comptime T: type) !*T {
        _ = self;
        return error.GcAllocNotSupported;
    }

    /// Trigger a mark-sweep collection cycle. **Phase 5.3.a stub.**
    /// 5.3.b lands the mark phase (root enumeration + transitive
    /// trace via `tag_ops.tag_trace_table`); 5.3.c lands the sweep
    /// phase (per-tag finaliser dispatch + free-pool push).
    pub fn collect(self: *GcHeap) void {
        _ = self;
        // No-op at 5.3.a; the stats counter stays at zero to make
        // "collection never ran" detectable from a test.
    }
};

// --- tests ---

test "GcHeap.init / deinit on an empty heap" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    try testing.expect(gc.live_head == null);
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
    try testing.expectEqual(@as(usize, default_gc_threshold_bytes), gc.threshold_bytes);
}

test "GcHeap.alloc raises gc_alloc_not_supported at 5.3.a skeleton" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const result = gc.alloc(u32);
    try testing.expectError(error.GcAllocNotSupported, result);
}

test "GcHeap.collect is a no-op at 5.3.a skeleton" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const before = gc.stats.collect_count;
    gc.collect();
    try testing.expectEqual(before, gc.stats.collect_count);
}

test "Stats struct shape" {
    const s = Stats{};
    try testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try testing.expectEqual(@as(usize, 0), s.bytes_freed);
    try testing.expectEqual(@as(u64, 0), s.alloc_count);
    try testing.expectEqual(@as(u64, 0), s.collect_count);
    try testing.expectEqual(@as(u64, 0), s.sweep_count);
    try testing.expectEqual(@as(usize, 0), s.last_live_bytes);
}
