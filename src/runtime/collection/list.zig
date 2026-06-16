//! PersistentList — Clojure's singly-linked cons-cell list.
//!
//! Each `Cons` cell holds `first` (head), `rest` (tail: `nil` or another
//! list pointer), `meta` (`nil` or a metadata map), and `count` (O(1)
//! length). Lists are immutable and structurally shared — `cons(x, ys)`
//! reuses `ys` directly.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");

/// Cons cell — fundamental list-building block. `extern struct` so
/// declaration order is preserved + HeapHeader lands at offset 0
/// (required by `gc.alloc(T)` per the comptime check).
pub const Cons = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    first: Value,
    rest: Value,
    meta: Value,
    count: u32,

    comptime {
        std.debug.assert(@alignOf(Cons) >= 8);
        std.debug.assert(@offsetOf(Cons, "header") == 0);
    }
};

/// Allocate a new cons cell prepending `head` to `tail`. `tail` must be
/// `nil` or a list Value; `count` is precomputed so callers see O(1)
/// length.
pub fn cons(alloc: std.mem.Allocator, head: Value, tail: Value) !Value {
    const cell = try alloc.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),
    };
    return Value.encodeHeapPtr(.list, cell);
}

/// Allocate a new cons cell on the GC heap, so the resulting Value
/// outlives any per-eval arena (e.g. when the list ends up bound to
/// a global Var). Use this for quoted-list literals and any list a
/// primitive needs to return to caller-land. Tests + per-test arenas
/// keep using the plain `cons` above when they don't need long-lived
/// Values.
///
/// 5.3.d.5 migration: rt.gpa.create + trackHeap → rt.gc.alloc; the
/// per-tag trace fn (registered by `registerGcHooks`) walks
/// first / rest / meta so the GC sees the outgoing pointers and
/// keeps reachable children alive.
pub fn consHeap(rt: *Runtime, head: Value, tail: Value) !Value {
    // D-244 #4: in a `acc = consHeap(rt, x, acc)` fold (the `list` builtin +
    // many primitives) the partial-list `tail`/`acc` is held in a Zig local,
    // unrooted, across this alloc; defer a mid-fold collect (ADR-0150 region).
    // Pure cons-folds only — a fold whose element production ALSO allocs is the
    // separate window-1 / gc_self_guard scope (D-244 #4b).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const cell = try rt.gc.alloc(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),
    };
    return Value.encodeHeapPtr(.list, cell);
}

/// Per-tag trace fn called by mark phase to walk outgoing GC-managed
/// pointers per ADR-0028 §5 + the cw v0 D100 "transitive trace"
/// requirement. Cons has no owned non-GC resources so no finaliser
/// is needed.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const c: *Cons = @ptrCast(@alignCast(header));
    if (c.first.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (c.rest.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    if (c.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Register Cons's trace fn into `tag_ops.tag_trace_table[.list]`.
/// Idempotent at the same fn pointer; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.list, &traceGc);
}

/// The interned distinct empty list `()` (D-164 / clj-parity C1). A
/// count-0 `Cons` (first/rest/meta all nil) tagged `.list`, allocated once
/// per Runtime on `gc.infra` (process-lifetime — never GC-swept, mirroring
/// `native_descriptors`) and cached in `rt.empty_list`. Tag `.list` means
/// `list?`/`seq?`/`sequential?`/`printList`/equality work unchanged (they
/// key on `.list` + count); the single instance gives identity equality
/// for `(= '() '())`. Mirrors JVM's single static `PersistentList.EMPTY`.
pub fn emptyList(rt: *Runtime) !Value {
    if (!rt.empty_list.isNil()) return rt.empty_list;
    const cell = try rt.gc.infra.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = .nil_val,
        .rest = .nil_val,
        .meta = .nil_val,
        .count = 0,
    };
    rt.empty_list = Value.encodeHeapPtr(.list, cell);
    return rt.empty_list;
}

/// True when `val` is a `.list` Value with no elements (`()` — count 0).
pub fn isEmpty(val: Value) bool {
    return val.tag() == .list and countOf(val) == 0;
}

/// Free the interned empty-list singleton (allocated on `gc.infra`, so it
/// is not GC-swept and must be released explicitly — same discipline as
/// `native_descriptors`). Called from `Runtime.deinit`; idempotent.
pub fn deinitEmptyList(rt: *Runtime) void {
    if (rt.empty_list.isNil()) return;
    rt.gc.infra.destroy(rt.empty_list.decodePtr(*Cons));
    rt.empty_list = .nil_val;
}

/// First element. `nil` for non-list inputs (matches Clojure's `first`).
pub fn first(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).first,
        else => .nil_val,
    };
}

/// Rest of a list. `nil` for non-list inputs and at the tail end.
pub fn rest(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).rest,
        else => .nil_val,
    };
}

/// O(1) length. `0` for non-list inputs.
pub fn countOf(val: Value) u32 {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).count,
        else => 0,
    };
}

/// Sequence view: `val` itself if non-empty, otherwise `nil`. Mirrors
/// Clojure's `(seq xs)` — empty colls become `nil`.
pub fn seq(val: Value) Value {
    return switch (val.tag()) {
        .list => if (val.decodePtr(*Cons).count > 0) val else .nil_val,
        else => .nil_val,
    };
}

/// Raw `Cons` pointer view. Caller must already know `val` is a list.
pub fn asCons(val: Value) *Cons {
    std.debug.assert(val.tag() == .list);
    return val.decodePtr(*Cons);
}

/// Metadata of a list (or nil).
pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const Cons).meta;
}

/// `(with-meta lst newmeta)` — shallow copy of the head Cons sharing the
/// rest chain, meta set. (`.list`-tagged; raw `.cons` with-meta deferred.)
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const c = v.decodePtr(*const Cons);
    const nc = try rt.gc.alloc(Cons);
    nc.* = .{ .header = HeapHeader.init(.list), .first = c.first, .rest = c.rest, .meta = m, .count = c.count };
    return Value.encodeHeapPtr(.list, nc);
}

// --- tests ---

const testing = std.testing;

test "Cons alignment" {
    try testing.expect(@alignOf(Cons) >= 8);
}

test "cons creates a single-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, Value.initInteger(42), .nil_val);

    try testing.expect(lst.tag() == .list);
    try testing.expectEqual(@as(u32, 1), countOf(lst));
    try testing.expectEqual(@as(i48, 42), first(lst).asInteger());
    try testing.expect(rest(lst).isNil());
}

fn consHeapFailingHarness(alloc_inner: std.mem.Allocator) !void {
    var th = std.Io.Threaded.init(alloc_inner, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), alloc_inner);
    defer rt.deinit();
    _ = try consHeap(&rt, Value.initInteger(42), .nil_val);
}

test "consHeap returns OOM without leaking under each allocation failure (uniform errdefer)" {
    try testing.checkAllAllocationFailures(testing.allocator, consHeapFailingHarness, .{});
}

test "cons creates a multi-element list (1 2 3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const l3 = try cons(alloc, Value.initInteger(3), .nil_val);
    const l2 = try cons(alloc, Value.initInteger(2), l3);
    const l1 = try cons(alloc, Value.initInteger(1), l2);

    try testing.expectEqual(@as(u32, 3), countOf(l1));
    try testing.expectEqual(@as(u32, 2), countOf(l2));
    try testing.expectEqual(@as(u32, 1), countOf(l3));

    try testing.expectEqual(@as(i48, 1), first(l1).asInteger());
    try testing.expectEqual(@as(i48, 2), first(rest(l1)).asInteger());
    try testing.expectEqual(@as(i48, 3), first(rest(rest(l1))).asInteger());
    try testing.expect(rest(rest(rest(l1))).isNil());
}

test "first / rest / countOf on nil" {
    try testing.expect(first(.nil_val).isNil());
    try testing.expect(rest(.nil_val).isNil());
    try testing.expectEqual(@as(u32, 0), countOf(.nil_val));
}

test "seq is itself for non-empty, nil for empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, Value.initInteger(1), .nil_val);
    try testing.expect(!seq(lst).isNil());
    try testing.expect(seq(.nil_val).isNil());
}

test "HeapHeader carries the list tag and starts unmarked / unfrozen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, .true_val, .nil_val);
    const cell = asCons(lst);
    try testing.expectEqual(@as(u8, @intFromEnum(HeapTag.list)), cell.header.tag);
    // GC mark bit lives in gc_and_lock.gc_mark per ADR-0009 a2 +
    // 5.3.d.9 (Flags.marked removed; mark bit 0 of gc_mark).
    try testing.expectEqual(@as(u30, 0), cell.header.gc_and_lock.gc_mark & 1);
    try testing.expect(!cell.header.flags.frozen);
}

test "meta defaults to nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, Value.initInteger(1), .nil_val);
    try testing.expect(asCons(lst).meta.isNil());
}

test "emptyList is an interned count-0 .list, distinct from nil" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const e = try emptyList(&rt);
    try testing.expect(e.tag() == .list);
    try testing.expectEqual(@as(u32, 0), countOf(e));
    try testing.expect(isEmpty(e));
    try testing.expect(!e.isNil());
    try testing.expect(first(e).isNil());
    try testing.expect(rest(e).isNil()); // tail field stays nil; restFn lifts
    try testing.expect(seq(e).isNil()); // empty seq → nil

    // Interned: a second call returns the bit-identical Value (single
    // instance, mirroring JVM PersistentList.EMPTY).
    const e2 = try emptyList(&rt);
    try testing.expectEqual(@intFromEnum(e), @intFromEnum(e2));

    // A non-empty list is not isEmpty.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const one = try cons(arena.allocator(), Value.initInteger(1), .nil_val);
    try testing.expect(!isEmpty(one));
}

test "structural sharing across cons calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tail = try cons(alloc, Value.initInteger(2), try cons(alloc, Value.initInteger(3), .nil_val));
    const a = try cons(alloc, Value.initInteger(1), tail);
    const b = try cons(alloc, Value.initInteger(0), tail);

    try testing.expectEqual(@intFromEnum(rest(a)), @intFromEnum(rest(b)));
    try testing.expectEqual(@as(u32, 3), countOf(a));
    try testing.expectEqual(@as(u32, 3), countOf(b));
}
