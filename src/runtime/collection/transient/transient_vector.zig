// SPDX-License-Identifier: EPL-2.0
//! TransientVector — single-use mutable scratch buffer that
//! materialises into a PersistentVector via `persistent!`. Phase 8
//! row 8.5 cycle 1 landing per D-074 + F-006 (3-layer allocator —
//! the wrapper struct lives on the GC heap, the growable items
//! buffer lives on `gc.infra` and is released by the per-tag
//! finaliser).
//!
//! ## Shape
//!
//!   ```
//!   TransientVector { consumed, count, capacity, items_ptr, meta }
//!     └── items_ptr[0..count] : owned `[]Value` on gc.infra
//!   ```
//!
//! Unlike JVM `clojure.lang.PersistentVector$TransientVector`, cw v1
//! does **not** share the HAMT trie root with the source persistent
//! vector — each transient is a flat `[]Value` scratch buffer (cw v0
//! inheritance). `persistent!` is therefore O(n) (rebuilds a
//! PersistentVector by repeated `conj`), not O(1). The HAMT-editable
//! shape is parked for a future perf cycle; per F-002 (finished-form
//! wins) the no-sharing landing is finished form at this layer
//! because the user-observable surface is identical to JVM Clojure.
//!
//! ## Lifecycle
//!
//! - `(transient v)` allocs a TransientVector with `items_ptr` sized
//!   for the source's `count` and `count == source.count`.
//! - Each `(conj! tv x)` / `(pop! tv)` checks `consumed == 0`
//!   (`ensureEditable`); on mutation the items buffer grows
//!   geometrically. The same transient Value is returned (callers
//!   must still rebind because other transient variants — e.g. the
//!   TransientArrayMap's promote-to-HAMT path — may reallocate the
//!   wrapper).
//! - `(persistent! tv)` flips `consumed = 1`, builds a fresh
//!   PersistentVector via `vector.conj` over `items_ptr[0..count]`,
//!   and returns the persistent Value. The transient is dead from
//!   that moment; any subsequent `conj! / persistent! / pop!` raises
//!   `transient_used_after_persistent`.
//!
//! Single-threaded today; the JVM `AtomicReference<Thread>`
//! ownership-thread check is omitted because cw v1 has no threading
//! model yet. The same observable semantics result on a single-
//! threaded runtime — see survey
//! `private/notes/phase8-8.5-survey.md` § "Provisional behaviour
//! candidates" PC2 for the rationale. Phase B (concurrency) revisits
//! the ownership-thread check when a threading model lands.

const std = @import("std");
const value_mod = @import("../../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../../runtime.zig").Runtime;
const error_catalog = @import("../../error/catalog.zig");
const error_mod = @import("../../error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const tag_ops = @import("../../gc/tag_ops.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const vector = @import("../vector.zig");

/// Initial capacity when the source is empty.
const INITIAL_CAPACITY: u32 = 8;

/// Growable mutable buffer over a heap-owned `[]Value` slice.
///
/// `consumed` is a `u8` (not `bool`) for `extern struct` layout
/// stability. 0 = editable; 1 = `persistent!` has been called.
pub const TransientVector = extern struct {
    header: HeapHeader,
    consumed: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    count: u32 = 0,
    capacity: u32 = 0,
    _pad2: [4]u8 = .{ 0, 0, 0, 0 },
    items_ptr: ?[*]Value = null,
    meta: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(TransientVector) >= 8);
        std.debug.assert(@offsetOf(TransientVector, "header") == 0);
    }

    /// Live slice view of the populated items.
    pub fn items(self: *const TransientVector) []const Value {
        if (self.items_ptr) |p| return p[0..self.count];
        return &.{};
    }
};

/// Build a TransientVector from a persistent vector source. The
/// source's elements are eagerly copied into a fresh items buffer
/// (no structural sharing). `(transient nil)` is supported and
/// yields an empty transient (no elements, default capacity).
pub fn fromVector(rt: *Runtime, source: Value) !Value {
    const src_count: u32 = if (source.isNil()) 0 else vector.count(source);
    const initial_cap: u32 = @max(src_count, INITIAL_CAPACITY);

    const buf = try rt.gc.infra.alloc(Value, initial_cap);
    errdefer rt.gc.infra.free(buf);
    var i: u32 = 0;
    while (i < src_count) : (i += 1) {
        buf[i] = vector.nth(source, i);
    }

    const tv = try rt.gc.alloc(TransientVector);
    tv.* = .{
        .header = HeapHeader.init(.transient_vector),
        .consumed = 0,
        .count = src_count,
        .capacity = initial_cap,
        .items_ptr = buf.ptr,
        .meta = if (source.isNil()) Value.nil_val else vectorMeta(source),
    };
    return Value.encodeHeapPtr(.transient_vector, tv);
}

/// Convert the transient back to a PersistentVector. Mutates the
/// transient's `consumed` flag — subsequent mutating calls raise
/// `transient_used_after_persistent`.
pub fn toPersistent(rt: *Runtime, tv_val: Value, loc: SourceLocation) !Value {
    const tv = try expectTransient(tv_val, "persistent!", loc);
    try ensureEditable(tv, "persistent!", loc);
    tv.consumed = 1;

    // PERF: bulk O(n) trie build from the flat buffer vs N persistent conjs O(n log n) [refs: O-003, D-180]
    const out = try vector.fromSlice(rt, tv.items());
    // Carry through the source's metadata (`(transient ^{…} v)` / the
    // `to` collection of `into`); `fromSlice` mints a meta-less vector.
    if (tv.meta.isNil()) return out;
    return try vector.withMeta(rt, out, tv.meta);
}

/// Append `x` to the transient's items buffer. Returns the same
/// Value (callers rebind for forward-compat with future kinds that
/// may reallocate the wrapper).
pub fn conj(rt: *Runtime, tv_val: Value, x: Value, loc: SourceLocation) !Value {
    const tv = try expectTransient(tv_val, "conj!", loc);
    try ensureEditable(tv, "conj!", loc);
    try ensureCapacity(rt, tv, tv.count + 1);
    tv.items_ptr.?[tv.count] = x;
    tv.count += 1;
    return tv_val;
}

/// Element count — read accessor so `count` treats a live transient
/// vector as a first-class read target (clj parity). No editable check:
/// reads are valid on a live transient.
pub fn count(tv_val: Value) u32 {
    return tv_val.decodePtr(*const TransientVector).count;
}

/// Read element `i` (0-based); returns `not_found` when out of range.
/// Powers `nth` / indexed `get` on a transient vector.
pub fn nth(tv_val: Value, i: i64, not_found: Value) Value {
    const tv = tv_val.decodePtr(*const TransientVector);
    if (i < 0 or i >= tv.count) return not_found;
    return tv.items()[@intCast(i)];
}

/// In-place index-assign (`assoc!` on a transient vector). `i == count`
/// appends (delegates to `conj`); `0 ≤ i < count` overwrites in place;
/// out of range raises `index_out_of_range` (matches clj's
/// `(assoc! tv i v)`, which only permits indices 0..count).
pub fn assoc(rt: *Runtime, tv_val: Value, i: i64, v: Value, loc: SourceLocation) !Value {
    const tv = try expectTransient(tv_val, "assoc!", loc);
    try ensureEditable(tv, "assoc!", loc);
    if (i < 0 or i > tv.count)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "assoc!" });
    if (i == tv.count) return conj(rt, tv_val, v, loc);
    tv.items_ptr.?[@intCast(i)] = v;
    return tv_val;
}

/// Drop the last element. Errors when the transient is empty
/// (matches JVM Clojure `(pop! (transient []))` IllegalStateException).
pub fn pop(tv_val: Value, loc: SourceLocation) !Value {
    const tv = try expectTransient(tv_val, "pop!", loc);
    try ensureEditable(tv, "pop!", loc);
    if (tv.count == 0) {
        return error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "pop!",
            .expected = "non-empty transient vector",
            .actual = "empty transient vector",
        });
    }
    tv.count -= 1;
    // Clear the freed slot so the GC doesn't retain a stale Value.
    tv.items_ptr.?[tv.count] = Value.nil_val;
    return tv_val;
}

/// Per-tag finaliser — releases the heap-owned items buffer.
/// Registered into `tag_ops.tag_finaliser_table` via `registerGcHooks`.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const tv: *TransientVector = @ptrCast(@alignCast(header));
    if (tv.items_ptr) |p| {
        gc.infra.free(p[0..tv.capacity]);
        tv.items_ptr = null;
    }
}

/// Per-tag GC trace — marks every Value in `items_ptr[0..count]`
/// plus the `meta` slot. Called by the mark phase.
pub fn traceTransientVector(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const tv: *TransientVector = @ptrCast(@alignCast(header));
    if (tv.items_ptr) |p| {
        var i: u32 = 0;
        while (i < tv.count) : (i += 1) {
            if (p[i].heapHeader()) |h| mark_sweep.mark(gc, h);
        }
    }
    if (tv.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register both the trace fn and the finaliser into the per-tag
/// tables. Idempotent at the same fn pointers; `Runtime.init` calls
/// this once before any allocation lands.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.transient_vector, &traceTransientVector);
    tag_ops.registerFinaliser(.transient_vector, &finaliseGc);
}

// --- internals ---

fn expectTransient(v: Value, fn_name: []const u8, loc: SourceLocation) !*TransientVector {
    if (v.tag() != .transient_vector) {
        return error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = fn_name,
            .expected = "transient_vector",
            .actual = @tagName(v.tag()),
        });
    }
    return v.decodePtr(*TransientVector);
}

fn ensureEditable(tv: *TransientVector, fn_name: []const u8, loc: SourceLocation) !void {
    if (tv.consumed != 0) {
        return error_catalog.raise(.transient_used_after_persistent, loc, .{
            .fn_name = fn_name,
        });
    }
}

fn ensureCapacity(rt: *Runtime, tv: *TransientVector, needed: u32) !void {
    if (needed <= tv.capacity) return;
    var new_cap: u32 = @max(tv.capacity, INITIAL_CAPACITY);
    while (new_cap < needed) new_cap *|= 2;

    const old_buf: []Value = if (tv.items_ptr) |p| p[0..tv.capacity] else &.{};
    // D-361: this element buffer grows via `infra`, bypassing gc.alloc's
    // heap_ceiling. Without this check a runaway `(vec (range 1e8))` under a
    // CLJW_EVAL_MAX_HEAP_MB cap grows the buffer to hundreds of MB and the OS
    // OOM-kills the process before `persistent!` (gc.alloc) would trip the cap
    // (the D-361 Linux symptom). Refuse here so the cap surfaces as the
    // catchable/uncatchable eval_heap_exceeded during the build, on every host.
    try rt.gc.checkInfraCap(new_cap * @sizeOf(Value));
    const new_buf = try rt.gc.infra.realloc(old_buf, new_cap);
    tv.items_ptr = new_buf.ptr;
    tv.capacity = new_cap;
}

/// Read the `meta` slot off a persistent vector (helper for
/// `fromVector` carry-through). `vector.zig` does not currently
/// expose a `meta` accessor; reach in via the same decode path
/// used by Vector.count.
fn vectorMeta(v: Value) Value {
    if (v.tag() != .vector) return Value.nil_val;
    return v.decodePtr(*const vector.Vector).meta;
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "TransientVector layout: header at offset 0, alignment ≥ 8" {
    try testing.expect(@offsetOf(TransientVector, "header") == 0);
    try testing.expect(@alignOf(TransientVector) >= 8);
}

test "fromVector + toPersistent on empty source returns empty persistent vector" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const tv = try fromVector(&fix.rt, vector.empty());
    try testing.expect(tv.tag() == .transient_vector);

    const p = try toPersistent(&fix.rt, tv, .{ .line = 0, .column = 0 });
    try testing.expect(p.tag() == .vector);
    try testing.expectEqual(@as(u32, 0), vector.count(p));
}

test "conj! then persistent! returns a one-element vector" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tv = try fromVector(&fix.rt, vector.empty());
    _ = try conj(&fix.rt, tv, Value.initInteger(42), loc);
    const p = try toPersistent(&fix.rt, tv, loc);

    try testing.expect(p.tag() == .vector);
    try testing.expectEqual(@as(u32, 1), vector.count(p));
    try testing.expectEqual(@as(i48, 42), vector.nth(p, 0).asInteger());
}

test "conj! after persistent! raises transient_used_after_persistent" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tv = try fromVector(&fix.rt, vector.empty());
    _ = try toPersistent(&fix.rt, tv, loc);

    error_mod.clearLastError();
    try testing.expectError(
        error_mod.ClojureWasmError.ValueError,
        conj(&fix.rt, tv, Value.initInteger(1), loc),
    );
    const info = error_mod.getLastError().?;
    try testing.expect(std.mem.find(u8, info.message, "Transient used after persistent!") != null);
}

test "conj! 16 ints crosses INITIAL_CAPACITY (8) and grows the buffer" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tv = try fromVector(&fix.rt, vector.empty());
    var i: i48 = 0;
    while (i < 16) : (i += 1) {
        _ = try conj(&fix.rt, tv, Value.initInteger(i), loc);
    }
    const p = try toPersistent(&fix.rt, tv, loc);
    try testing.expectEqual(@as(u32, 16), vector.count(p));
    try testing.expectEqual(@as(i48, 0), vector.nth(p, 0).asInteger());
    try testing.expectEqual(@as(i48, 15), vector.nth(p, 15).asInteger());
}

test "pop! on empty transient raises transient_kind_mismatch" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tv = try fromVector(&fix.rt, vector.empty());
    error_mod.clearLastError();
    try testing.expectError(error_mod.ClojureWasmError.TypeError, pop(tv, loc));
}

test "pop! drops the last element" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    const tv = try fromVector(&fix.rt, vector.empty());
    _ = try conj(&fix.rt, tv, Value.initInteger(1), loc);
    _ = try conj(&fix.rt, tv, Value.initInteger(2), loc);
    _ = try pop(tv, loc);
    const p = try toPersistent(&fix.rt, tv, loc);
    try testing.expectEqual(@as(u32, 1), vector.count(p));
    try testing.expectEqual(@as(i48, 1), vector.nth(p, 0).asInteger());
}

test "transient(non-transient) call raises transient_kind_mismatch" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    error_mod.clearLastError();
    // Calling pop! on a plain vector (not a transient) must fail with kind mismatch.
    try testing.expectError(error_mod.ClojureWasmError.TypeError, pop(vector.empty(), loc));
}

test "fromVector copies elements from a non-empty source" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(10));
    v = try vector.conj(&fix.rt, v, Value.initInteger(20));
    v = try vector.conj(&fix.rt, v, Value.initInteger(30));

    const tv = try fromVector(&fix.rt, v);
    const p = try toPersistent(&fix.rt, tv, loc);
    try testing.expectEqual(@as(u32, 3), vector.count(p));
    try testing.expectEqual(@as(i48, 10), vector.nth(p, 0).asInteger());
    try testing.expectEqual(@as(i48, 20), vector.nth(p, 1).asInteger());
    try testing.expectEqual(@as(i48, 30), vector.nth(p, 2).asInteger());
}
