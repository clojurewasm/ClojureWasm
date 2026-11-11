// SPDX-License-Identifier: EPL-2.0
//! Per-Tag dispatch infrastructure for cw v1 mark-sweep GC + class
//! system (ADR-0028 §4 + ADR-0027 §3 cross-reference).
//!
//! The three Tag-indexed dispatch tables (`tag_descriptor_table` /
//! `tag_trace_table` / `tag_finaliser_table`) are declared as
//! `pub var` with all-null defaults; per-Tag entries are filled at
//! startup via the `register*` helpers below. The "three parallel
//! arrays" shape was chosen over a single `TagOps` struct-of-arrays
//! per ADR-0028 §4 — parallel arrays match the call-site pattern
//! `if (tag_finaliser_table[tag]) |f| f(header);` and let each table's
//! entry width change independently.
//!
//! Registration is **idempotent** at the same (tag, fn) pair — Runtime
//! tests construct multiple `Runtime` instances and each `Runtime.init`
//! may re-register Layer 0 finalisers (strings / collections / etc.).
//! Re-registering a different fn for the same tag is asserted against
//! in debug builds as a programming error.
//!
//! No-behaviour-wired entries stay `null`; access sites use the
//! pattern `if (tag_finaliser_table[tag]) |f| f(header);` so a missing
//! entry is a no-op (per ADR-0028 §4 Phase 16 entry contract — the
//! finaliser must be set before the first allocation of that Tag).
//!
//! Dispatch tables are indexed by `@intFromEnum(HeapTag)` over the
//! 0..63 heap-tag slot space; immediate Tags (nil / boolean / integer /
//! float / char / builtin_fn at 64..69) are not indexed here because
//! they are NaN-box bit patterns, not heap-resident objects, so the GC
//! never sweeps or traces them.

const heap_tag = @import("../value/heap_tag.zig");
const heap_header = @import("../value/heap_header.zig");

const HeapTag = heap_tag.HeapTag;
const HeapHeader = heap_header.HeapHeader;

/// Per-HeapTag descriptor pointer table. Read by 5.11 TypeDescriptor
/// activation + class-of dispatch (ADR-0007 + ADR-0027 §3 cross-ref).
/// Entries are `pub const TypeDescriptor` globals registered at runtime
/// init — declared here as a forward pointer so the table compiles
/// before the descriptor module exists.
///
/// Per ADR-0028 §4 main loop disposition: the choice of "three parallel
/// arrays" (as declared here) vs a single `TagOps` struct-of-arrays
/// shape lives with the 5.3 GC implementation owner. The
/// `tag_descriptor_table` access pattern is `tag_descriptor_table[
/// @intFromEnum(value.tag_heap())] orelse fallback()`.
///
/// `?*const anyopaque` is the forward-declared element type — the 5.11
/// activation refines it to `?*const TypeDescriptor` once the
/// descriptor struct's full layout is wired without forward-decl
/// cycles.
pub var tag_descriptor_table: [64]?*const anyopaque = @splat(null);

/// Per-HeapTag GC mark-phase trace function. Called by `gc.mark(value)`
/// when descending into a heap object's outgoing pointers (ADR-0028 §5).
/// Each entry walks the type-specific GC-managed pointer fields and
/// calls `gc.mark(child)` on each.
///
/// A `null` entry means a leaf node (no GC-managed outgoing pointers);
/// a non-null entry is a per-tag tracer registered via `registerTrace`.
/// Mark-phase access pattern:
///
/// ```zig
/// if (tag_trace_table[tag]) |trace_fn| trace_fn(gc, header);
/// ```
///
/// A `null` entry means the heap object has no GC-managed outgoing
/// pointers (terminal node — e.g. `string` payload, `big_int` limb
/// data on `infra_alloc`). `null` is the safe default; missing-but-
/// needed entries surface as live-leak symptoms in the bench harness
/// at 5.3 onward.
pub var tag_trace_table: [64]?*const fn (gc: *anyopaque, header: *HeapHeader) void = @splat(null);

pub const TraceFn = *const fn (gc: *anyopaque, header: *HeapHeader) void;

/// Per-HeapTag finaliser function. Called by sweep before the freed
/// block is pushed onto its free pool (ADR-0028 §4). May only free
/// back to `gc.infra` or no-op; allocating through `gc_alloc` from
/// inside a finaliser is forbidden (no-alloc invariant).
///
/// Sweep access pattern (sweep then recycles the block inline):
///
/// ```zig
/// if (tag_finaliser_table[tag]) |f| f(gc, header);
/// ```
///
/// Tags needing a finaliser register one at `Runtime.init` via
/// `registerFinaliser` — e.g. `big_int` releases its `Managed` limbs
/// back to `gc.infra` (limbs live on GPA per F-005); `string`,
/// `ex_info`, `regex`, transient/typed/reified instances likewise free
/// owned non-GC resources. Tags whose owning feature is not yet wired
/// (`wasm_module` / `wasm_fn` / `host_instance`) stay `null` until
/// their owning Phase lands behaviour. A `null` entry is a no-op
/// (nothing to finalise).
pub var tag_finaliser_table: [64]?*const fn (gc: *anyopaque, header: *HeapHeader) void = @splat(null);

/// Per-tag OWNED-BYTES hook (D-573): the bytes a live object owns BEYOND its
/// GC record block — the memory its finaliser would free. `sweep` adds this to
/// `last_live_bytes` so the adaptive trigger (`threshold = max(floor,
/// last_live)`) sees a cost-proportional live size. Without it, a heap of
/// Strings reported only the 32-byte wrappers while the byte payloads — the
/// memory actually held, the graph actually costing RSS — were invisible:
/// measured 78 MB reported against 359 MB RSS, a factor of 4.6, which made the
/// adaptive arm read as inert exactly when the collector was most loaded.
///
/// A `null` entry means "owns nothing beyond the record" (every persistent
/// collection — vector/map/list nodes are pure GC records). Unhooked-but-
/// finalised tags whose payload lives outside `gc.infra` accounting:
/// `host_instance` (descriptor-opaque state) and the wasm handles
/// (engine-owned bytes) — see D-573's residual note.
pub var tag_owned_bytes_table: [64]?*const fn (header: *HeapHeader) usize = @splat(null);

pub const OwnedBytesFn = *const fn (header: *HeapHeader) usize;

/// Register an owned-bytes hook for `tag`. Same idempotent semantics as
/// `registerFinaliser`.
pub fn registerOwnedBytes(tag: HeapTag, fn_ptr: OwnedBytesFn) void {
    const idx = @intFromEnum(tag);
    if (tag_owned_bytes_table[idx]) |existing| {
        const std = @import("std");
        std.debug.assert(existing == fn_ptr);
        return;
    }
    tag_owned_bytes_table[idx] = fn_ptr;
}

/// Finaliser signature — receives the *GcHeap (type-erased to break
/// the import cycle; concrete cast at call site) so it can free
/// owned non-GC resources back to `gc.infra` per ADR-0028 §4 + the
/// Block B reconciliation in §2. Examples:
///   - String.finaliseGc frees `bytes: []const u8` back to gc.infra
///   - BigInt.finaliseGc calls `Managed.deinit` (which uses the
///     Managed's stored allocator — set to `gc.infra` at construction)
pub const FinaliserFn = *const fn (gc: *anyopaque, header: *HeapHeader) void;

/// Register a finaliser for `tag`. Idempotent at the same `fn_ptr` —
/// re-registering the same function is a no-op (matches multi-
/// `Runtime` semantics where each `Runtime.init` re-binds Layer 0
/// finalisers). Re-registering a **different** function for the
/// same tag is a programming error (asserted in debug builds).
pub fn registerFinaliser(tag: HeapTag, fn_ptr: FinaliserFn) void {
    const idx = @intFromEnum(tag);
    if (tag_finaliser_table[idx]) |existing| {
        const std = @import("std");
        std.debug.assert(existing == fn_ptr);
        return;
    }
    tag_finaliser_table[idx] = fn_ptr;
}

/// Register a per-tag trace function (called from `mark` to walk
/// outgoing GC-managed pointers). Same idempotent semantics as
/// `registerFinaliser`.
pub fn registerTrace(tag: HeapTag, fn_ptr: TraceFn) void {
    const idx = @intFromEnum(tag);
    if (tag_trace_table[idx]) |existing| {
        const std = @import("std");
        std.debug.assert(existing == fn_ptr);
        return;
    }
    tag_trace_table[idx] = fn_ptr;
}

/// Test-only: reset every table to all-null. Tests that exercise
/// registration must call this in `defer` so they don't leak state
/// across the test runner.
pub fn resetForTest() void {
    tag_descriptor_table = @splat(null);
    tag_trace_table = @splat(null);
    tag_finaliser_table = @splat(null);
}

// --- tests ---

const testing = @import("std").testing;

test "tag_*_table arrays are 64 entries (heap-tag slot space)" {
    try testing.expectEqual(@as(usize, 64), tag_descriptor_table.len);
    try testing.expectEqual(@as(usize, 64), tag_trace_table.len);
    try testing.expectEqual(@as(usize, 64), tag_finaliser_table.len);
}

test "tag_*_table default: all entries are null before any registration" {
    defer resetForTest();
    resetForTest();
    for (tag_descriptor_table) |entry| try testing.expect(entry == null);
    for (tag_trace_table) |entry| try testing.expect(entry == null);
    for (tag_finaliser_table) |entry| try testing.expect(entry == null);
}

test "registerFinaliser sets the entry; re-registering same fn is idempotent" {
    defer resetForTest();
    const noop = struct {
        fn f(_: *anyopaque, _: *HeapHeader) void {
            // Test-only no-op finaliser; production finalisers free
            // owned slices (e.g. String.bytes) back to gc.infra.
        }
    }.f;
    registerFinaliser(.string, &noop);
    try testing.expect(tag_finaliser_table[@intFromEnum(HeapTag.string)] != null);
    // Re-register same fn — idempotent.
    registerFinaliser(.string, &noop);
    try testing.expect(tag_finaliser_table[@intFromEnum(HeapTag.string)] == &noop);
}

test "registerTrace sets the entry; re-registering same fn is idempotent" {
    defer resetForTest();
    const noop = struct {
        fn f(_: *anyopaque, _: *HeapHeader) void {
            // Test-only no-op trace; production tracers walk
            // outgoing GC-managed pointers + call gc.mark on each.
        }
    }.f;
    registerTrace(.fn_val, &noop);
    try testing.expect(tag_trace_table[@intFromEnum(HeapTag.fn_val)] != null);
    registerTrace(.fn_val, &noop);
    try testing.expect(tag_trace_table[@intFromEnum(HeapTag.fn_val)] == &noop);
}

test "HeapTag enum integer indices fit the dispatch table bounds (0..63)" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(HeapTag.string));
    try testing.expectEqual(@as(u8, 12), @intFromEnum(HeapTag.range));
    try testing.expectEqual(@as(u8, 16), @intFromEnum(HeapTag.fn_val));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(HeapTag.typed_instance));
    try testing.expectEqual(@as(u8, 32), @intFromEnum(HeapTag.atom));
    try testing.expectEqual(@as(u8, 48), @intFromEnum(HeapTag.big_int));
    try testing.expectEqual(@as(u8, 63), @intFromEnum(HeapTag.wasm_externref)); // D15 = last slot (D-248 reorg: was tval)
}
