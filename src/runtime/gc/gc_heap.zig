// SPDX-License-Identifier: EPL-2.0
//! Mark-sweep GC heap for cw v1 — `gc_alloc` layer of the 3-layer
//! allocator boundary per ADR-0028 §2 + F-006.
//!
//! Struct shape:
//!   - `allocations` — side-table of live heap-object records (header
//!     + size + alignment); see the `GcHeap` docstring for why a
//!     side-table beats an intrusive next-pointer.
//!   - `permanent_roots` — embedder-pinned root Values (`pin` / `unpin`).
//!   - `free_pools` — per-(size, alignment) free pool head map, owned
//!     by `runtime/gc/free_pool.zig`.
//!   - `stats` — bytes_allocated / bytes_freed / alloc/collect/sweep
//!     counts + last_live_bytes.
//!   - `infra` — backing GPA allocator (per F-006 §2 layer 1) for the
//!     raw heap pages this `GcHeap` operates over.
//!   - `bytes_since_last_gc` + `threshold_bytes` — drive the adaptive
//!     `collect()` trigger per ADR-0028 §1.
//!
//! `alloc` (free-pool fast path → infra slow path), `pin` / `unpin`,
//! and `deinit` (per-tag finaliser → rawFree drain) are all landed.
//! The `collect()` orchestrator lives in `mark_sweep.zig` to keep the
//! import graph acyclic (it reaches `root_set.zig`, which imports this
//! file).
//!
//! Thread-safety (ADR-0090 §2, F-006): `gc_mutex` (a `std.Io.Mutex`,
//! locked through the `io_default` singleton because the allocator API
//! takes no `io` arg) serializes `alloc` / `pin` / `unpin` and the whole
//! `collect()` cycle (the latter brackets in `mark_sweep.collect`). It is
//! uncontended today (real threads arrive with `future` / `pmap`); the
//! global alloc lock is the foundation the `ThreadGcContext`
//! root-publication handshake (ADR-0090) builds on for collection safety.
//! Not reentrant: `alloc` never calls `collect`, and `collect` never
//! allocates, so the two lock-takers never nest.

const std = @import("std");
const testing = std.testing;

const heap_header = @import("../value/heap_header.zig");
const free_pool_mod = @import("free_pool.zig");
const value_mod = @import("../value/value.zig");
const io_default = @import("../concurrency/io_default.zig");

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
    /// Per-(size, alignment) free pool heads. Sweep pushes freed blocks
    /// here (intrusive FreeNode at offset 8); `alloc` pops them as its
    /// fast path before falling back to `infra`.
    free_pools: FreePoolMap = .empty,
    /// Allocation + collection counters.
    stats: Stats = .{},
    /// Adaptive GC trigger threshold (bytes since last collect).
    /// Recomputed at end of each `collect()` cycle.
    threshold_bytes: usize = default_gc_threshold_bytes,
    /// Bytes allocated since the last `collect()` invocation. Trips
    /// collection when it exceeds `threshold_bytes`.
    bytes_since_last_gc: usize = 0,
    /// Global heap lock (ADR-0090 §2). Serializes `alloc` / `pin` /
    /// `unpin` and the whole `collect()` cycle so allocation is
    /// thread-safe under F-006. Locked via the `io_default` singleton
    /// (the allocator API has no `io` arg). Uncontended until real
    /// threads land (`future` / `pmap`).
    gc_mutex: std.Io.Mutex = .init,

    pub fn init(infra: std.mem.Allocator) GcHeap {
        var g = GcHeap{ .infra = infra };
        g.free_pools.initMap(infra);
        return g;
    }

    pub fn deinit(self: *GcHeap) void {
        // Drain every live allocation back to infra. Calls the per-tag
        // finaliser before rawFree so types that own non-GC resources
        // (String.bytes / BigInt limbs / wasm_module references) get
        // their cleanup chance — matches the sweep contract per
        // ADR-0028 §4.
        const tag_ops = @import("tag_ops.zig");
        for (self.allocations.items) |rec| {
            if (tag_ops.tag_finaliser_table[rec.header.tag]) |finaliser| {
                finaliser(@ptrCast(self), rec.header);
            }
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
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
        try self.permanent_roots.append(self.infra, v);
    }

    /// Unpin the first matching Value entry. Returns `true` on a hit,
    /// `false` if the Value was not pinned (treated as a programming
    /// error by callers — typically wrapped in `std.debug.assert`).
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

    /// Allocate a typed heap object on the GC heap: free-pool fast path
    /// → infra slow path, with a comptime HeapHeader-at-offset-0 check.
    /// Caller initialises the value (HeapHeader and payload fields).
    /// Note: `alloc` does NOT auto-trigger `collect()` mid-alloc today.
    /// Callers invoke `mark_sweep.collect` explicitly; threshold-driven
    /// auto-collection is a future wiring task (the root walkers it
    /// needs are already in place — `root_set.zig`).
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
        io_default.lockMutex(&self.gc_mutex);
        defer io_default.unlockMutex(&self.gc_mutex);
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

    // The `collect()` orchestrator lives in `mark_sweep.zig` — it
    // imports `root_set.zig` which itself imports `gc_heap.zig`, so the
    // natural cycle-free place for the entry point is
    // `mark_sweep.collect(gc, ctx)`. Callers reach the entry point
    // through `mark_sweep.collect`, not through a method on this struct.
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

test "concurrent alloc through the global heap lock is race-free (ADR-0090 §2)" {
    // The gc_mutex (locked via io_default) must serialize alloc across real
    // OS threads so the `allocations` ArrayList append + `infra` rawAlloc
    // never race. Set io_default to a THREADED io for real mutex blocking,
    // then restore it (the singleton is process-wide; tests run serially).
    const Cell = extern struct { header: HeapHeader, payload: u64 = 0 };
    const per_thread = 500;
    const n_threads = 4;

    const saved_io = io_default.get();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    defer io_default.set(saved_io); // runs before threaded.deinit (LIFO)
    io_default.set(threaded.io());

    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    const Worker = struct {
        fn run(g: *GcHeap) void {
            var i: usize = 0;
            while (i < per_thread) : (i += 1) {
                const c = g.alloc(Cell) catch return;
                c.* = .{ .header = HeapHeader.init(.string) };
            }
        }
    };

    var threads: [n_threads]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&gc});
    for (&threads) |t| t.join();

    // Every alloc landed exactly once — no lost append, no double-count.
    try testing.expectEqual(@as(usize, n_threads * per_thread), gc.allocations.items.len);
    try testing.expectEqual(@as(u64, n_threads * per_thread), gc.stats.alloc_count);
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

test "Stats struct shape" {
    const s = Stats{};
    try testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try testing.expectEqual(@as(usize, 0), s.bytes_freed);
    try testing.expectEqual(@as(u64, 0), s.alloc_count);
    try testing.expectEqual(@as(u64, 0), s.collect_count);
    try testing.expectEqual(@as(u64, 0), s.sweep_count);
    try testing.expectEqual(@as(usize, 0), s.last_live_bytes);
}
