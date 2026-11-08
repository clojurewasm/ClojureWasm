// SPDX-License-Identifier: EPL-2.0
//! Layer 7 (Property) — the hash/eq law over `clojure.core/=`. ADR-0186 / ADR-0052.
//!
//! The load-bearing law a hashed collection depends on: two `=` values MUST
//! carry the same hash, so an `=` key finds its bucket. This file pins that
//! direction plus reflexivity and symmetry over a pool of values built from
//! GENERATED specs, deliberately minting the same value through DIFFERENT
//! representations (a fixnum and a heap BigInt of one integer; a vector and a
//! list of one element) so the equal-but-differently-built pairs — the ones the
//! law exists to constrain — actually occur.
//!
//! Two equality surfaces are pinned against `valueHash`: the user-facing
//! `valueEqual` (`=`) and the map/set key `keyEqValue`; both must imply equal
//! hash. Values are finite / NaN-free so `=` stays reflexive (clj's `=` is
//! non-reflexive only on NaN, a documented divergence not weakened here).

const std = @import("std");
const prop = @import("prop.zig");
const build_options = @import("build_options");

const Value = @import("../runtime/value/value.zig").Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const equal = @import("../runtime/equal.zig");
const big_int = @import("../runtime/numeric/big_int.zig");
const keyword_mod = @import("../runtime/keyword.zig");
const string_mod = @import("../runtime/collection/string.zig");
const vector = @import("../runtime/collection/vector.zig");
const list = @import("../runtime/collection/list.zig");
const date = @import("../runtime/time/date.zig");
const timestamp = @import("../runtime/time/timestamp.zig");
const instant_value = @import("../runtime/time/instant_value.zig");
const duration_value = @import("../runtime/time/duration_value.zig");
const local_date_value = @import("../runtime/time/local_date_value.zig");
const local_date_time_value = @import("../runtime/time/local_date_time_value.zig");
const local_time_value = @import("../runtime/time/local_time_value.zig");

const testing = std.testing;

/// Gate defaults, overridable for a sweep: `zig build test -Dprop-seed=0x… -Dprop-iters=…`.
fn config() prop.Config {
    return .{ .seed = build_options.prop_seed, .iters = build_options.prop_iters };
}

/// 17 kinds × 4 payloads = 68 distinct specs, drawn small so the pool collides
/// often (same value from one spec, and, across kinds 0/1 and 8/9, the same
/// value from two representations). Kinds 10..16 are the Date / java.time
/// typed_instance values: every spec allocates a FRESH instance, so a repeated
/// spec is an equal-but-distinct pair that an identity hash would split.
const kinds = 17;
const payloads = 4;
const kw_names = [payloads][]const u8{ "ka", "kb", "kc", "kd" };
const str_vals = [payloads][]const u8{ "sa", "sb", "sc", "sd" };

/// Map a generated i64 spec to a Value. Kinds 0/1 (fixnum / heap BigInt) and 8/9
/// (vector / list) are the two cross-representation pairs the law hinges on.
fn valueFromSpec(rt: *Runtime, spec: i64) !Value {
    const kind = @mod(spec, kinds);
    const p: i64 = @mod(@divFloor(spec, kinds), payloads);
    const pu: usize = @intCast(p);
    return switch (kind) {
        0 => Value.initInteger(p),
        1 => try big_int.allocFromI64(rt, p, .bigint),
        2 => Value.initFloat(@floatFromInt(p)),
        3 => try keyword_mod.intern(rt, null, kw_names[pu]),
        4 => try string_mod.alloc(rt, str_vals[pu]),
        5 => Value.initChar(@intCast(97 + p)),
        6 => Value.initBoolean(@mod(p, 2) == 0),
        7 => Value.nil_val,
        8 => vec: {
            const elems = [_]Value{Value.initInteger(p)};
            break :vec try vector.fromSlice(rt, &elems);
        },
        9 => lst: {
            break :lst try list.consHeap(rt, Value.initInteger(p), try list.emptyList(rt));
        },
        10 => try date.make(rt, p),
        11 => try timestamp.make(rt, p, @intCast(p * 1_000_000)),
        12 => try instant_value.make(rt, p * 1000, @intCast(p)),
        13 => try duration_value.make(rt, p, @intCast(p)),
        14 => try local_date_value.make(rt, p),
        15 => try local_date_time_value.make(rt, p, p),
        16 => try local_time_value.make(rt, p),
        else => unreachable,
    };
}

fn buildPool(rt: *Runtime, xs: []i64, out: *std.ArrayList(Value)) !void {
    for (xs) |spec| try out.append(testing.allocator, try valueFromSpec(rt, spec));
}

/// A fresh runtime + env per property evaluation. `Env.init` only mints the
/// namespace objects (no bootstrap load), so per-iteration cost is negligible.
const Fixture = struct {
    fn run(comptime body: fn (*Runtime, *Env, []i64) anyerror!void, xs: []i64) anyerror!void {
        var th = std.Io.Threaded.init(testing.allocator, .{});
        defer th.deinit();
        var rt = Runtime.init(th.io(), testing.allocator);
        defer rt.deinit();
        var env = try Env.init(&rt);
        defer env.deinit();
        try body(&rt, &env, xs);
    }
};

const gen = prop.IntSlice{ .distinct = kinds * payloads, .max_len = 48 };

// --- the laws ---

test "property: = implies equal hash (the load-bearing hash/eq law)" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, env: *Env, xs: []i64) anyerror!void {
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                for (pool.items) |b| {
                    if ((try equal.valueEqual(rt, env, a, b)) and
                        (equal.valueHash(a) != equal.valueHash(b)))
                        return error.EqualButHashDiffers;
                }
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: map/set key equality implies equal hash (HAMT bucketing)" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, _: *Env, xs: []i64) anyerror!void {
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                for (pool.items) |b| {
                    if (equal.keyEqValue(a, b) and (equal.valueHash(a) != equal.valueHash(b)))
                        return error.KeyEqualButHashDiffers;
                }
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: = is reflexive for every generated value" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, env: *Env, xs: []i64) anyerror!void {
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                if (!try equal.valueEqual(rt, env, a, a)) return error.NotReflexive;
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}

test "property: = is symmetric" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, env: *Env, xs: []i64) anyerror!void {
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                for (pool.items) |b| {
                    if ((try equal.valueEqual(rt, env, a, b)) != (try equal.valueEqual(rt, env, b, a)))
                        return error.NotSymmetric;
                }
            }
        }
    }.f;
    const wrapped = struct {
        fn f(_: Ctx, xs: []i64) anyerror!void {
            try Fixture.run(body, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, Ctx{}, wrapped);
}
