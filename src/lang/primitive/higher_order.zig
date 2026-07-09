// SPDX-License-Identifier: EPL-2.0
//! Higher-order primitives — `apply` / `reduce` / `every?` / `some` /
//! `some?` per ADR-0033 D6 + v5 §7 transducer spec. (`into` moved to
//! core.clj as a multi-arity def — see the retirement note below.)
//!
//! `reduce` carries an IReduce protocol fast-path (receiver-first
//! `-reduce` dispatch, D-069) plus PERF arms for range / vector /
//! chunk sources, falling through to the generic seq walk. The
//! map/filter/take/drop/keep/remove + partial/comp/complement/
//! constantly/juxt surface lives in Layer 3 `.clj` over these
//! primitives; the eager `-take-eager` leaf below is what those
//! defns call.
//!
//! ## Pattern
//!
//! Same shape as sequence.zig + collection.zig: a Layer 2 Tag switch
//! dispatching to Layer 0 helpers + `rt.vtable.callFn` for invoking
//! user fns, with a `.protocol_extended` slow-path arm (D-069) for
//! user-extended types alongside the fast-path Tag arms.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: list, vector, map, set, reduced, sequence (Layer 2)
//! Clojure peer: none (Pattern B1 direct intern, public surface)

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

const reduced = @import("../../runtime/collection/reduced.zig");
const range_mod = @import("../../runtime/collection/range.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const compare_mod = @import("../../runtime/compare.zig");
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const lazy_seq_mod = @import("../../runtime/lazy_seq.zig");
const sequence = @import("sequence.zig");
const tree_walk = @import("../../eval/backend/tree_walk.zig");
const root_set = @import("../../runtime/gc/root_set.zig");

// --- apply ---

/// Implements clojure.core/apply.
/// Spec: `(apply f args...)` calls f with the trailing args expanded.
///   - `(apply f xs)`             — call f with each element of xs
///   - `(apply f a b xs)`         — call f with a, b, then xs elements
///   - `(apply f a b c d e xs)`   — 5 leading args + xs
/// JVM reference: clojure.lang.RT.applyTo / clojure.core/apply
/// cw v1 tier: A (Phase 6.16.a-3.1)
///
/// ADR-0042 (row 7.9): variadic-callee bind-direct fast-path. When `f`
/// is a user Fn whose variadic arity exactly matches `leading.len` AND
/// trailing has a seq-shaped tag (list / cons / chunked_cons /
/// lazy_seq / nil), pass `args[1..]` (= `[leading..., trailing]`)
/// straight through. `tree_walk.callFunction`'s rest-pack gate then
/// binds trailing directly to the `& rest` slot — no walk, no
/// realisation. Other callee shapes (fixed-arity, builtin, keyword,
/// map-as-fn, ...) and non-seq trailings fall through to the eager
/// spread path so the arity-matching contract on those callables is
/// preserved.
pub fn applyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2) {
        return error_catalog.raise(.arity_below_min, loc, .{
            .fn_name = "apply",
            .got = args.len,
            .min = 2,
        });
    }
    const f = args[0];
    const trailing = args[args.len - 1];
    const leading = args[1 .. args.len - 1];

    if (canBindDirect(f, leading.len, trailing)) {
        // ADR-0042 am1: bind the trailing seq straight to `& rest`
        // (apply's lazy-preserving spread) via the dedicated entry — NOT
        // the generic callFunction, which always cons-wraps. canBindDirect
        // has verified `f` is a variadic fn_val whose `& rest` matches.
        return try tree_walk.callFunctionBindingRest(rt, env, f, args[1..], loc);
    }

    // Eager spread: walk the trailing seqable, collecting into a flat slice.
    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(rt.gpa);
    try collected.appendSlice(rt.gpa, leading);

    // `seq` the trailing operand so an EMPTY seqable (incl. an empty `.list`
    // / `.cons`, which are non-nil) collapses to nil — otherwise the walk
    // below runs once and spreads a spurious `(first empty)` = nil
    // (`(apply + '())` → "+ got nil"). seq on a realised seq returns it
    // unchanged; apply already eagerly walks, so no laziness is lost.
    var cur: Value = trailing;
    if (!cur.isNil()) {
        cur = try sequence.seqFn(rt, env, &.{cur}, loc);
    }
    while (!cur.isNil()) {
        try collected.append(rt.gpa, try sequence.firstFn(rt, env, &.{cur}, loc));
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    return try invokeCallable(rt, env, f, collected.items, loc);
}

fn canBindDirect(f: Value, leading_count: usize, trailing: Value) bool {
    if (f.tag() != .fn_val) return false;
    const fn_ptr = f.decodePtr(*const tree_walk.Function);
    const v = fn_ptr.variadic orelse return false;
    if (v.arity != leading_count) return false;
    return switch (trailing.tag()) {
        .list, .cons, .chunked_cons, .lazy_seq, .nil => true,
        else => false,
    };
}

/// Invoke a callable Value (builtin or Function) with args via the
/// runtime vtable. Shared by apply / the HOFs / `swap!` (atom.zig).
pub fn invokeCallable(rt: *Runtime, env: *Env, f: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (f.tag() == .builtin_fn) {
        const fn_ptr = f.asBuiltinFn(dispatch.BuiltinFn);
        return fn_ptr(rt, env, args, loc);
    }
    if (rt.vtable) |vt| {
        return try vt.callFn(rt, env, f, args, loc);
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "apply",
        .expected = "callable (fn or builtin)",
        .actual = @tagName(f.tag()),
    });
}

// --- reduce ---

/// Implements clojure.core/reduce.
/// Spec:
///   `(reduce f coll)`      — reduces coll, using (first coll) as init
///   `(reduce f init coll)` — reduces with explicit init
/// `(reduced x)` returned by f terminates the reduction early with x.
/// JVM reference: clojure.lang.RT.reduce / clojure.core.protocols/IReduce
/// cw v1 tier: A. IReduce protocol fast-path (D-069) is tried first,
/// then PERF source arms, then the generic seq walk.
pub fn reduceFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2 or args.len > 3) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "reduce",
            .expected = 2,
            .got = args.len,
        });
    }
    const f = args[0];

    // D-251 GC-root reduce's live Values across reentrant eval. `reduce` drives
    // the reducing fn (`invokeCallable` -> VM eval) and forces lazy / chunked
    // seq elements (`firstFn`/`nextFn`/`seqFn` -> VM eval); a collect at any
    // nested back-edge poll would sweep Zig locals on no operand stack -> UAF.
    // Reusing the VM's `EvalFrame` chain (ADR-0091/0094, the DA-fork pick over a
    // parallel root stack): publish a 3-slot operand frame [f, acc, cur] the
    // root walk covers for free (self TLS + worker slot). `f` is rooted for the
    // whole call (a `.clj` reducing-fn closure must survive BETWEEN iterations —
    // reduce's `args` live above the caller's popped sp, so they are NOT rooted
    // by the caller frame); slot 2 holds the cursor AND, before the first
    // `seqFn`, the original `coll` (whose lazy-seq thunk closure transitively
    // roots the source — e.g. the `(range …)` a `map` captured). acc/cur are
    // refreshed before each reentrant call below.
    // GC-ROOT: A2 — reentrant-primitive manual frame [f, acc/coll, cur] (ADR-0094) [ref: .dev/gc_rooting.md §A,C]
    var gc_roots: [3]Value = .{ f, .nil_val, .nil_val };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{
        .stack = &gc_roots,
        .sp = &gc_sp,
        .locals = &.{},
        .parent = root_set.eval_frame_head,
    };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;

    // Row 7.7 cycle 4: IReduce protocol fast-path bypass. If the
    // receiver carries an `IReduce -reduce` MethodEntry (via `extend-type`),
    // call it directly with receiver-first argument order — `(reduce f
    // coll)` becomes `(-reduce coll f)`, `(reduce f init coll)` becomes
    // `(-reduce coll f init)`. Skips the `seq → first → rest` walk
    // entirely, enabling JVM-style early termination on user types.
    // Cycle 4 collapses JVM's IReduce + IReduceInit split into a single
    // arity-overloaded `IReduce -reduce` per §7 DIVERGENCE in the row 7.7
    // survey. Falls through to the seq-walk when no MethodEntry is
    // registered (lazy_seq's own IReduce impl is row 7.9 / D-072).
    const coll = args[args.len - 1];
    var ireduce_args_buf: [3]Value = undefined;
    const ireduce_args: []const Value = if (args.len == 3) blk: {
        ireduce_args_buf[0] = coll;
        ireduce_args_buf[1] = f;
        ireduce_args_buf[2] = args[1];
        break :blk ireduce_args_buf[0..3];
    } else blk: {
        ireduce_args_buf[0] = coll;
        ireduce_args_buf[1] = f;
        break :blk ireduce_args_buf[0..2];
    };
    var cs: dispatch.CallSite = .{};
    if (try dispatch.dispatchOrNull(rt, env, &cs, coll, "IReduce", "-reduce", ireduce_args, loc)) |v| {
        return if (reduced.isReduced(v)) reduced.unreduce(v) else v;
    }

    // PERF: tight i64 reduce over a compact range — element `i` is
    // `start + i*step`, so no seq node / chunk is allocated per element
    // (the generic walk below would materialise a chunked_cons). A live
    // `.range` always has count ≥ 1 (empty → nil). [refs: O-001, D-163]
    if (coll.tag() == .range) {
        const n = range_mod.countOf(coll);
        var racc: Value = if (args.len == 3) args[1] else range_mod.elementAt(coll, 0);
        var ri: i64 = if (args.len == 3) 0 else 1;
        while (ri < n) : (ri += 1) {
            gc_roots[1] = racc; // root across the reducing-fn eval
            const rstep = try invokeCallable(rt, env, f, &.{ racc, range_mod.elementAt(coll, ri) }, loc);
            if (reduced.isReduced(rstep)) return reduced.unreduce(rstep);
            racc = rstep;
        }
        return racc;
    }

    // PERF: index-walk a vector instead of seqFn → vectorToList (which
    // builds an N-element eager cons list before the walk). `(reduce f
    // bigvec)` / `(into to bigvec)` (into = reduce conj) went O(n)
    // intermediate alloc → O(1). [refs: O-002, D-163]
    if (coll.tag() == .vector) {
        const n = vector_mod.count(coll);
        var racc: Value = undefined;
        var ri: u32 = 0;
        if (args.len == 3) {
            racc = args[1];
        } else {
            if (n == 0) return try invokeCallable(rt, env, f, &.{}, loc);
            racc = vector_mod.nth(coll, 0);
            ri = 1;
        }
        while (ri < n) : (ri += 1) {
            gc_roots[1] = racc; // root across the reducing-fn eval
            const rstep = try invokeCallable(rt, env, f, &.{ racc, vector_mod.nth(coll, ri) }, loc);
            if (reduced.isReduced(rstep)) return reduced.unreduce(rstep);
            racc = rstep;
        }
        return racc;
    }

    // PERF: D-386 (O-023) fused reduce — when `coll` is a (map/filter …) lazy
    // chain carrying a `[xform source]` fusion descriptor, reduce its ORIGINAL
    // source ONCE through the captured transducer (clojure.core/transduce — the
    // Eduction/transduce engine, which already beats Python), skipping the
    // per-element lazy thunk-force walk below. Invisible to laziness: reduce
    // realizes its source fully, so fusing changes no observable Value (ADR-0036
    // dual-backend parity holds — pure speed). ONLY the 3-arg form: 2-arg reduce
    // seeds init from (first coll), but transduce seeds from `(f)` — different
    // semantics for a general f, so 2-arg falls through to the generic walk.
    // [refs: O-023, D-386]
    if (args.len == 3 and coll.tag() == .lazy_seq and !lazy_seq_mod.fuseOf(coll).isNil()) {
        // PERF: O-023 fusion helps a NON-chunked source (a cons-list map/filter
        // chain — the generic walk forces a `.clj` lazy thunk per transform per
        // element). But for a CHUNKED source (range/vector-backed), the generic
        // walk's in-Zig chunk drain (`-chunk-map-step`, O-032, + the chunked arm
        // below) is ~2.5× FASTER than the `.clj`-transducer-per-element fused path
        // (measured: `(into [] (map f (range 100k)))` 39→16 ms; gc_large_heap
        // 59→35 ms). So fire fusion ONLY when the realized head is non-chunked; a
        // chunked head falls through to the generic walk. The `seq` force is
        // memoized — the generic walk re-seqs the same node. [refs: O-045, O-023, O-032]
        gc_roots[1] = args[1];
        gc_roots[2] = coll;
        const head = try sequence.seqFn(rt, env, &.{coll}, loc);
        if (head.tag() != .chunked_cons) {
            // Delegate to the `.clj` `-fused-reduce`: it walks the `[xform coll]`
            // fuse chain (composing transducers inner-first, reaching the base)
            // and runs ONE `(transduce composed (completing f) init base)` pass.
            if (env.findNs("clojure.core")) |core| {
                if (core.resolve("-fused-reduce")) |fr| {
                    gc_roots[1] = args[1]; // init
                    gc_roots[2] = coll; // fuse descriptor transitively roots the chain
                    return try invokeCallable(rt, env, fr.deref(), &.{ f, args[1], coll }, loc);
                }
            }
        }
    }

    var acc: Value = undefined;
    var cur: Value = undefined;
    if (args.len == 3) {
        acc = args[1];
        gc_roots[1] = acc; // init/transient rooted across the first force
        gc_roots[2] = args[2]; // the coll (its lazy-seq thunk closure roots the source)
        cur = try sequence.seqFn(rt, env, &.{args[2]}, loc);
    } else {
        // (reduce f coll): use (first coll) as init.
        gc_roots[2] = args[1]; // the coll rooted across the first force
        cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
        if (cur.isNil()) {
            // Empty coll, no init → call (f) with zero args (= rf init).
            return try invokeCallable(rt, env, f, &.{}, loc);
        }
        gc_roots[2] = cur; // root the seq across (first coll)'s thunk-forcing
        acc = try sequence.firstFn(rt, env, &.{cur}, loc);
        gc_roots[1] = acc;
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    while (!cur.isNil()) {
        gc_roots[1] = acc; // root acc + cur across every reentrant call below
        gc_roots[2] = cur;
        // PERF: drain a whole chunk per step (slots[offset..count]) instead
        // of one firstFn/nextFn per element, so a chunked source (range seq,
        // chunk-aware map/filter) pays the seq-node overhead once per 32
        // elements. [refs: O-004, D-163]
        if (cur.tag() == .chunked_cons) {
            const cnt = chunked_cons.currentChunkCount(cur);
            var ci: u32 = 0;
            while (ci < cnt) : (ci += 1) {
                const elt = chunked_cons.currentChunkNth(cur, ci);
                gc_roots[1] = acc; // acc grows each step; re-root before the eval
                const step = try invokeCallable(rt, env, f, &.{ acc, elt }, loc);
                if (reduced.isReduced(step)) return reduced.unreduce(step);
                acc = step;
            }
            // Skip the whole drained chunk; re-seq the tail (may be a
            // lazy_seq / chunked_cons / cons / nil).
            gc_roots[1] = acc; // re-root acc (cur already rooted from loop top)
            cur = try sequence.seqFn(rt, env, &.{chunked_cons.chunkRest(cur)}, loc);
            continue;
        }
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const step = try invokeCallable(rt, env, f, &.{ acc, elt }, loc);
        if (reduced.isReduced(step)) {
            return reduced.unreduce(step);
        }
        acc = step;
        gc_roots[1] = acc; // re-root the new acc across (next coll)'s thunk-forcing
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    return acc;
}

// `into` moved to core.clj (Layer 2) as a multi-arity def over
// reduce/transduce — it gained the 3-arg `(into to xform from)`
// transducer form, which the Zig 2-arg primitive could not host. No
// other Zig code called the primitive, so it is fully retired here.

// --- every? ---

/// Implements clojure.core/every?.
/// Spec: `(every? pred coll)` — returns true iff pred is truthy for
/// every element; vacuously true on empty coll.
/// JVM reference: clojure.core/every?
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn everyQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("every?", args, 2, loc);
    const pred = args[0];
    // GC-ROOT: A2/C2 — root pred + coll/cursor across firstFn/pred/nextFn reentrant
    // eval (D-252) [ref: .dev/gc_rooting.md §C]. slot 1 holds the original coll
    // across the first seqFn (its lazy-seq thunk closure roots the source), then
    // the cursor each iteration.
    var gc_roots: [2]Value = .{ pred, args[1] };
    var gc_sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
    while (!cur.isNil()) {
        gc_roots[1] = cur;
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const r = try invokeCallable(rt, env, pred, &.{elt}, loc);
        if (isFalsy(r)) return .false_val;
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    return .true_val;
}

// --- some ---

/// Implements clojure.core/some.
/// Spec: `(some pred coll)` — returns the first truthy `(pred x)`
/// result, or `nil` if none truthy.
/// JVM reference: clojure.core/some
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn someFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("some", args, 2, loc);
    const pred = args[0];
    // GC-ROOT: A2/C3 — root pred + coll/cursor across firstFn/pred/nextFn reentrant
    // eval (D-252) [ref: .dev/gc_rooting.md §C]. See everyQFn for the slot shape.
    var gc_roots: [2]Value = .{ pred, args[1] };
    var gc_sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
    while (!cur.isNil()) {
        gc_roots[1] = cur;
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const r = try invokeCallable(rt, env, pred, &.{elt}, loc);
        if (!isFalsy(r)) return r;
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    return .nil_val;
}

// --- some? ---

/// Implements clojure.core/some?.
/// Spec: `(some? x)` — true iff `x` is not nil.
/// JVM reference: clojure.core/some?
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn someQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("some?", args, 1, loc);
    return if (args[0].isNil()) .false_val else .true_val;
}

// --- eager leaves (Phase 6.16.a-3.2) ---
//
// The `-name` `defn-` `^:private :zig-leaf` pattern from ADR-0033 D4.
// These are the eager backends for clojure.core's map/filter/take/
// drop/keep/remove — the Layer 3 `.clj` shim calls them directly when
// the multi-arity form is the eager one. The transducer 1-arg arities
// live (D-177) in core.clj over reduce/reduced; only the
// lazy `sequence`/`eduction` pull surface remains (D-160).

// `-map-eager` / `-filter-eager` / `-drop-eager` deleted — map/filter
// are lazy `.clj` (ADR-0054 cycle 2), drop is lazy `.clj` (cycle 3).
// `-take-eager` remains (take is bounded-eager: it realizes only N, so
// it already terminates on an infinite source).

/// `(-take-eager n coll)` — eager list of first n elements.
pub fn takeEagerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("-take-eager", args, 2, loc);
    const n_val = args[0];
    if (n_val.tag() != .integer) {
        return error_catalog.raise(.type_arg_not_integer, loc, .{
            .fn_name = "-take-eager",
            .actual = @tagName(n_val.tag()),
        });
    }
    const n = n_val.asInteger();
    // (take 0 …) / (take -1 …) → () not nil (D-164): JVM take yields an
    // empty seq for a non-positive count.
    if (n <= 0) return try list_mod.emptyList(rt);
    // D-244 #4b: `cur` (the source cursor) AND each `collected` element are held
    // in a gpa `ArrayList` the GC does NOT trace, so a collect during `nextFn`'s
    // alloc (alloc-torture / ADR-0028 auto-collect) sweeps the source chunk +
    // any heap elements → reads as nil (`(take 5 (range 20))` → `(f nil)`).
    // Bracket the bounded build in the fabrication no-collect region, like the
    // other multi-alloc builders (vector/map/set/list + range.seqChunk).
    // [ref: .dev/gc_rooting.md §A]
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(rt.gpa);
    var remaining: i64 = n;
    while (!cur.isNil() and remaining > 0) : (remaining -= 1) {
        try collected.append(rt.gpa, try sequence.firstFn(rt, env, &.{cur}, loc));
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    return try buildListFromSlice(rt, collected.items);
}

/// `(-range start end step)` — produce a compact `.range` value (ADR-0063,
/// O-001) for a finite integer range, or nil for an empty one. core.clj's
/// `range` 3-arg arm calls this only when all args are fixed-precision
/// integers and step≠0 (the `int?` + `(not= step 0)` gate); float / bigint /
/// step-0 ranges stay the lazy `.clj` body. The integer-tag guard here is
/// defensive — a direct mis-call raises rather than mis-producing.
pub fn rangeLeafFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("-range", args, 3, loc);
    for (args) |a| {
        if (a.tag() != .integer) {
            return error_catalog.raise(.type_arg_not_integer, loc, .{
                .fn_name = "-range",
                .actual = @tagName(a.tag()),
            });
        }
    }
    // An empty integer range (`(range 0)` / `(range 5 5)`) is `()` not nil
    // (D-164); `fromBounds` returns nil for count 0, lifted here. Internal
    // range ops keep `make`'s nil-for-empty (their callers test isNil).
    const r = try range_mod.fromBounds(rt, args[0].asInteger(), args[1].asInteger(), args[2].asInteger());
    return if (r.isNil()) try list_mod.emptyList(rt) else r;
}

// `-keep-eager` / `-remove-eager` deleted — keep/remove are lazy `.clj`
// now (ADR-0054 cycle 2; remove = filter-complement).

const list_mod = @import("../../runtime/collection/list.zig");

/// Build a Clojure list (Cons chain) from a Zig slice. Empty slice
/// yields the interned empty list `()` (D-164 / clj-parity C1), so an
/// eager seq op over an empty result (`(take 0 …)`) reads as `()` not nil.
fn buildListFromSlice(rt: *Runtime, items: []const Value) !Value {
    if (items.len == 0) return try list_mod.emptyList(rt);
    var acc: Value = .nil_val;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        acc = try list_mod.consHeap(rt, items[i], acc);
    }
    return acc;
}

// --- helpers ---

/// Clojure truthiness: only `nil` and `false` are falsy.
fn isFalsy(v: Value) bool {
    return v.isNil() or v == Value.false_val;
}

// --- native sort (O-007) ---

/// Context for the natural-order stable sort: `valueCompare` is fallible
/// (uncomparable values raise), but `std.mem.sort`'s `lessThanFn` cannot
/// propagate an error, so the first failure is stashed here and the sort is
/// drained returning `false` (any order — the result is discarded). Checked
/// after the sort.
const NaturalSortCtx = struct {
    rt: *Runtime,
    env: *Env,
    loc: SourceLocation,
    err: ?anyerror = null,
};

fn naturalLessThan(ctx: *NaturalSortCtx, a: Value, b: Value) bool {
    if (ctx.err != null) return false;
    // A deftype declaring java.lang.Comparable supplies its own ordering
    // (instaparse's AutoFlattenSeq): consult Comparable/-compare-to before
    // the native valueCompare — the same split the compare primitive applies.
    if (a.tag() == .typed_instance or a.tag() == .reified_instance) {
        var cs: dispatch.CallSite = .{};
        const maybe = dispatch.dispatchOrNull(ctx.rt, ctx.env, &cs, a, "Comparable", "-compare-to", &.{ a, b }, ctx.loc) catch |e| {
            ctx.err = e;
            return false;
        };
        if (maybe) |r| {
            if (r.tag() == .integer) return r.asInteger() < 0;
        }
    }
    const ord = compare_mod.valueCompare(ctx.rt, a, b, ctx.loc) catch |e| {
        ctx.err = e;
        return false;
    };
    return ord == .lt;
}

/// Context for the keyed stable sort: sorts an index permutation by the
/// precomputed `keys` (parallel to the element vector), `valueCompare` on the
/// keys. Same error-stash discipline as `NaturalSortCtx`.
const KeySortCtx = struct {
    rt: *Runtime,
    keys: []const Value,
    loc: SourceLocation,
    err: ?anyerror = null,
};

fn keyLessThan(ctx: *KeySortCtx, ia: u32, ib: u32) bool {
    if (ctx.err != null) return false;
    const ord = compare_mod.valueCompare(ctx.rt, ctx.keys[ia], ctx.keys[ib], ctx.loc) catch |e| {
        ctx.err = e;
        return false;
    };
    return ord == .lt;
}

/// `(clojure.core/-sort-by-keys keys elems)` — stable sort of `elems` by the
/// parallel precomputed `keys` vector via `compare` (`valueCompare`), the
/// native fast path behind `(sort-by f coll)`. PERF (O-010): the naive form is
/// the `.clj` `-msort` with a `(fn [a b] (compare (f a) (f b)))` comparator
/// that re-enters eval AND re-applies `f` on EVERY comparison (O(n log n) `f`
/// calls). Here the caller precomputes `keys = (mapv f coll)` (one `f` per
/// element), and this sorts an index permutation by `valueCompare` on the keys
/// — no eval reentry (so no GC safepoint mid-sort → no frame rooting), and the
/// keys are compared directly. Stable: equal keys keep ascending index order
/// (block sort is stable + the index array starts ascending), matching JVM
/// `sort-by` stability. Fewer `f` calls than JVM (n vs n log n) — observably
/// identical for a pure key fn (the F-011 contract); a side-effecting key fn is
/// undefined either way.
fn sortByKeysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len != 2) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "-sort-by-keys", .expected = 2, .got = args.len });
    }
    const keys_v = args[0];
    const elems_v = args[1];
    const n = vector_mod.count(elems_v);
    if (n <= 1) return elems_v;
    const keys = try rt.gpa.alloc(Value, n);
    defer rt.gpa.free(keys);
    const idx = try rt.gpa.alloc(u32, n);
    defer rt.gpa.free(idx);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        keys[i] = vector_mod.nth(keys_v, i);
        idx[i] = i;
    }
    var ctx: KeySortCtx = .{ .rt = rt, .keys = keys, .loc = loc };
    std.mem.sort(u32, idx, &ctx, keyLessThan);
    if (ctx.err) |e| return e;
    const out = try rt.gpa.alloc(Value, n);
    defer rt.gpa.free(out);
    i = 0;
    while (i < n) : (i += 1) out[i] = vector_mod.nth(elems_v, idx[i]);
    return vector_mod.fromSlice(rt, out);
}

/// `(clojure.core/-sort-natural v)` — stable natural-order sort of a vector via
/// `compare` (`valueCompare`), the native fast path behind `(sort coll)`.
/// PERF (O-007): the naive form is the `.clj` `-msort` merge sort, which pays
/// per-element `take`/`drop`/`vec`/`rest`/`conj`/`first` + a per-comparison
/// `compare` call through the eval machinery. This copies the vector into a
/// flat buffer, runs `std.mem.sort` (stable block sort) calling `valueCompare`
/// directly (no eval reentry — so no GC safepoint can fire mid-sort, hence no
/// frame rooting is needed), and rebuilds via `vector.fromSlice` (O-003 O(n)
/// trie build). Custom-comparator `(sort comp coll)` / `sort-by` stay on the
/// `.clj` `-msort` (a user comparator re-enters eval; the natural path does
/// not). Stable: `valueCompare` ties → `.eq` → `lessThan` false → block sort
/// preserves input order (matches `-merge-sorted`'s left-wins tie rule).
fn sortNaturalFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len != 1) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "-sort-natural", .expected = 1, .got = args.len });
    }
    const v = args[0];
    const n = vector_mod.count(v);
    if (n <= 1) return v; // 0/1 elements are already sorted
    const buf = try rt.gpa.alloc(Value, n);
    defer rt.gpa.free(buf);
    var i: u32 = 0;
    while (i < n) : (i += 1) buf[i] = vector_mod.nth(v, i);
    var ctx: NaturalSortCtx = .{ .rt = rt, .env = env, .loc = loc };
    std.mem.sort(Value, buf, &ctx, naturalLessThan);
    if (ctx.err) |e| return e;
    return vector_mod.fromSlice(rt, buf);
}

/// PERF: D-386 (O-023) `-lazy-set-fuse` — return a copy of a lazy_seq carrying
/// the `{:xform :coll}` fusion descriptor (a non-lazy_seq passes through). The
/// thunk body is unchanged, so seq ops are identical; reduce reads the fuse to
/// transduce in one pass. [refs: O-023]
pub fn lazySetFuseFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("-lazy-set-fuse", args, 2, loc);
    if (args[0].tag() != .lazy_seq) return args[0];
    return try lazy_seq_mod.setFuse(rt, args[0], args[1]);
}

/// PERF: D-386 (O-023) `-lazy-get-fuse` — the fusion descriptor of a coll (nil if
/// none / not a lazy_seq). Used by `map`/`filter` to compose a chain. [refs: O-023]
pub fn lazyGetFuseFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("-lazy-get-fuse", args, 1, loc);
    return lazy_seq_mod.fuseOf(args[0]);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "apply", .f = &applyFn },
    .{ .name = "reduce", .f = &reduceFn },
    .{ .name = "every?", .f = &everyQFn },
    .{ .name = "some", .f = &someFn },
    .{ .name = "some?", .f = &someQFn },
};

/// `-name` eager leaves per ADR-0033 D4 — registered in
/// `clojure.core` (NOT `rt`) with `^:private :zig-leaf` metadata.
///
/// **Why clojure.core, not rt**: D-071 Part 3 closes the
/// `^:private` enforcement on these leaves. The analyzer cross-ns
/// private check (`analyzer.zig:374-381`) compares
/// `env.current_ns` against `v_ptr.ns`; for the wrappers in
/// `core.clj` (`(def map (fn* [f coll] (-map-eager f coll)))`)
/// to resolve same-ns, the leaf's owning Var must live in the
/// same namespace as the wrapper. Since `core.clj` opens with
/// `(in-ns 'clojure.core)` (landed 6.16.b-3, commit 6211d8a),
/// the leaves belong here too.
///
/// User-ns callers reaching for `(clojure.core/-map-eager …)`
/// then trip the cross-ns private check and get
/// `private_access_error` — the intended ADR-0033 D4 contract.
const LEAF_ENTRIES = [_]Entry{
    .{ .name = "-take-eager", .f = &takeEagerFn },
    .{ .name = "-range", .f = &rangeLeafFn },
    .{ .name = "-sort-natural", .f = &sortNaturalFn },
    .{ .name = "-sort-by-keys", .f = &sortByKeysFn },
    .{ .name = "-lazy-set-fuse", .f = &lazySetFuseFn },
    .{ .name = "-lazy-get-fuse", .f = &lazyGetFuseFn },
};

pub fn register(
    env: *Env,
    rt_ns: *env_mod.Namespace,
    clojure_core_ns: *env_mod.Namespace,
) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
    for (LEAF_ENTRIES) |it| {
        _ = try env.intern(clojure_core_ns, it.name, Value.initBuiltinFn(it.f), .{
            .private = true,
            .zig_leaf = true,
        });
    }
}

// --- tests ---

const testing = std.testing;

test "some? true for non-nil, false for nil" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    try testing.expectEqual(Value.true_val, try someQFn(&rt, &env, &.{Value.initInteger(0)}, .{ .line = 0, .column = 0 }));
    try testing.expectEqual(Value.false_val, try someQFn(&rt, &env, &.{Value.nil_val}, .{ .line = 0, .column = 0 }));
}

test "isFalsy: only nil + false are falsy" {
    try testing.expect(isFalsy(Value.nil_val));
    try testing.expect(isFalsy(Value.false_val));
    try testing.expect(!isFalsy(Value.true_val));
    try testing.expect(!isFalsy(Value.initInteger(0))); // 0 is truthy in Clojure
}
