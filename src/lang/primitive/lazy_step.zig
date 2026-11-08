// SPDX-License-Identifier: EPL-2.0
//! Native lazy-seq producers for one-coll `map`, `filter`, `take` and
//! `iterate` (O-110, card CLJW-PERF-LAZY-REALIZE).
//!
//! Each `__X-lazy` builtin returns an UNREALIZED lazy node whose body is a
//! native step (`lazy_seq.allocNative`) instead of an interpreted arity-0
//! closure. Realizing the node runs the step in Zig: one node per element
//! (or per 32-chunk on a chunked source), exactly the shape of the clj
//! bodies they replace, so realization counts, chunk geometry and call order
//! are unchanged:
//!
//!   map     (lazy-seq (when-let [s (seq coll)]
//!             (if (chunked-seq? s)
//!               (chunk-cons <f over the chunk> (map f (chunk-rest s)))
//!               (cons (f (first s)) (map f (rest s))))))
//!   filter  same, survivors only; a non-match continues with the rest
//!   take    (lazy-seq (when (pos? n) (when-let [s (seq coll)]
//!             (cons (first s) (take (dec n) (rest s))))))
//!   iterate (lazy-seq (cons x (iterate f (f x))))
//!
//! What goes away per element: the closure allocation for the lazy body,
//! the eval re-entry that runs it, and the interpreted let/if/seq/first/rest
//! tree. `f`/`pred` still run through `invokeCallable`.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: lazy_seq.allocNative, seqable (Layer 0), chunked_seq,
//! chunked_cons, list.consSeqHeap, chunk_transform, higher_order.invokeCallable
//! Clojure peer: -map-lazy / -filter-lazy / take / iterate (core.clj)

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;
const seqable = @import("../../runtime/seqable.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const list = @import("../../runtime/collection/list.zig");
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const chunked_seq = @import("../../runtime/collection/chunked_seq.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const chunk_transform = @import("chunk_transform.zig");
const invokeCallable = @import("higher_order.zig").invokeCallable;
const big_int = @import("../../runtime/numeric/big_int.zig");

const nb_i48_max: i64 = (1 << 47) - 1;

/// A 3-slot reentrant-primitive root frame (ADR-0094): [op, cursor, value].
const Roots = struct {
    slots: [3]Value,
    sp: u16 = 3,
    frame: root_set.EvalFrame = undefined,

    fn push(self: *Roots) void {
        self.frame = .{ .stack = &self.slots, .sp = &self.sp, .locals = &.{}, .parent = root_set.eval_frame_head };
        root_set.eval_frame_head = &self.frame;
    }
    fn pop(self: *Roots) void {
        root_set.eval_frame_head = self.frame.parent;
    }
};

// The step pointers are encoded at run time (a fn address is not comptime).
fn mapStepV() Value {
    return Value.initBuiltinFn(&mapStep);
}
fn filterStepV() Value {
    return Value.initBuiltinFn(&filterStep);
}
fn takeStepV() Value {
    return Value.initBuiltinFn(&takeStep);
}
fn iterateStepV() Value {
    return Value.initBuiltinFn(&iterateStep);
}

/// PERF: realize one `(map f coll)` node in Zig [refs: O-110, O-032]
fn mapStep(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const f = args[0];
    // GC-ROOT: [f, cursor, mapped/buf]: the step operands live in the node
    // being realized, but every fresh cursor, buffer and tail is rooted here
    // across the user fn and the allocations [ref: .dev/gc_rooting.md].
    var r: Roots = .{ .slots = .{ f, args[1], .nil_val } };
    r.push();
    defer r.pop();
    const s = try seqable.seq(rt, env, args[1], loc);
    r.slots[1] = s;
    if (s.isNil()) return .nil_val;
    if (chunked_seq.isChunked(s)) {
        r.slots[2] = try chunk_transform.chunkMapStepFn(rt, env, &.{ f, s }, loc);
        r.slots[1] = try chunked_seq.chunkRest(rt, s);
        r.slots[1] = try lazy_seq.allocNative(rt, mapStepV(), f, r.slots[1]);
        return try chunked_cons.chunkCons(rt, r.slots[2], r.slots[1]);
    }
    r.slots[2] = try invokeCallable(rt, env, f, &.{try seqable.first(rt, env, s, loc)}, loc);
    r.slots[1] = try seqable.rest(rt, env, s, loc);
    r.slots[1] = try lazy_seq.allocNative(rt, mapStepV(), f, r.slots[1]);
    return try list.consSeqHeap(rt, r.slots[2], r.slots[1]);
}

/// PERF: realize one `(filter pred coll)` node in Zig; a non-match (or an
/// all-dropped chunk) continues in this loop instead of through a nested
/// lazy node [refs: O-110, O-032]
fn filterStep(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const pred = args[0];
    // GC-ROOT: [pred, cursor, survivor/buf], as mapStep.
    var r: Roots = .{ .slots = .{ pred, args[1], .nil_val } };
    r.push();
    defer r.pop();
    while (true) {
        const s = try seqable.seq(rt, env, r.slots[1], loc);
        r.slots[1] = s;
        if (s.isNil()) return .nil_val;
        if (chunked_seq.isChunked(s)) {
            r.slots[2] = try chunk_transform.chunkFilterStepFn(rt, env, &.{ pred, s }, loc);
            r.slots[1] = try chunked_seq.chunkRest(rt, s);
            if (r.slots[2].decodePtr(*const chunked_cons.ChunkBuffer).count == 0) continue;
            r.slots[1] = try lazy_seq.allocNative(rt, filterStepV(), pred, r.slots[1]);
            return try chunked_cons.chunkCons(rt, r.slots[2], r.slots[1]);
        }
        r.slots[2] = try seqable.first(rt, env, s, loc);
        const keep = (try invokeCallable(rt, env, pred, &.{r.slots[2]}, loc)).isTruthy();
        r.slots[1] = try seqable.rest(rt, env, s, loc);
        if (keep) {
            r.slots[1] = try lazy_seq.allocNative(rt, filterStepV(), pred, r.slots[1]);
            return try list.consSeqHeap(rt, r.slots[2], r.slots[1]);
        }
    }
}

/// PERF: realize one `(take n coll)` node in Zig (n a fixed-precision
/// integer; core.clj keeps the generic body for any other n) [refs: O-110]
fn takeStep(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const n = args[0].asInteger();
    if (n <= 0) return .nil_val;
    // GC-ROOT: [n, cursor, head], as mapStep.
    var r: Roots = .{ .slots = .{ args[0], args[1], .nil_val } };
    r.push();
    defer r.pop();
    const s = try seqable.seq(rt, env, args[1], loc);
    r.slots[1] = s;
    if (s.isNil()) return .nil_val;
    r.slots[2] = try seqable.first(rt, env, s, loc);
    r.slots[1] = try seqable.rest(rt, env, s, loc);
    r.slots[1] = try lazy_seq.allocNative(rt, takeStepV(), Value.initInteger(n - 1), r.slots[1]);
    return try list.consSeqHeap(rt, r.slots[2], r.slots[1]);
}

/// PERF: realize the head of `(iterate f x)`: `(x . <next of x>)`, no `f`
/// call, as clj's Iterate answers `first` without running `f` [refs: O-110]
fn iterateStep(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    // GC-ROOT: [f, x, tail], as mapStep.
    var r: Roots = .{ .slots = .{ args[0], args[1], .nil_val } };
    r.push();
    defer r.pop();
    r.slots[2] = try lazy_seq.allocNative(rt, iterateNextV(), args[0], args[1]);
    return try list.consSeqHeap(rt, args[1], r.slots[2]);
}

/// PERF: realize the element after `prev`: `y = (f prev)`, then
/// `(y . <next of y>)`. `f` runs once per element, when that element is
/// first reached, as in clj's Iterate.next [refs: O-110]
fn iterateNext(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    const f = args[0];
    // GC-ROOT: [f, y, tail], as mapStep.
    var r: Roots = .{ .slots = .{ f, .nil_val, .nil_val } };
    r.push();
    defer r.pop();
    r.slots[1] = try invokeCallable(rt, env, f, &.{args[1]}, loc);
    r.slots[2] = try lazy_seq.allocNative(rt, iterateNextV(), f, r.slots[1]);
    return try list.consSeqHeap(rt, r.slots[1], r.slots[2]);
}

fn iterateNextV() Value {
    return Value.initBuiltinFn(&iterateNext);
}

fn NodeFn(comptime name: []const u8, comptime stepV: fn () Value) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity(name, args, 2, loc);
            return try lazy_seq.allocNative(rt, stepV(), args[0], args[1]);
        }
    };
}

/// `(take n coll)` with a non-integer n stays in core.clj; reject it here so
/// a wrong caller fails loudly instead of truncating.
fn takeNode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("__take-lazy", args, 2, loc);
    _ = env;
    const n: Value = switch (args[0].tag()) {
        .integer => args[0],
        // A Long past the inline i48 range (`int?`, heap-boxed, D-165): no
        // seq is that long, so a positive one takes everything and a negative
        // one takes nothing, exactly as the count-down would.
        .big_int => if ((big_int.toI64(args[0]) catch 0) > 0) Value.initInteger(nb_i48_max) else Value.initInteger(0),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__take-lazy", .expected = "integer", .actual = @tagName(args[0].tag()) }),
    };
    return try lazy_seq.allocNative(rt, takeStepV(), n, args[1]);
}

pub fn register(env: *Env, ns: *env_mod.Namespace) !void {
    _ = try env.intern(ns, "__map-lazy", Value.initBuiltinFn(&NodeFn("__map-lazy", mapStepV).call), null);
    _ = try env.intern(ns, "__filter-lazy", Value.initBuiltinFn(&NodeFn("__filter-lazy", filterStepV).call), null);
    _ = try env.intern(ns, "__iterate-lazy", Value.initBuiltinFn(&NodeFn("__iterate-lazy", iterateStepV).call), null);
    _ = try env.intern(ns, "__take-lazy", Value.initBuiltinFn(&takeNode), null);
}
