// SPDX-License-Identifier: EPL-2.0
//! Lazy sequence activation per ROADMAP §9.7 row 5.7 + ADR-0009
//! amendment 2.
//!
//! Per Clojure's LazySeq semantics: a LazySeq wraps a thunk (an
//! arity-0 Fn Value) that produces a body: a seq, a seqable collection, a
//! string, another LazySeq, or nil. The first `force()` invokes the thunk
//! ONCE, drains a nested lazy body iteratively, coerces the terminal through
//! the Seqable boundary (`seqable.zig`, clj `RT.seq` inside
//! `LazySeq.realize`, ADR-0197), caches it in `realized` and sets
//! `realized_flag = 1` so subsequent calls short-circuit. `first` / `rest` /
//! `next` on a lazy value are the boundary's accessors over `seq`.
//!
//! ## Thread-safety (ADR-0143, D-046)
//!
//! `future`/`agent` spawn real OS threads, so multiple threads can
//! `force()` the same LazySeq. `force` uses an **inline lock-free
//! double-checked atomic flag + CAS-claim** (the atom.zig idiom, D-246
//! — no off-heap cell, no finaliser, no struct growth): the
//! `realized_flag` byte is a 3-state atomic word (PENDING/REALISED/
//! CLAIMING). The steady-state read is a lock-free acquire-load (clj's
//! shape — clj nulls a volatile Lock so realised reads need no lock);
//! exactly one CAS winner invokes the thunk (clj's at-most-once),
//! publishing via a release-store that fences the plain `realized`
//! write; losers spin until publish, polling the ADR-0092 §2 safepoint
//! (the thunk eval is exclusion-bearing). A thrown thunk resets the
//! flag to PENDING (clj does not cache a thrown realisation → retry).
//! NOT the off-heap `Io.Mutex` cell delay/promise use: LazySeq is the
//! highest-cardinality heap object, so a per-element cell+finaliser is
//! the wrong trade (Zig 0.16 has no inline blocking wait — `std.Thread`
//! sync primitives are gone — so a blocking loser would force that
//! cell). See ADR-0143 § Alternatives for the full design space.
//! Known limitation (shared with delay/promise/future): a thunk that
//! forces its own LazySeq hangs (clj StackOverflows) — degenerate,
//! unguarded for memo-family consistency.
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
const safepoint = @import("concurrency/safepoint.zig");
const root_set = @import("gc/root_set.zig");
const seqable = @import("seqable.zig");
const list_mod = @import("collection/list.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;

/// LazySeq — extern struct with HeapHeader at offset 0; thunk +
/// realized + meta Values; realized_flag discriminator since both
/// thunk and realized may equal Value.nil_val at runtime.
pub const LazySeq = extern struct {
    header: HeapHeader,
    /// 3-state atomic realise word (ADR-0143): `flag_pending` (0) /
    /// `flag_realised` (1, result in `realized`) / `flag_claiming` (2,
    /// a thread holds the CAS-claim and is invoking the thunk). Accessed
    /// only via `@atomicLoad`/`@cmpxchgStrong`/`@atomicStore` in `force`.
    realized_flag: u8 = 0,
    /// 1 when `thunk` is a native step (a builtin_fn called with
    /// `[step_a step_b]`) instead of an arity-0 closure (O-110).
    native: u8 = 0,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    /// Arity-0 Fn Value that produces the body. Released (nil) once the
    /// node is realised, so the closure and what it captured can be
    /// collected (JVM `fn = null`); kept across a thrown realisation so the
    /// retry can re-invoke it.
    thunk: Value = Value.nil_val,
    /// Valid only when `realized_flag == 1`: the coerced terminal seq (a
    /// seq view / cons chain / instance / nil), or, for an inner node of a
    /// nested lazy body, the next `.lazy_seq` link (`seq` follows links).
    realized: Value = Value.nil_val,
    /// Optional metadata map.
    meta: Value = Value.nil_val,
    /// PERF: D-386 (O-023) internal fusion descriptor — a `{:xform :coll}` map
    /// stamped by `map`/`filter` so `reduce` can fuse the transform chain into a
    /// single `transduce` pass (no intermediate seq). A SEPARATE slot from `meta`
    /// (NOT the user meta map) so `(meta (map …))` stays nil = clj parity. Inert
    /// to every seq op (first/rest/seq/take force the thunk normally). [refs: O-023]
    fuse: Value = Value.nil_val,
    /// PERF: O-110 the two operands of a native step (`native == 1`), e.g.
    /// `f` and the source seq of a one-coll `map` node. Released with the
    /// thunk once the node is realised. [refs: O-110]
    step_a: Value = Value.nil_val,
    step_b: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(LazySeq) >= 8);
        std.debug.assert(@offsetOf(LazySeq, "header") == 0);
    }
};

/// `realized_flag` states (ADR-0143). PENDING/REALISED keep the original
/// 0/1 semantics (`isRealised` / `(realized? ls)` check REALISED); CLAIMING
/// marks the CAS-claim held by the thread invoking the thunk.
const flag_pending: u8 = 0;
const flag_realised: u8 = 1;
const flag_claiming: u8 = 2;

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

/// PERF: a lazy node whose body is a native step: realizing it calls the
/// builtin `step` with `[a b]` instead of an interpreted arity-0 closure, so
/// a core producer (map/filter/take/iterate) costs no closure allocation and
/// no eval re-entry per node. Same at-most-once realization. Callers root
/// `a`/`b` across this alloc. [refs: O-110]
pub fn allocNative(rt: *Runtime, step: Value, a: Value, b: Value) !Value {
    const ls = try rt.gc.alloc(LazySeq);
    ls.* = .{ .header = HeapHeader.init(.lazy_seq), .native = 1, .thunk = step, .step_a = a, .step_b = b };
    return Value.encodeHeapPtr(.lazy_seq, ls);
}

/// Invoke a node's body: the native step on its operands, or the closure.
fn callBody(rt: *Runtime, env: *env_mod.Env, ls: *LazySeq, loc: SourceLocation) anyerror!Value {
    if (ls.native == 1) {
        const step = ls.thunk.asBuiltinFn(@import("dispatch.zig").BuiltinFn);
        return step(rt, env, &.{ ls.step_a, ls.step_b }, loc);
    }
    const vt = rt.vtable orelse return error.LazySeqVTableNotInstalled;
    return vt.callFn(rt, env, ls.thunk, &[_]Value{}, loc);
}

/// True iff the LazySeq's thunk has already been forced. Powers
/// `(realized? ls)` introspection (the `realized_flag` discriminator).
pub fn isRealised(v: Value) bool {
    return @atomicLoad(u8, &v.decodePtr(*const LazySeq).realized_flag, .acquire) == flag_realised;
}

/// Realize a LazySeq: invoke its thunk at most once, drain a nested lazy
/// body, coerce the terminal through the Seqable boundary and cache it.
/// Non-lazy input passes through. `env` is threaded to the thunk so the
/// closure reads dynamic vars per Clojure semantics.
///
/// Shape = clj `LazySeq.realize` (ADR-0197): `force` (the thunk) → `unwrap`
/// (an inner LazySeq is drained through its own single-level realization,
/// which publishes the inner with its RAW body as a link, so the loop
/// advances one link per step and never recurses) → `RT.seq` (`seqable.seq`).
/// The entry node caches the TERMINAL seq, so re-reading a deep chain is
/// O(1); an inner node caches its link and is followed by `seq`. On success
/// the thunk is released (JVM `fn = null`); a raised thunk OR coercion resets
/// the flag to PENDING and keeps the thunk, so the realisation is not cached
/// and the next touch retries from this node (ADR-0143).
///
/// Thread-safe (ADR-0143): the 3-state flag is re-observed in a loop so a
/// loser that sees the winner's claim spins for the publish, and a loser
/// that sees a thrown winner reset the flag re-claims. Published `realized`
/// links never change afterwards, so a spinning loser's node stays reachable
/// from wherever it obtained it.
///
/// GC-ROOT: the thunk result is held in a Zig local across the inner
/// realizations (reentrant eval) and the coercion (allocating views), so it
/// is published in a 1-slot manual EvalFrame [ref: .dev/gc_rooting.md §A8].
/// `v` itself is rooted by the caller (the VM operand watermark, tree_walk's
/// args frame, or the published `realized` links of a walk).
pub fn force(rt: *Runtime, env: *env_mod.Env, v: Value, loc: SourceLocation) anyerror!Value {
    return realize(rt, env, v, loc, true);
}

fn realize(rt: *Runtime, env: *env_mod.Env, v: Value, loc: SourceLocation, comptime unwrap: bool) anyerror!Value {
    if (v.tag() != .lazy_seq) return v;
    const ls = v.decodePtr(*LazySeq);
    while (true) {
        switch (@atomicLoad(u8, &ls.realized_flag, .acquire)) {
            // Steady-state lock-free read: the acquire-load synchronises
            // with the winner's release-store, so `realized` is visible.
            flag_realised => return ls.realized,
            flag_pending => {
                // Try to win the realise window. Loser falls through to
                // re-observe (the winner is now CLAIMING).
                if (@cmpxchgStrong(u8, &ls.realized_flag, flag_pending, flag_claiming, .acq_rel, .acquire) != null) continue;
                var gc_roots: [1]Value = .{.nil_val};
                var gc_sp: u16 = 1;
                var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
                root_set.eval_frame_head = &gc_frame;
                defer root_set.eval_frame_head = gc_frame.parent;
                const raw = callBody(rt, env, ls, loc) catch |e| {
                    @atomicStore(u8, &ls.realized_flag, flag_pending, .release);
                    return e;
                };
                gc_roots[0] = raw;
                const stored = settle(rt, env, raw, loc, unwrap) catch |e| {
                    @atomicStore(u8, &ls.realized_flag, flag_pending, .release);
                    return e;
                };
                ls.realized = stored;
                ls.thunk = .nil_val;
                ls.step_a = .nil_val;
                ls.step_b = .nil_val;
                // Publish: the release-store fences the plain `realized` /
                // `thunk` writes so a fast-path acquire-load observes them
                // (clj's volatile-lock visibility trick).
                @atomicStore(u8, &ls.realized_flag, flag_realised, .release);
                return stored;
            },
            // Another thread holds the claim and is invoking the thunk.
            // Spin for the publish, honoring the safepoint protocol
            // (ADR-0092 §2): the thunk eval is exclusion-bearing, so a
            // non-parking spin would stall a stop-the-world collector.
            flag_claiming => {
                if (safepoint.gc_requested.load(.monotonic)) safepoint.park();
                std.atomic.spinLoopHint();
            },
            else => unreachable,
        }
    }
}

/// The value a realized node stores. A non-lazy body is coerced (`RT.seq`).
/// An inner node (`unwrap = false`) stores a lazy body as its raw link; the
/// entry node drains the link chain one inner realization per step (each
/// inner publishes its own link or coerced terminal) and stores the terminal.
fn settle(rt: *Runtime, env: *env_mod.Env, raw: Value, loc: SourceLocation, comptime unwrap: bool) anyerror!Value {
    if (raw.tag() != .lazy_seq) return seqable.seq(rt, env, raw, loc);
    if (!unwrap) return raw;
    var cur = raw;
    while (cur.tag() == .lazy_seq) cur = try realize(rt, env, cur, loc, false);
    return cur;
}

/// `(seq v)` for a lazy node: the coerced terminal of its realization. An
/// inner node reached directly holds a link, so links are followed until a
/// terminal; the entry node of a `force` answers in one step. Non-lazy
/// input is the boundary's own `seqable.seq`.
pub fn seq(rt: *Runtime, env: *env_mod.Env, v: Value, loc: SourceLocation) anyerror!Value {
    if (v.tag() != .lazy_seq) return seqable.seq(rt, env, v, loc);
    var cur = v;
    while (cur.tag() == .lazy_seq) cur = try force(rt, env, cur, loc);
    return cur;
}

/// Per-tag trace fn — walks thunk + realized + meta.
pub fn traceLazySeq(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ls: *LazySeq = @ptrCast(@alignCast(header));
    if (ls.thunk.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.realized.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.meta.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.fuse.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.step_a.heapHeader()) |h| mark_sweep.mark(gc, h);
    if (ls.step_b.heapHeader()) |h| mark_sweep.mark(gc, h);
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
    const nls = try copy(rt, v);
    nls.meta = m;
    return Value.encodeHeapPtr(.lazy_seq, nls);
}

/// Snapshot the state and payload together. Realization clears the thunk, so
/// copying a pending flag then reading fields while a winner publishes could
/// create a pending copy with a nil thunk. Claim pending sources while copying;
/// realized payloads are immutable after their acquire/release publication.
/// No user code runs under the copy claim. The caller roots v across allocation.
fn copy(rt: *Runtime, v: Value) !*LazySeq {
    const ls = v.decodePtr(*LazySeq);
    while (true) {
        const flag = @atomicLoad(u8, &ls.realized_flag, .acquire);
        switch (flag) {
            flag_pending => {
                if (@cmpxchgStrong(u8, &ls.realized_flag, flag_pending, flag_claiming, .acq_rel, .acquire) != null) continue;
            },
            flag_realised => {},
            flag_claiming => {
                if (safepoint.gc_requested.load(.monotonic)) safepoint.park();
                std.atomic.spinLoopHint();
                continue;
            },
            else => unreachable,
        }
        defer if (flag == flag_pending) {
            @atomicStore(u8, &ls.realized_flag, flag_pending, .release);
        };
        const nls = try rt.gc.alloc(LazySeq);
        nls.* = .{ .header = HeapHeader.init(.lazy_seq), .realized_flag = flag, .native = ls.native, .thunk = ls.thunk, .realized = ls.realized, .meta = ls.meta, .fuse = ls.fuse, .step_a = ls.step_a, .step_b = ls.step_b };
        return nls;
    }
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
    const nls = try copy(rt, v);
    nls.fuse = f;
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

    const result = try force(&fix.rt, &env, v, seqable.noloc);
    try testing.expectEqual(@as(i48, 42), result.asInteger());
}

test "force on non-LazySeq input: returns the input unchanged" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    try testing.expectEqual(Value.nil_val, try force(&fix.rt, &env, Value.nil_val, seqable.noloc));
    try testing.expectEqual(
        @as(i48, 7),
        (try force(&fix.rt, &env, Value.initInteger(7), seqable.noloc)).asInteger(),
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
    try testing.expectError(error.LazySeqVTableNotInstalled, force(&fix.rt, &env, v, seqable.noloc));
}

test "force: concurrent first-force invokes the thunk at most once (D-046, ADR-0143)" {
    // future/agent spawn real OS threads, so multiple threads can force the
    // same LazySeq. The CAS-claim must let exactly ONE thread invoke the
    // thunk; the losers observe the published result. Pre-ADR-0143 (no
    // synchronization) all threads read realized_flag == 0 and double-run.
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    const Mock = struct {
        var invocations: std.atomic.Value(usize) = .init(0);
        var start: std.atomic.Value(bool) = .init(false);
        fn callFn(_: *Runtime, _: *env_mod.Env, _: Value, _: []const Value, _: @import("error/info.zig").SourceLocation) anyerror!Value {
            _ = invocations.fetchAdd(1, .monotonic);
            // Widen the realise window so the pre-fix unsynchronized force
            // double-runs deterministically.
            var i: usize = 0;
            while (i < 20_000) : (i += 1) std.atomic.spinLoopHint();
            return Value.nil_val;
        }
        fn typeKey(_: Value) []const u8 {
            return "mock";
        }
    };
    Mock.invocations.store(0, .monotonic);
    Mock.start.store(false, .monotonic);
    fix.rt.vtable = .{ .callFn = Mock.callFn, .valueTypeKey = Mock.typeKey };

    const v = try alloc(&fix.rt, Value.true_val);

    const Worker = struct {
        fn run(rt: *Runtime, e: *env_mod.Env, lazy: Value) void {
            // D-566: a thread that forces is a mutator, so it runs as a
            // registered worker (the shape future/agent workers have). The
            // mock thunk allocates nothing, so the alloc assert does not
            // depend on this; a real thunk would.
            var tx: ?*anyopaque = null;
            var ctx = root_set.workerContext(&tx);
            root_set.registerThread(&ctx) catch return;
            defer root_set.unregisterThread(&ctx);
            while (!Mock.start.load(.acquire)) std.atomic.spinLoopHint();
            _ = force(rt, e, lazy, seqable.noloc) catch unreachable;
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &fix.rt, &env, v });
    Mock.start.store(true, .release); // release all workers simultaneously
    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 1), Mock.invocations.load(.monotonic));
    try testing.expect(isRealised(v));
    try testing.expectEqual(Value.nil_val, v.decodePtr(*const LazySeq).realized);
}

test "seqable accessors on a .list pass through to the list ops" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    // Build (1 2 3) via consHeap.
    const l3 = try list_mod.consHeap(&fix.rt, Value.initInteger(3), Value.nil_val);
    const l2 = try list_mod.consHeap(&fix.rt, Value.initInteger(2), l3);
    const l1 = try list_mod.consHeap(&fix.rt, Value.initInteger(1), l2);

    try testing.expectEqual(@as(i48, 1), (try seqable.first(&fix.rt, &env, l1, seqable.noloc)).asInteger());
    const r = try seqable.rest(&fix.rt, &env, l1, seqable.noloc);
    try testing.expectEqual(@as(i48, 2), (try seqable.first(&fix.rt, &env, r, seqable.noloc)).asInteger());
    const n = try seqable.next(&fix.rt, &env, l1, seqable.noloc);
    try testing.expectEqual(@as(i48, 2), (try seqable.first(&fix.rt, &env, n, seqable.noloc)).asInteger());
}

test "seqable accessors on a cached LazySeq route through realized" {
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

    try testing.expectEqual(@as(i48, 42), (try seqable.first(&fix.rt, &env, ls_val, seqable.noloc)).asInteger());
    const r = try seqable.rest(&fix.rt, &env, ls_val, seqable.noloc);
    try testing.expectEqual(@as(i48, 99), (try seqable.first(&fix.rt, &env, r, seqable.noloc)).asInteger());
}

test "seq follows an inner node's link to the terminal" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    // inner (realised, terminal (7)) <- link (realised, holds inner)
    const terminal = try list_mod.consHeap(&fix.rt, Value.initInteger(7), Value.nil_val);
    const inner = try alloc(&fix.rt, Value.nil_val);
    inner.decodePtr(*LazySeq).realized_flag = flag_realised;
    inner.decodePtr(*LazySeq).realized = terminal;
    const link = try alloc(&fix.rt, Value.nil_val);
    link.decodePtr(*LazySeq).realized_flag = flag_realised;
    link.decodePtr(*LazySeq).realized = inner;

    try testing.expectEqual(terminal, try seq(&fix.rt, &env, link, seqable.noloc));
    try testing.expectEqual(@as(i48, 7), (try seqable.first(&fix.rt, &env, link, seqable.noloc)).asInteger());
}

test "force drains a nested lazy chain iteratively and caches the terminal in the entry node" {
    // A thunk whose body is another LazySeq (filter's no-match branch, a
    // 1e5-deep `(filter pred (iterate inc 0))`) must not recurse per link:
    // each inner is realized one level (its link published), and the entry
    // node stores the TERMINAL so a second read is O(1).
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    const depth: usize = 50_000;
    const Mock = struct {
        var remaining: usize = 0;
        var invocations: usize = 0;
        var first_inner: Value = Value.nil_val;
        fn callFn(rt: *Runtime, _: *env_mod.Env, _: Value, _: []const Value, _: @import("error/info.zig").SourceLocation) anyerror!Value {
            invocations += 1;
            if (remaining == 0) return Value.nil_val;
            remaining -= 1;
            const inner = try alloc(rt, Value.true_val);
            if (first_inner.isNil()) first_inner = inner;
            return inner;
        }
        fn typeKey(_: Value) []const u8 {
            return "mock";
        }
    };
    Mock.remaining = depth;
    Mock.invocations = 0;
    Mock.first_inner = Value.nil_val;
    fix.rt.vtable = .{ .callFn = Mock.callFn, .valueTypeKey = Mock.typeKey };

    const head = try alloc(&fix.rt, Value.true_val);
    const result = try force(&fix.rt, &env, head, seqable.noloc);
    try testing.expect(result.isNil());
    try testing.expectEqual(depth + 1, Mock.invocations);
    // The entry node holds the terminal, not the first link.
    try testing.expect(isRealised(head));
    try testing.expect(head.decodePtr(*const LazySeq).realized.isNil());
    try testing.expect(head.decodePtr(*const LazySeq).thunk.isNil());
    // An inner node holds its link and is followed by `seq` without a re-run.
    const inner = Mock.first_inner;
    try testing.expect(isRealised(inner));
    try testing.expect(inner.decodePtr(*const LazySeq).realized.tag() == .lazy_seq);
    try testing.expect((try seq(&fix.rt, &env, inner, seqable.noloc)).isNil());
    try testing.expectEqual(depth + 1, Mock.invocations);
    // A second read of the head invokes nothing.
    try testing.expect((try force(&fix.rt, &env, head, seqable.noloc)).isNil());
    try testing.expectEqual(depth + 1, Mock.invocations);
}

test "a body that is not seqable raises, resets to PENDING and is retried" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var env = try env_mod.Env.init(&fix.rt);
    defer env.deinit();

    const Mock = struct {
        var invocations: usize = 0;
        fn callFn(_: *Runtime, _: *env_mod.Env, _: Value, _: []const Value, _: @import("error/info.zig").SourceLocation) anyerror!Value {
            invocations += 1;
            return Value.initInteger(1);
        }
        fn typeKey(_: Value) []const u8 {
            return "mock";
        }
    };
    Mock.invocations = 0;
    fix.rt.vtable = .{ .callFn = Mock.callFn, .valueTypeKey = Mock.typeKey };

    const v = try alloc(&fix.rt, Value.true_val);
    try testing.expect(std.meta.isError(force(&fix.rt, &env, v, seqable.noloc)));
    try testing.expect(!isRealised(v));
    try testing.expect(!v.decodePtr(*const LazySeq).thunk.isNil());
    try testing.expect(std.meta.isError(force(&fix.rt, &env, v, seqable.noloc)));
    try testing.expectEqual(@as(usize, 2), Mock.invocations);
}
