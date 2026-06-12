// SPDX-License-Identifier: EPL-2.0
//! sorted-map / sorted-set / sorted? constructors (ADR-0057). The LLRB
//! tree + get/assoc/contains/count/seq/keys/vals live in
//! runtime/collection/sorted.zig; the existing collection chokepoints
//! (collection.zig / sequence.zig / lookup.zig / print.zig) route the
//! `.sorted_map` / `.sorted_set` tags there.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const sorted = @import("../../runtime/collection/sorted.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const list_mod = @import("../../runtime/collection/list.zig");
const root_set = @import("../../runtime/gc/root_set.zig");

/// `(sorted-map & kvs)` — build a sorted map (default `compare` order).
pub fn sortedMapFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len % 2 != 0)
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    return buildMap(rt, env, Value.nil_val, args, loc);
}

/// `(sorted-map-by comparator & kvs)` — sorted map ordered by `comparator`.
pub fn sortedMapByFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0) return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "sorted-map-by", .expected = 1, .got = 0 });
    if ((args.len - 1) % 2 != 0)
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    return buildMap(rt, env, args[0], args[1..], loc);
}

fn buildMap(rt: *Runtime, env: *Env, comparator: Value, kvs: []const Value, loc: SourceLocation) anyerror!Value {
    var m = try sorted.emptyMapBy(rt, comparator);
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) {
        m = try sorted.assoc(rt, env, m, kvs[i], kvs[i + 1], loc);
    }
    return m;
}

/// `(sorted-set & xs)` — build a sorted set (default `compare` order).
pub fn sortedSetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return buildSet(rt, env, Value.nil_val, args, loc);
}

/// `(sorted-set-by comparator & xs)` — sorted set ordered by `comparator`.
pub fn sortedSetByFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 0) return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "sorted-set-by", .expected = 1, .got = 0 });
    return buildSet(rt, env, args[0], args[1..], loc);
}

fn buildSet(rt: *Runtime, env: *Env, comparator: Value, xs: []const Value, loc: SourceLocation) anyerror!Value {
    var s = try sorted.emptySetBy(rt, comparator);
    for (xs) |x| {
        s = try sorted.conjSet(rt, env, s, x, loc);
    }
    return s;
}

/// `(subseq sc test key)` / `(subseq sc s-test s-key e-test e-key)` —
/// ascending sub-sequence of entries whose key satisfies the bound(s).
pub fn subseqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return subseqImpl(rt, env, args, true, "subseq", loc);
}

/// `(rsubseq sc …)` — same as subseq but descending.
pub fn rsubseqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return subseqImpl(rt, env, args, false, "rsubseq", loc);
}

fn subseqImpl(rt: *Runtime, env: *Env, args: []const Value, ascending: bool, name: []const u8, loc: SourceLocation) anyerror!Value {
    if (args.len != 3 and args.len != 5)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = name, .got = args.len, .min = 3, .max = 5 });
    const sc = args[0];
    // A deftype/reify declaring clojure.lang.Sorted (data.priority-map) is
    // driven through the Sorted protocol_remap methods, exactly as clj's
    // core.clj subseq/rsubseq drive any Sorted via .comparator/.entryKey/
    // .seqFrom/.seq(asc).
    if (sc.tag() == .typed_instance or sc.tag() == .reified_instance)
        return subseqSorted(rt, env, args, ascending, loc);
    if (sc.tag() != .sorted_map and sc.tag() != .sorted_set)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "sorted collection", .actual = @tagName(sc.tag()) });
    const b: sorted.Bound = if (args.len == 3)
        .{ .test1 = args[1], .key1 = args[2] }
    else
        .{ .test1 = args[1], .key1 = args[2], .test2 = args[3], .key2 = args[4] };
    return sorted.subseqRange(rt, env, sc, ascending, b, loc);
}

/// True iff `test_fn` IS the `clojure.core/<name>` fn (bit identity, the cljw
/// form of clj's `(#{> >=} test)` set-membership on the fn value).
fn isCoreTest(env: *Env, test_fn: Value, fn_name: []const u8) bool {
    const core_ns = env.findNs("clojure.core") orelse return false;
    const v = core_ns.resolve(fn_name) orelse return false;
    return @intFromEnum(v.deref()) == @intFromEnum(test_fn);
}

/// clj core.clj's `mk-bound-fn` as a struct: include(e) =
/// `(test (comparator (entryKey sc e) key) 0)`.
const BoundFn = struct {
    rt: *Runtime,
    env: *Env,
    sc: Value,
    comparator_fn: Value,
    test_fn: Value,
    key: Value,
    loc: SourceLocation,

    fn includes(self: *const BoundFn, e: Value) anyerror!bool {
        var cs: dispatch.CallSite = .{};
        const ek = try dispatch.dispatch(self.rt, self.env, &cs, self.sc, "Sorted", "-entry-key", &.{ self.sc, e }, self.loc);
        const vt = self.rt.vtable orelse return error.NotImplemented;
        const cmp = try vt.callFn(self.rt, self.env, self.comparator_fn, &.{ ek, self.key }, self.loc);
        const r = try vt.callFn(self.rt, self.env, self.test_fn, &.{ cmp, Value.initInteger(0) }, self.loc);
        return r.isTruthy();
    }
};

/// `(seqFrom sc key ascending)` / `(seq sc ascending)` via the Sorted remap.
fn sortedSeqFrom(rt: *Runtime, env: *Env, sc: Value, key: Value, ascending: bool, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    return dispatch.dispatch(rt, env, &cs, sc, "Sorted", "-sorted-seq-from", &.{ sc, key, Value.initBoolean(ascending) }, loc);
}

fn sortedSeqAsc(rt: *Runtime, env: *Env, sc: Value, ascending: bool, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    return dispatch.dispatch(rt, env, &cs, sc, "Sorted", "-sorted-seq", &.{ sc, Value.initBoolean(ascending) }, loc);
}

/// Eager `(take-while include coll)` — the result is bounded by the sorted
/// collection, so eagerness is safe. Rooted per the realizeSeqWalk pattern
/// (GC-ROOT: the cursor + accumulated items live in Zig locals across
/// VM-re-entrant seq/first/rest + include calls [ref: .dev/gc_rooting.md §C]).
fn takeWhileBound(rt: *Runtime, env: *Env, bound: *const BoundFn, coll: Value) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur_root: [1]Value = .{coll};
    var cur_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &cur_root, .sp = &cur_sp, .locals = items.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var cur = coll;
    while (true) {
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        const s = try lazy_seq.seq(rt, env, cur);
        if (s.tag() == .nil) break;
        cur_root[0] = s;
        const e = try lazy_seq.first(rt, env, s);
        if (!try bound.includes(e)) break;
        try items.append(rt.gpa, e);
        gc_frame.locals = items.items;
        cur = try lazy_seq.rest(rt, env, s);
    }
    var out = try list_mod.emptyList(rt);
    var i = items.items.len;
    while (i > 0) {
        i -= 1;
        out = try list_mod.consHeap(rt, items.items[i], out);
    }
    return out;
}

/// `(next s)` over a possibly-lazy seq: nil when fewer than 2 elements.
fn seqNext(rt: *Runtime, env: *Env, s: Value) anyerror!Value {
    const r = try lazy_seq.rest(rt, env, s);
    const n = try lazy_seq.seq(rt, env, r);
    return if (n.tag() == .nil) Value.nil_val else n;
}

/// subseq/rsubseq over a clojure.lang.Sorted deftype — the cljw form of
/// clj core.clj's subseq/rsubseq bodies (bound algebra preserved verbatim).
fn subseqSorted(rt: *Runtime, env: *Env, args: []const Value, ascending: bool, loc: SourceLocation) anyerror!Value {
    const sc = args[0];
    var cs: dispatch.CallSite = .{};
    const comparator_fn = try dispatch.dispatch(rt, env, &cs, sc, "Sorted", "-sorted-comparator", &.{sc}, loc);

    if (args.len == 3) {
        const bound: BoundFn = .{ .rt = rt, .env = env, .sc = sc, .comparator_fn = comparator_fn, .test_fn = args[1], .key = args[2], .loc = loc };
        // subseq: > / >= start FROM the key ascending; rsubseq: < / <= start
        // FROM the key descending. The other tests scan the full seq.
        const from_key = if (ascending)
            (isCoreTest(env, args[1], ">") or isCoreTest(env, args[1], ">="))
        else
            (isCoreTest(env, args[1], "<") or isCoreTest(env, args[1], "<="));
        if (from_key) {
            const s = try lazy_seq.seq(rt, env, try sortedSeqFrom(rt, env, sc, args[2], ascending, loc));
            if (s.tag() == .nil) return .nil_val;
            const e = try lazy_seq.first(rt, env, s);
            return if (try bound.includes(e)) s else try seqNext(rt, env, s);
        }
        return takeWhileBound(rt, env, &bound, try sortedSeqAsc(rt, env, sc, ascending, loc));
    }

    // 5-arity: seqFrom the near bound, drop a non-matching head, take-while
    // the far bound (clj's exact shape for both directions).
    const near_test = if (ascending) args[1] else args[3];
    const near_key = if (ascending) args[2] else args[4];
    const far_test = if (ascending) args[3] else args[1];
    const far_key = if (ascending) args[4] else args[2];
    const near: BoundFn = .{ .rt = rt, .env = env, .sc = sc, .comparator_fn = comparator_fn, .test_fn = near_test, .key = near_key, .loc = loc };
    const far: BoundFn = .{ .rt = rt, .env = env, .sc = sc, .comparator_fn = comparator_fn, .test_fn = far_test, .key = far_key, .loc = loc };
    const s = try lazy_seq.seq(rt, env, try sortedSeqFrom(rt, env, sc, near_key, ascending, loc));
    if (s.tag() == .nil) return .nil_val;
    const e = try lazy_seq.first(rt, env, s);
    const start = if (try near.includes(e)) s else try seqNext(rt, env, s);
    if (start.tag() == .nil) return .nil_val;
    return takeWhileBound(rt, env, &far, start);
}

/// `(sorted? coll)` — true for sorted maps/sets.
pub fn sortedQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("sorted?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .sorted_map or t == .sorted_set) Value.true_val else Value.false_val;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "sorted-map", .f = &sortedMapFn },
    .{ .name = "sorted-map-by", .f = &sortedMapByFn },
    .{ .name = "sorted-set", .f = &sortedSetFn },
    .{ .name = "sorted-set-by", .f = &sortedSetByFn },
    .{ .name = "sorted?", .f = &sortedQFn },
    .{ .name = "subseq", .f = &subseqFn },
    .{ .name = "rsubseq", .f = &rsubseqFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
