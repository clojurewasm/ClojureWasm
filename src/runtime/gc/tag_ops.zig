// SPDX-License-Identifier: EPL-2.0
//! Per-Tag dispatch infrastructure for cw v1 mark-sweep GC + class
//! system (ADR-0028 §4 + ADR-0027 §3 cross-reference).
//!
//! **Phase 5 row 5.2.b skeleton + 5.3.d.2 register helpers.** The
//! three Tag-indexed dispatch tables (`tag_descriptor_table` /
//! `tag_trace_table` / `tag_finaliser_table`) are declared as
//! `pub var` with all-null defaults; per-Tag entries get filled at
//! startup via the `register*` helpers below. §9.7 row 5.3 GC
//! implementation owner chose "three parallel arrays" over the
//! alternative `TagOps` struct-of-arrays shape per ADR-0028 §4 main
//! loop disposition + F-003 deferral — parallel arrays match the
//! existing call-site pattern `if (tag_finaliser_table[tag]) |f|
//! f(header);` and survive future entry width changes
//! independently per table.
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
/// Entries are `null` until §9.7 row 5.3 GC implementation lands the
/// trace bodies. Mark-phase access pattern:
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

/// Per-HeapTag finaliser function. Called by sweep before unlink + free-
/// pool push (ADR-0028 §4). May only `infra_alloc.free` or no-op;
/// allocation through `gc_alloc` from inside a finaliser is a Phase-5-
/// enforced panic.
///
/// Sweep access pattern:
///
/// ```zig
/// if (tag_finaliser_table[tag]) |f| f(header);
/// gc.unlinkLive(header);
/// gc.freePoolPush(header);
/// ```
///
/// Day-1 Tags that need a finaliser (per ADR-0028 §4):
///   - `big_int` / `ratio` / `big_decimal`: release `Managed` limbs
///     back to `infra_alloc` (limbs live on GPA per F-005)
///   - `wasm_module` / `wasm_fn`: drop zwasm v2 `Module` / `FuncEntity`
///     references (Phase 16 entry contract)
///   - `host_instance`: dispatches through `TypeDescriptor.finaliser`
///     per ADR-0011
///
/// Phase 5 row 5.3 wires the entries that have known finalisers; the
/// rest stay `null` until their owning Phase entry lands behaviour.
pub var tag_finaliser_table: [64]?*const fn (header: *HeapHeader) void = @splat(null);

pub const FinaliserFn = *const fn (header: *HeapHeader) void;

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
        fn f(_: *HeapHeader) void {
            // Test-only no-op finaliser; production finalisers free
            // owned slices (e.g. String.bytes) back to infra_alloc.
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
    try testing.expectEqual(@as(u8, 63), @intFromEnum(HeapTag.reserved_d15));
}
