// SPDX-License-Identifier: EPL-2.0
//! Plain data shapes of the mark-sweep heap (ADR-0028): the live-list record,
//! the persistent mark-waypoint, the statistics block, and the comptime
//! HeapHeader-at-offset-0 check every `GcHeap.alloc` type passes. No state,
//! no behaviour: `gc_heap.zig` holds the heap that uses them.

const std = @import("std");
const HeapHeader = @import("../value/heap_header.zig").HeapHeader;

/// Minimum allocation size (bytes) per ADR-0028 §3: the freed payload must
/// host the free-list link at offset 8 (8 bytes header + at least 8 bytes
/// payload = 16 bytes minimum). Smaller types round up; the extra bytes are
/// unused while live.
pub const min_alloc_bytes: usize = 16;

/// Comptime invariant: every `T` passed to `GcHeap.alloc` has `HeapHeader` as
/// its first field, at offset 0. The returned `*T` and the live-list
/// `*HeapHeader` are pointer-aliases; mark/sweep read `header.tag` without
/// knowing T. A different first field would silently misread its first bytes
/// as a tag and run the wrong `tag_finaliser_table` entry at sweep, so the
/// check fires at compile time.
pub fn assertHeaderAtOffsetZero(comptime T: type) void {
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

/// A process-lifetime mark-waypoint (D-251) + the bytes it owns (D-573): the
/// size feeds `persistent_bytes`, the cost the time-share arm absorbs because
/// these objects are re-traced every cycle.
pub const PersistentMark = struct {
    obj: *anyopaque,
    size: usize,
};

/// Allocation + collection statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    alloc_count: u64 = 0,
    collect_count: u64 = 0,
    sweep_count: u64 = 0,
    last_live_bytes: usize = 0,
    /// Diagnostic (gc_alloc_rate lever, D-450): allocs served from the page
    /// heap (vs a large cell's `infra.rawAlloc`). small_allocs/alloc_count is
    /// the share of the allocation stream the page heap carries.
    small_allocs: u64 = 0,
    /// D-573: nanoseconds spent inside `collectStopTheWorld`, and the wall
    /// clock at the first collection. Their ratio is the GC time fraction the
    /// floor is steered by (the JVM's `-XX:GCTimeRatio` quantity).
    gc_ns_total: u64 = 0,
    first_collect_ns: i64 = 0,
};

/// Per-allocation record on the GcHeap live list: the type-erased
/// `*HeapHeader` plus the original (size, alignment), so sweep and deinit free
/// with the metadata `rawAlloc` was given. Without them a debug allocator
/// trips "Invalid free": the header alone would imply an 8-byte block.
pub const AllocRecord = struct {
    header: *HeapHeader,
    size: usize,
    alignment: std.mem.Alignment,
};
