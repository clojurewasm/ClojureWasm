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
const value_mod = @import("../value/value.zig");

const HeapHeader = heap_header.HeapHeader;
const FreePoolMap = free_pool_mod.FreePoolMap;
const Value = value_mod.Value;

/// Default GC trigger threshold (bytes since last collection).
/// Adaptive at runtime: `threshold = max(default, last_live_bytes * 2)`
/// per ADR-0028 §1 Load-bearing-concern #2 disposition.
pub const default_gc_threshold_bytes: usize = 1 * 1024 * 1024;

/// Minimum allocation size (bytes) per ADR-0028 §3: the freed payload
/// must host the FreeNode overlay at offset 8 (8 bytes header +
/// ≥ 8 bytes payload = 16 bytes minimum). Allocations of types
/// smaller than 16 bytes round up; the extra bytes are unused while
/// live but become the FreeNode region on free.
pub const min_alloc_bytes: usize = 16;

/// Comptime invariant: every `T` passed to `GcHeap.alloc` must have
/// `HeapHeader` as its first field. The returned `*T` and the
/// live-list `*HeapHeader` are pointer-aliases — caster relies on
/// offset 0 holding the header so mark/sweep can read `header.tag`
/// without knowing T. A struct with a different first field would
/// silently misinterpret the first bytes as a tag enum value, and
/// the mis-link would surface only under a debugger or on the
/// downstream sweep path (where the tag's `tag_finaliser_table`
/// entry runs against the wrong memory). The check below fires at
/// compile time so the bug never reaches a debugger.
fn assertHeaderAtOffsetZero(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("GcHeap.alloc requires a struct type; got " ++ @typeName(T));
    }
    const fields = info.@"struct".fields;
    if (fields.len == 0) {
        @compileError("GcHeap.alloc requires T to have at least one field; " ++ @typeName(T) ++ " has none");
    }
    if (fields[0].type != HeapHeader) {
        @compileError("GcHeap.alloc requires T to have HeapHeader as its first field; " ++ @typeName(T) ++ "'s first field is " ++ @typeName(fields[0].type));
    }
    if (@offsetOf(T, fields[0].name) != 0) {
        @compileError("GcHeap.alloc requires HeapHeader at offset 0 of T; " ++ @typeName(T) ++ " has it at a different offset");
    }
}

/// Allocation + collection statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    alloc_count: u64 = 0,
    collect_count: u64 = 0,
    sweep_count: u64 = 0,
    last_live_bytes: usize = 0,
};

/// Per-allocation record on the GcHeap live list. Stores the type-
/// erased `*HeapHeader` plus the original (size, alignment) so deinit
/// / 5.3.c sweep can `rawFree` with the matching metadata back to
/// `infra`. Without the per-record size + alignment, debug allocators
/// trip "Invalid free" canaries because the type-erased *HeapHeader
/// alone would imply an 8-byte destroy of a (typically larger) full
/// allocation.
pub const AllocRecord = struct {
    header: *HeapHeader,
    size: usize,
    alignment: std.mem.Alignment,
};

/// Mark-sweep GC heap. Owns a list of tracked heap objects + per-size
/// free pools; trigger threshold adapts based on the last live-set
/// measurement.
///
/// Live-list shape (per 5.3.b.1 design decision, depth 1):
/// **side-table** `ArrayListUnmanaged(AllocRecord)` on GcHeap rather
/// than an intrusive `next: ?*HeapHeader` field on HeapHeader. Reason:
/// (1) preserves ADR-0009's 8-byte HeapHeader invariant (avoiding
/// header-grow surgery); (2) matches cw v0's path (refined per
/// ADR-0028 audit bullet #5 — only the mark BIT goes inline per
/// ADR-0028 §6, not the live-list link); (3) sweep walk stays
/// sequential through ArrayList memory (cache-friendly), which is
/// what the cw v0 perf inheritance language in ADR-0028 §3 cares
/// about. Each record carries (size, alignment) so the deinit /
/// sweep `rawFree` paths match what `rawAlloc` originally requested.
pub const GcHeap = struct {
    /// Backing allocator for raw heap pages. Per F-006 §2 this is the
    /// process-lifetime GPA (`infra_alloc`).
    infra: std.mem.Allocator,
    /// Side-table of live heap-object records. Append at alloc time;
    /// swap-remove during sweep for dead objects. Per the docstring
    /// design decision: side-table chosen over intrusive next-pointer
    /// to preserve the 8-byte HeapHeader invariant.
    allocations: std.ArrayList(AllocRecord) = .empty,
    /// Embedder-pinned root Values per ADR-0028 §5 row 10. Holds
    /// `Value` entries that the embedder (FFI / test fixture / future
    /// `cljw -e` REPL prompt buffer) wants to keep alive across
    /// `collect()` cycles. `pin` appends, `unpin` swap-removes the
    /// first match. The root walker yields each entry's
    /// `Value.heapHeader()` (skipping immediates).
    permanent_roots: std.ArrayList(Value) = .empty,
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
        var g = GcHeap{ .infra = infra };
        g.free_pools.initMap(infra);
        return g;
    }

    pub fn deinit(self: *GcHeap) void {
        // Drain every live allocation back to infra. Per-tag finalisers
        // (ADR-0028 §4) land in 5.3.c; until then deinit just frees
        // raw memory without per-tag side-effects (acceptable because
        // gc.alloc has not been wired into Phase 1-4 alloc sites yet,
        // so the only headers in the list are 5.3.b.1's allocator-
        // test-fixture headers, not real Value payloads).
        for (self.allocations.items) |rec| {
            const mem = @as([*]u8, @ptrCast(rec.header))[0..rec.size];
            self.infra.rawFree(mem, rec.alignment, @returnAddress());
        }
        self.allocations.deinit(self.infra);
        self.permanent_roots.deinit(self.infra);
        self.free_pools.deinit(self.infra);
    }

    /// Pin a Value so it stays alive across `collect()` cycles. Returns
    /// after appending to `permanent_roots`. Callers (FFI / test
    /// fixtures / future REPL prompt buffer per ADR-0028 §5 row 10)
    /// must pair every `pin` with an `unpin` to avoid steady-state
    /// leaks. Immediates can be pinned too — the walker filters them.
    pub fn pin(self: *GcHeap, v: Value) !void {
        try self.permanent_roots.append(self.infra, v);
    }

    /// Unpin the first matching Value entry. Returns `true` on a hit,
    /// `false` if the Value was not pinned (treated as a programming
    /// error by callers — typically wrapped in `std.debug.assert`).
    pub fn unpin(self: *GcHeap, v: Value) bool {
        for (self.permanent_roots.items, 0..) |entry, i| {
            if (entry == v) {
                _ = self.permanent_roots.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Allocate a typed heap object on the GC heap. **Phase 5.3.c.2**:
    /// free-pool fast-path → infra slow-path. **Phase 5.3.b.4 adds
    /// the comptime HeapHeader-at-offset-0 check.** Caller initialises
    /// the value (HeapHeader and payload fields). Auto-trigger of
    /// `collect()` mid-alloc lands once root walkers are wired at
    /// 5.3.b.3 — without roots, an auto-collect would sweep every
    /// allocation including the one we're about to return.
    ///
    /// Allocation size is rounded up to `min_alloc_bytes = 16` per
    /// ADR-0028 §3 so freed memory can host the FreeNode overlay at
    /// offset 8. The extra payload bytes (for T smaller than 16) are
    /// unused while live but become the FreeNode region on free.
    ///
    /// Convention: `T` must have `HeapHeader` as its first field so
    /// the returned `*T` and `*HeapHeader` are pointer-aliases. The
    /// caller-side existing pattern (`pub const BigInt = struct {
    /// header: HeapHeader, ... }`) satisfies this; the comptime check
    /// below rejects mis-typed `T` at compile time before the live-
    /// list mis-link can land.
    pub fn alloc(self: *GcHeap, comptime T: type) !*T {
        comptime assertHeaderAtOffsetZero(T);
        const align_t: std.mem.Alignment = .fromByteUnits(@alignOf(T));
        const effective_size: usize = @max(@sizeOf(T), min_alloc_bytes);
        const key = free_pool_mod.FreePoolKey{ .size = effective_size, .alignment = align_t };

        const raw: [*]u8 = self.free_pools.pop(key) orelse blk: {
            const fresh = self.infra.rawAlloc(effective_size, align_t, @returnAddress()) orelse
                return error.OutOfMemory;
            break :blk fresh;
        };
        errdefer self.infra.rawFree(raw[0..effective_size], align_t, @returnAddress());

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

    try testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, 0), gc.permanent_roots.items.len);
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
    try testing.expectEqual(@as(usize, default_gc_threshold_bytes), gc.threshold_bytes);
}

test "GcHeap.pin appends to permanent_roots; unpin removes first match" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const a = Value.initInteger(42);
    const b = Value.initInteger(7);
    try gc.pin(a);
    try gc.pin(b);
    try testing.expectEqual(@as(usize, 2), gc.permanent_roots.items.len);

    try testing.expect(gc.unpin(a));
    try testing.expectEqual(@as(usize, 1), gc.permanent_roots.items.len);
    try testing.expect(gc.unpin(b));
    try testing.expectEqual(@as(usize, 0), gc.permanent_roots.items.len);

    try testing.expect(!gc.unpin(a)); // already removed
}

test "GcHeap.alloc tracks bytes + count + bytes_since_last_gc" {
    // Use a HeapHeader-prefixed test type to satisfy the 5.3.b.1
    // "HeapHeader at offset 0" convention.
    const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c1 = try gc.alloc(Cell);
    c1.* = .{ .header = HeapHeader.init(.string) };
    try testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 1), gc.stats.alloc_count);
    try testing.expectEqual(@as(usize, @sizeOf(Cell)), gc.bytes_since_last_gc);

    const c2 = try gc.alloc(Cell);
    c2.* = .{ .header = HeapHeader.init(.vector) };
    try testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Cell)), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 2), gc.stats.alloc_count);
}

test "GcHeap.alloc returned pointer aliases the live-list HeapHeader" {
    // The HeapHeader-at-offset-0 convention means the returned *T and
    // the live-list *HeapHeader are pointer-aliases (same address);
    // 5.3.b mark / 5.3.c sweep both rely on this.
    const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const c = try gc.alloc(Cell);
    c.* = .{ .header = HeapHeader.init(.list) };

    const rec = gc.allocations.items[0];
    const hdr_via_cast: *HeapHeader = @ptrCast(c);
    try testing.expectEqual(rec.header, hdr_via_cast);
    try testing.expectEqual(@as(u8, @intFromEnum(value_mod.HeapTag.list)), rec.header.tag);
    try testing.expectEqual(@sizeOf(Cell), rec.size);
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
