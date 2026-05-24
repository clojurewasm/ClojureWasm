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

const GcHeap = gc_heap_mod.GcHeap;
const HeapHeader = heap_header.HeapHeader;

/// Visit every root + recursively trace through GC-managed pointers.
/// Sets `header.gc_and_lock.mark` (bit 0) on every reached object.
/// **Phase 5.3.a stub** — raises until 5.3.b wires the body.
pub fn mark(gc: *GcHeap, root_header: *HeapHeader) !void {
    _ = gc;
    _ = root_header;
    return error.GcMarkNotSupported;
}

/// Walk the live list, finalise + recycle unreached objects, clear
/// marks on reached ones. **Phase 5.3.a stub** — raises until 5.3.c
/// wires the body.
pub fn sweep(gc: *GcHeap) !void {
    _ = gc;
    return error.GcSweepNotSupported;
}

// --- tests ---

test "mark stub raises GcMarkNotSupported at 5.3.a" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    var hdr = HeapHeader.init(.string);
    try testing.expectError(error.GcMarkNotSupported, mark(&gc, &hdr));
}

test "sweep stub raises GcSweepNotSupported at 5.3.a" {
    var gc = GcHeap.init(testing.allocator);
    defer gc.deinit();

    try testing.expectError(error.GcSweepNotSupported, sweep(&gc));
}
