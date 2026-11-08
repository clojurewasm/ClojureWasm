// SPDX-License-Identifier: EPL-2.0
//! Layer 7 (Property) — valueCompare is a NaN-safe total order. ADR-0186.
//!
//! Pins the SORT-NAN defect class: the native ordering path
//! (runtime/compare.zig valueCompare, reached by sort / sort-by / sorted-set /
//! sorted-map) must be a total order over the numeric tower, returning .eq for
//! any NaN operand (the clojure.core/compare rule) rather than hitting
//! std.math.order's `unreachable`. The compare PRIMITIVE
//! (lang/primitive/math.zig) is separately pinned by
//! test/diff/clj_corpus/compare_cross_numeric.txt, so both implementations are
//! locked and cannot silently diverge. Laws checked: reflexivity, antisymmetry,
//! and NaN -> .eq, over a pool of ints (+/-), floats, BigInts, and the
//! non-finite floats NaN / +Inf / -Inf.

const std = @import("std");
const prop = @import("prop.zig");
const build_options = @import("build_options");

const Value = @import("../runtime/value/value.zig").Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const compare = @import("../runtime/compare.zig");
const big_int = @import("../runtime/numeric/big_int.zig");
const SourceLocation = @import("../runtime/error/info.zig").SourceLocation;

const testing = std.testing;

/// Gate defaults, overridable for a sweep: `zig build test -Dprop-seed=0x.. -Dprop-iters=..`.
fn config() prop.Config {
    return .{ .seed = build_options.prop_seed, .iters = build_options.prop_iters };
}

const kinds = 7;
const payloads = 4;

/// Map a generated i64 spec to a numeric Value. Kinds 4/5/6 are the non-finite
/// floats (NaN / +Inf / -Inf) whose ordering the SORT-NAN fix made total.
fn valueFromSpec(rt: *Runtime, spec: i64) !Value {
    const kind = @mod(spec, kinds);
    const p: i64 = @mod(@divFloor(spec, kinds), payloads);
    return switch (kind) {
        0 => Value.initInteger(p),
        1 => Value.initInteger(-p),
        2 => Value.initFloat(@floatFromInt(p)),
        3 => try big_int.allocFromI64(rt, p, .bigint),
        4 => Value.initFloat(std.math.nan(f64)),
        5 => Value.initFloat(std.math.inf(f64)),
        6 => Value.initFloat(-std.math.inf(f64)),
        else => unreachable,
    };
}

fn buildPool(rt: *Runtime, xs: []i64, out: *std.ArrayList(Value)) !void {
    for (xs) |spec| try out.append(testing.allocator, try valueFromSpec(rt, spec));
}

fn sign(o: std.math.Order) i8 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// A fresh runtime per property evaluation (valueCompare needs no Env).
const Fixture = struct {
    fn run(comptime body: fn (*Runtime, []i64) anyerror!void, xs: []i64) anyerror!void {
        var th = std.Io.Threaded.init(testing.allocator, .{});
        defer th.deinit();
        var rt = Runtime.init(th.io(), testing.allocator);
        defer rt.deinit();
        try body(&rt, xs);
    }
};

const gen = prop.IntSlice{ .distinct = kinds * payloads, .max_len = 40 };

// --- the laws ---

test "property: valueCompare is reflexive over the numeric tower" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            const loc = SourceLocation{};
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                if (sign(try compare.valueCompare(rt, a, a, loc)) != 0) return error.NotReflexive;
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

test "property: valueCompare is antisymmetric (sign(a,b) == -sign(b,a))" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            const loc = SourceLocation{};
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                for (pool.items) |b| {
                    const ab = sign(try compare.valueCompare(rt, a, b, loc));
                    const ba = sign(try compare.valueCompare(rt, b, a, loc));
                    if (ab != -ba) return error.NotAntisymmetric;
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

test "property: valueCompare returns .eq for any NaN operand (no unreachable)" {
    const Ctx = struct {};
    const body = struct {
        fn f(rt: *Runtime, xs: []i64) anyerror!void {
            const loc = SourceLocation{};
            const nan = Value.initFloat(std.math.nan(f64));
            var pool: std.ArrayList(Value) = .empty;
            defer pool.deinit(testing.allocator);
            try buildPool(rt, xs, &pool);
            for (pool.items) |a| {
                if (sign(try compare.valueCompare(rt, nan, a, loc)) != 0) return error.NanNotEq;
                if (sign(try compare.valueCompare(rt, a, nan, loc)) != 0) return error.NanNotEq;
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
