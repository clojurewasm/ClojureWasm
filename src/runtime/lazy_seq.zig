// SPDX-License-Identifier: EPL-2.0
//! Lazy sequence activation per ROADMAP §9.7 row 5.7 + ADR-0009
//! amendment 2.
//!
//! Per Clojure's LazySeq semantics: a LazySeq wraps a thunk (an
//! arity-0 Fn Value) that produces the next realised value
//! (typically a Cons cell or nil for end-of-seq). The first
//! `force()` invokes the thunk, caches the result in `realized`,
//! sets `realized_flag = 1` so subsequent calls short-circuit
//! without re-invoking.
//!
//! ## Mutex shape
//!
//! **No lock — single-thread today.** cw v1 is single-threaded (per
//! the Runtime.io io_default accessor). The cw v0 LazySeq similarly
//! had no lock (`value.zig:665-668`); thread-safety was a
//! single-thread invariant. JVM's LazySeq locks on realise; that
//! lock-on-realise contention path (two threads forcing the same
//! LazySeq) lands at Phase B with real threading/locking (debt
//! D-046). The Zig-0.16 locking primitive is chosen at Phase B entry
//! (the pre-0.16 plan referenced removed APIs).
//!
//! ## Field layout (extern struct)
//!
//! `header: HeapHeader` at offset 0 (gc.alloc invariant) + a
//! `realized_flag: u8` discriminator (since both `thunk` and
//! `realized` can legitimately be `Value.nil_val`, we need a
//! separate state bit). Padding aligns `Value` fields to 8.
//!
//! Per-tag trace fn walks thunk + realized + meta; the GC keeps
//! the captured Fn (thunk) + any realised Cons chain alive until
//! the LazySeq itself becomes unreachable.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const env_mod = @import("env.zig");
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");
const list_mod = @import("collection/list.zig");
const chunked_cons_mod = @import("collection/chunked_cons.zig");
const range_mod = @import("collection/range.zig");
const vector_mod = @import("collection/vector.zig");
const set_mod = @import("collection/set.zig");
const map_mod = @import("collection/map.zig");
const sorted_mod = @import("collection/sorted.zig");
const map_entry_mod = @import("collection/map_entry.zig");
const persistent_queue_mod = @import("collection/persistent_queue.zig");

/// LazySeq — extern struct with HeapHeader at offset 0; thunk +
/// realized + meta Values; realized_flag discriminator since both
/// thunk and realized may equal Value.nil_val at runtime.
pub const LazySeq = extern struct {
    header: HeapHeader,
    /// 0 = thunk pending; 1 = thunk invoked, result in `realized`.
    realized_flag: u8 = 0,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    /// Arity-0 Fn Value that produces the realised seq. After
    /// force() returns, callers should treat thunk as cleared
    /// (set to nil_val) to release the closure for GC; current
    /// implementation keeps thunk live to support potential
    /// `(realized? ls)` introspection.
    thunk: Value = Value.nil_val,
    /// Realised seq (typically a Cons or nil). Valid only when
    /// `realized_flag == 1`.
    realized: Value = Value.nil_val,
    /// Optional metadata map.
    meta: Value = Value.nil_val,
    /// PERF: D-386 (O-023) internal fusion descriptor — a `{:xform :coll}` map
    /// stamped by `map`/`filter` so `reduce` can fuse the transform chain into a
    /// single `transduce` pass (no intermediate seq). A SEPARATE slot from `meta`
    /// (NOT the user meta map) so `(meta (map …))` stays nil = clj parity. Inert
    /// to every seq op (first/rest/seq/take force the thunk normally). [refs: O-023]
    fuse: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(LazySeq) >= 8);
        std.debug.assert(@offsetOf(LazySeq, "header") == 0);
    }
};

/// Build a fresh LazySeq wrapping a thunk Fn Value. The thunk is
/// expected to be a 0-arity callable that returns the realised
/// seq (typically a Cons or nil) when invoked via `rt.vtable.callFn`.
pub fn alloc(rt: *Runtime, thunk_fn: Value) !Value {
    const ls = try rt.gc.alloc(LazySeq);
    ls.* = .{
        .header = HeapHeader.init(.lazy_seq),
        .realized_flag = 0,
        .thunk = thunk_fn,
        .realized = Value.nil_val,
        .meta = Value.nil_val,
        .fuse = Value.nil_val,
    };
    return Value.encodeHeapPtr(.lazy_seq, ls);
}

/// True iff the LazySeq's thunk has already been forced. Powers
/// `(realized? ls)` introspection (the `realized_flag` discriminator).
pub fn isRealised(v: Value) bool {
    return v.decodePtr(*const LazySeq).realized_flag == 1;
}

/// `force(rt, env, v)` — realise the LazySeq's thunk on first
/// access, return the cached realised seq on subsequent calls.
/// `env` is threaded to the thunk's vtable.callFn invocation so
/// the closure can read dynamic vars per Clojure semantics.
pub fn force(rt: *Runtime, env: *env_mod.Env, v: Value) !Value {
    if (v.tag() != .lazy_seq) return v;
    const ls = v.decodePtr(*LazySeq);
    if (ls.realized_flag == 1) return ls.realized;

    // Thunk dispatch. Requires the vtable to be installed (Layer
    // 1 backend wires this at startup); else surface an internal
    // error rather than silently no-op.
    const vt = rt.vtable orelse return error.LazySeqVTableNotInstalled;
    const raw = try vt.callFn(rt, env, ls.thunk, &[_]Value{}, .{});
    // clj `LazySeq.seq` runs the realized body through `RT.seq`: a lazy-seq
    // body may legitimately return a non-seq seqable (e.g. `(lazy-seq [2 3])`
    // → a vector), which must be seq-coerced or the seq-walk would drop the
    // tail (`(1 nil)`). Coerce the terminal seqable collections to a list/seq
    // here so seq/first/rest/count all see a walkable value. A `.lazy_seq`
    // result is left for the caller's force-loop; `.list`/`.cons`/`.range`/
    // `.chunked_cons`/the seq-views are already walkable.
    const result = try coerceRealized(rt, raw);

    ls.realized = result;
    ls.realized_flag = 1;
    return result;
}

/// Seq-coerce a realized lazy-seq body (clj `RT.seq` parity). Non-seq seqable
/// collections become a list/seq; already-walkable values pass through.
fn coerceRealized(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .vector => blk: {
            var acc = try list_mod.emptyList(rt);
            var i = vector_mod.count(v);
            while (i > 0) {
                i -= 1;
                acc = try list_mod.consHeap(rt, vector_mod.nth(v, i), acc);
            }
            break :blk acc;
        },
        .map_entry => try list_mod.consHeap(rt, map_entry_mod.keyOf(v), try list_mod.consHeap(rt, map_entry_mod.valOf(v), try list_mod.emptyList(rt))),
        .hash_set => if (set_mod.count(v) > 0) try set_mod.seq(rt, v) else .nil_val,
        .array_map, .hash_map => if (map_mod.count(v) > 0) try map_mod.seq(rt, v) else .nil_val,
        .sorted_map, .sorted_set => if (sorted_mod.count(v) > 0) try sorted_mod.seq(rt, v) else .nil_val,
        .persistent_queue => try persistent_queue_mod.seqOf(rt, v),
        else => v,
    };
}

/// `(seq v)` — force the LazySeq if needed; returns the realised
/// seq (Cons / nil / another LazySeq). For non-LazySeq inputs,
/// returns the input unchanged (caller is expected to know the
/// tag — `runtime/collection/list.zig::seq` for Cons handling).
pub fn seq(rt: *Runtime, env: *env_mod.Env, v: Value) !Value {
    // Force ALL lazy layers, not just one: a thunk may realize to
    // another LazySeq (e.g. `filter`'s no-match branch returns
    // `(filter pred (rest s))` directly), and `seq` must resolve down
    // to a concrete Cons / nil so an empty lazy chain collapses to nil
    // (else a seq-walk advancing via `next` sees a non-nil LazySeq and
    // appends a spurious trailing nil).
    var current = v;
    while (current.tag() == .lazy_seq) {
        current = try force(rt, env, current);
    }
    // The interned empty list `()` (D-164) coerces to nil like every other
    // empty seq. `lazy_seq.seq` is the shared force+coerce that count /
    // realize / seq-walks terminate on, so the count-0 `.list` must collapse
    // here too — else a walk counts the singleton as a spurious nil element.
    if (current.tag() == .list and list_mod.countOf(current) == 0) return .nil_val;
    return current;
}

/// `(first v)` — head of the (possibly lazy) sequence. Force as
/// many LazySeq layers as needed; route through `list.first` for
/// .list Cons cells; return nil for everything else.
pub fn first(rt: *Runtime, env: *env_mod.Env, v: Value) !Value {
    var current = v;
    while (current.tag() == .lazy_seq) {
        current = try force(rt, env, current);
    }
    return switch (current.tag()) {
        .list => list_mod.first(current),
        // Generic seq head: a lazy tail may realize to / be cons'd over a
        // chunked_cons or a compact range (e.g. `(cons x (range n))`), so
        // these are part of the Layer-0 seq-accessor protocol too.
        .chunked_cons => chunked_cons_mod.first(current),
        .range => range_mod.first(current),
        .nil => Value.nil_val,
        else => Value.nil_val,
    };
}

/// `(rest v)` — tail of the (possibly lazy) sequence. Always
/// returns a sequence (possibly empty); per Clojure semantics
/// distinct from `(next v)` which returns nil for empty-tail.
pub fn rest(rt: *Runtime, env: *env_mod.Env, v: Value) !Value {
    var current = v;
    while (current.tag() == .lazy_seq) {
        current = try force(rt, env, current);
    }
    return switch (current.tag()) {
        .list => list_mod.rest(current),
        .chunked_cons => try chunked_cons_mod.rest(rt, current),
        .range => try chunked_cons_mod.rest(rt, try range_mod.seqChunk(rt, current)),
        .nil => Value.nil_val,
        else => Value.nil_val,
    };
}

/// `(next v)` — like `rest` but returns nil for empty-tail (matches
/// Clojure semantics: `(next ())` is nil, `(rest ())` is `()`).
pub fn next(rt: *Runtime, env: *env_mod.Env, v: Value) !Value {
    const tail = try rest(rt, env, v);
    return switch (tail.tag()) {
        .list => if (list_mod.countOf(tail) > 0) tail else Value.nil_val,
        else => if (tail.isNil()) Value.nil_val else tail,
    };
}

/// Per-tag trace fn — walks thunk + realized + meta.
pub fn traceLazySeq(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ls: *LazySeq = @ptrCast(@alignCast(header));
    if (ls.thunk.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.realized.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.fuse.heapHeader()) |h| mark_sweep.mark(gc, h);
}

/// Register the LazySeq trace fn into `tag_ops.tag_trace_table`.
/// Idempotent; called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.lazy_seq, &traceLazySeq);
}

/// Metadata of a lazy seq (or nil).
pub fn metaOf(v: Value) Value {
    return v.decodePtr(*const LazySeq).meta;
}

/// `(with-meta ls newmeta)` — shallow copy sharing thunk/realized/fuse, meta set.
pub fn withMeta(rt: *Runtime, v: Value, m: Value) !Value {
    const ls = v.decodePtr(*const LazySeq);
    const nls = try rt.gc.alloc(LazySeq);
    nls.* = .{ .header = HeapHeader.init(.lazy_seq), .realized_flag = ls.realized_flag, .thunk = ls.thunk, .realized = ls.realized, .meta = m, .fuse = ls.fuse };
    return Value.encodeHeapPtr(.lazy_seq, nls);
}

/// PERF: D-386 (O-023) the fusion descriptor of a lazy seq (or nil for a
/// non-lazy_seq / un-stamped one). Read by `reduceFn`'s fused arm. [refs: O-023]
pub fn fuseOf(v: Value) Value {
    if (v.tag() != .lazy_seq) return Value.nil_val;
    return v.decodePtr(*const LazySeq).fuse;
}

/// PERF: D-386 (O-023) shallow copy of a lazy seq sharing thunk/realized/meta
/// with the fusion descriptor set. The thunk body is byte-for-byte the original,
/// so every seq op forces it identically — `fuse` is a pure side channel reduce
/// reads. [refs: O-023]
pub fn setFuse(rt: *Runtime, v: Value, f: Value) !Value {
    const ls = v.decodePtr(*const LazySeq);
    const nls = try rt.gc.alloc(LazySeq);
    nls.* = .{ .header = HeapHeader.init(.lazy_seq), .realized_flag = ls.realized_flag, .thunk = ls.thunk, .realized = ls.realized, .meta = ls.meta, .fuse = f };
    return Value.encodeHeapPtr(.lazy_seq, nls);
}

// --- tests ---

const testing = std.testing;

const RuntimeFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() RuntimeFixture {
        var fix: RuntimeFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *RuntimeFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "LazySeq layout: HeapHeader at offset 0, extern + align 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(LazySeq, "header"));
    try testing.expect(@alignOf(LazySeq) >= 8);
}

test "alloc returns a .lazy_seq-tagged Value with realized_flag = 0" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try alloc(&fix.rt, Value.nil_val);
    try testing.expect(v.tag() == .lazy_seq);
    const ls = v.decodePtr(*const LazySeq);
    try testing.expectEqual(@as(u8, 0), ls.realized_flag);
    try testing.expectEqual(Value.nil_val, ls.thunk);
    try testing.expectEqual(Value.nil_val, ls.realized);
}

test "force on cached LazySeq: returns realized without invoking thunk" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    const v = try alloc(&fix.rt, Value.nil_val);
    const ls = v.decodePtr(*LazySeq);
    // Pre-cache: set realized_flag + realized directly to simulate
    // a prior force() — verify force short-circuits without
    // touching the (null) thunk.
    ls.realized_flag = 1;
    ls.realized = Value.initInteger(42);

    const result = try force(&fix.rt, &env, v);
    try testing.expectEqual(@as(i48, 42), result.asInteger());
}

test "force on non-LazySeq input: returns the input unchanged" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    try testing.expectEqual(Value.nil_val, try force(&fix.rt, &env, Value.nil_val));
    try testing.expectEqual(
        @as(i48, 7),
        (try force(&fix.rt, &env, Value.initInteger(7))).asInteger(),
    );
}

test "force on uncached LazySeq without vtable: surfaces error.LazySeqVTableNotInstalled" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();
    // Note: Runtime.init does NOT install vtable; only the eval
    // backend wires it at Phase 2.6+. Forcing before vtable is
    // installed should surface the internal-error shape — full
    // thunk-dispatch tests live in eval/backend/tree_walk's
    // LazySeq integration suite (5.7.b).

    const v = try alloc(&fix.rt, Value.true_val); // non-nil thunk so force tries to invoke
    try testing.expectError(error.LazySeqVTableNotInstalled, force(&fix.rt, &env, v));
}

test "first/rest/next on .list pass through to list ops" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    // Build (1 2 3) via consHeap.
    const l3 = try list_mod.consHeap(&fix.rt, Value.initInteger(3), Value.nil_val);
    const l2 = try list_mod.consHeap(&fix.rt, Value.initInteger(2), l3);
    const l1 = try list_mod.consHeap(&fix.rt, Value.initInteger(1), l2);

    try testing.expectEqual(@as(i48, 1), (try first(&fix.rt, &env, l1)).asInteger());
    const r = try rest(&fix.rt, &env, l1);
    try testing.expectEqual(@as(i48, 2), (try first(&fix.rt, &env, r)).asInteger());
    const n = try next(&fix.rt, &env, l1);
    try testing.expectEqual(@as(i48, 2), (try first(&fix.rt, &env, n)).asInteger());
}

test "first/rest/next on cached LazySeq route through realized" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    // Pre-cached LazySeq → realized = (42 99)
    const tail = try list_mod.consHeap(&fix.rt, Value.initInteger(99), Value.nil_val);
    const realised_list = try list_mod.consHeap(&fix.rt, Value.initInteger(42), tail);
    const ls_val = try alloc(&fix.rt, Value.nil_val);
    const ls = ls_val.decodePtr(*LazySeq);
    ls.realized_flag = 1;
    ls.realized = realised_list;

    try testing.expectEqual(@as(i48, 42), (try first(&fix.rt, &env, ls_val)).asInteger());
    const r = try rest(&fix.rt, &env, ls_val);
    try testing.expectEqual(@as(i48, 99), (try first(&fix.rt, &env, r)).asInteger());
}

test "first/rest/next on empty seq return nil" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    try testing.expect((try first(&fix.rt, &env, Value.nil_val)).isNil());
    try testing.expect((try rest(&fix.rt, &env, Value.nil_val)).isNil());
    try testing.expect((try next(&fix.rt, &env, Value.nil_val)).isNil());
}

test "next on single-element list returns nil (vs rest returning ())" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    const l1 = try list_mod.consHeap(&fix.rt, Value.initInteger(42), Value.nil_val);
    // rest returns nil (since count was 1 → tail = nil_val per consHeap)
    const r = try rest(&fix.rt, &env, l1);
    try testing.expect(r.isNil());
    // next also returns nil (rest's nil → nil)
    const n = try next(&fix.rt, &env, l1);
    try testing.expect(n.isNil());
}
