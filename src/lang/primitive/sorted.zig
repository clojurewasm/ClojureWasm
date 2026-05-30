// SPDX-License-Identifier: EPL-2.0
//! sorted-map / sorted-set / sorted? constructors (ADR-0057). The LLRB
//! tree + get/assoc/contains/count/seq/keys/vals live in
//! runtime/collection/sorted.zig; the existing collection chokepoints
//! (collection.zig / sequence.zig / lookup.zig / print.zig) route the
//! `.sorted_map` / `.sorted_set` tags there.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const sorted = @import("../../runtime/collection/sorted.zig");

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
    if (sc.tag() != .sorted_map and sc.tag() != .sorted_set)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "sorted collection", .actual = @tagName(sc.tag()) });
    const b: sorted.Bound = if (args.len == 3)
        .{ .test1 = args[1], .key1 = args[2] }
    else
        .{ .test1 = args[1], .key1 = args[2], .test2 = args[3], .key2 = args[4] };
    return sorted.subseqRange(rt, env, sc, ascending, b, loc);
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
