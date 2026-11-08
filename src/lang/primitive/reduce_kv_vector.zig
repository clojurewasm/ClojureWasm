// SPDX-License-Identifier: EPL-2.0
//! Indexed reduce-kv on a persistent vector or subvec. The collection is
//! already keyed by its index, so no seq, pair allocation, or interpreted
//! loop/recur is needed. All user callbacks still use normal invocation.
//! `vector?` also admits a MapEntry and a deftype / reify declaring
//! IPersistentVector; those go to the caller's generic `fallback` fn.
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const vector = @import("../../runtime/collection/vector.zig");
const sub_vector = @import("../../runtime/collection/sub_vector.zig");
const reduced = @import("../../runtime/collection/reduced.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const invokeCallable = @import("higher_order.zig").invokeCallable;

pub fn run(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    // (__reduce-kv-vector f init coll fallback)
    try error_catalog.checkArity("__reduce-kv-vector", args, 4, loc);
    const f = args[0];
    const coll = args[2];
    switch (coll.tag()) {
        .vector, .sub_vector => {},
        else => return invokeCallable(rt, env, args[3], args[0..3], loc),
    }
    const sub = coll.tag() == .sub_vector;
    const n = if (sub) sub_vector.count(coll) else vector.count(coll);
    // GC-ROOT: callback can reenter eval/GC; retain the original collection,
    // reducing fn and latest accumulator across every user call.
    var roots: [3]Value = .{ f, args[1], coll };
    const sp: u16 = roots.len;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const item = if (sub) sub_vector.nth(coll, i) else vector.nth(coll, i);
        const r = try invokeCallable(rt, env, f, &.{ roots[1], Value.initInteger(@intCast(i)), item }, loc);
        if (reduced.isReduced(r)) return reduced.unreduce(r);
        roots[1] = r;
    }
    return roots[1];
}
