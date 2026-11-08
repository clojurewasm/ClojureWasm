// SPDX-License-Identifier: EPL-2.0
//! The body of one lazy step of multi-collection `map` (ADR-0205).
//!
//! clj's 2- and 3-coll `map` is deliberately UNCHUNKED: each lazy step seqs
//! every source, calls `f` once on the heads and conses the result onto a lazy
//! tail `(map f (rest s1) (rest s2))`. cljw keeps that shape exactly (one `f`
//! call per realized node, the same order: seq all, f on the firsts, then the
//! rests), but runs the body in Zig instead of interpreting a let / and / seq /
//! first / rest / cons tree per element. The lazy node and the recursion stay
//! in core.clj (`-map-n-lazy`), which passes itself as `self`, so laziness,
//! realization counts and exceptions are unchanged.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: seqable (Layer 0), list.consHeap, higher_order.invokeCallable
//! Clojure peer: -map-n-lazy (core.clj)

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;
const seqable = @import("../../runtime/seqable.zig");
const list = @import("../../runtime/collection/list.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const invokeCallable = @import("higher_order.zig").invokeCallable;

const MAX_COLLS = 3;

/// `(cljw.internal/__map-step f self c1 c2 [c3])`: nil when any source is
/// empty, else `(cons (f (first s1) ..) (self f (rest s1) ..))`.
/// PERF: the per-element step of multi-coll map in Zig instead of an interpreted body [refs: O-062]
fn mapStepFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 4 or args.len > 2 + MAX_COLLS) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "__map-step", .expected = 4, .got = args.len });
    }
    const n = args.len - 2;
    // GC-ROOT: A2 reentrant-primitive frame (ADR-0094): slots [s1..sn x1..xn v]
    // keep every seq cursor, head, rest and the mapped value alive across the
    // user `f`, the lazy forces inside seq/first/rest and the `self` call; the
    // args (f, self, colls) ride as constants [ref: .dev/gc_rooting.md].
    var roots: [2 * MAX_COLLS + 1]Value = @splat(Value.nil_val);
    var sp: u16 = roots.len;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .constants = args, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;

    const ss = roots[0..n];
    const xs = roots[MAX_COLLS .. MAX_COLLS + n];
    const v_slot = &roots[2 * MAX_COLLS];
    for (args[2..], 0..) |c, i| {
        ss[i] = try seqable.seq(rt, env, c, loc);
        if (ss[i].isNil()) return .nil_val;
    }
    for (ss, 0..) |s, i| xs[i] = try seqable.first(rt, env, s, loc);
    v_slot.* = try invokeCallable(rt, env, args[0], xs, loc);

    // `(self f (rest s1) ..)`: the rests replace the heads in place (the heads
    // are dead once f has run).
    for (ss, 0..) |s, i| xs[i] = try seqable.rest(rt, env, s, loc);
    var call: [1 + MAX_COLLS]Value = undefined;
    call[0] = args[0];
    for (xs, 0..) |r, i| call[1 + i] = r;
    ss[0] = try invokeCallable(rt, env, args[1], call[0 .. 1 + n], loc); // the lazy tail, rooted
    return try list.consHeap(rt, v_slot.*, ss[0]);
}

pub fn register(env: *Env, ns: *env_mod.Namespace) !void {
    _ = try env.intern(ns, "__map-step", Value.initBuiltinFn(&mapStepFn), null);
}
