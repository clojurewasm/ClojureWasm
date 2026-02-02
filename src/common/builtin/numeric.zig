// Numeric utility functions — abs, max, min, quot, rand, rand-int.
//
// Runtime functions (kind = .runtime_fn) dispatched via BuiltinFn.
// Phase 6a additions to the standard library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;

// ============================================================
// Implementations
// ============================================================

/// (abs n) — returns the absolute value of n.
pub fn absFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .integer => |i| Value{ .integer = if (i < 0) -i else i },
        .float => |f| Value{ .float = @abs(f) },
        else => error.TypeError,
    };
}

/// (max x y & more) — returns the greatest of the nums.
pub fn maxFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    var best = args[0];
    for (args[1..]) |a| {
        if (try compareNum(a, best) > 0) {
            best = a;
        }
    }
    return best;
}

/// (min x y & more) — returns the least of the nums.
pub fn minFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    var best = args[0];
    for (args[1..]) |a| {
        if (try compareNum(a, best) < 0) {
            best = a;
        }
    }
    return best;
}

/// (quot num div) — returns the quotient of dividing num by div (truncated).
pub fn quotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .integer => |a| switch (args[1]) {
            .integer => |b| blk: {
                if (b == 0) return error.ArithmeticError;
                break :blk Value{ .integer = @divTrunc(a, b) };
            },
            .float => |b| blk: {
                if (b == 0.0) return error.ArithmeticError;
                const fa: f64 = @floatFromInt(a);
                break :blk Value{ .float = @trunc(fa / b) };
            },
            else => error.TypeError,
        },
        .float => |a| switch (args[1]) {
            .integer => |b| blk: {
                if (b == 0) return error.ArithmeticError;
                const fb: f64 = @floatFromInt(b);
                break :blk Value{ .float = @trunc(a / fb) };
            },
            .float => |b| blk: {
                if (b == 0.0) return error.ArithmeticError;
                break :blk Value{ .float = @trunc(a / b) };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

// PRNG state for rand/rand-int (module-level, deterministic seed for testing)
var prng = std.Random.DefaultPrng.init(0);

/// Set PRNG seed (for testing reproducibility).
pub fn setSeed(seed: u64) void {
    prng = std.Random.DefaultPrng.init(seed);
}

/// (rand) — returns a random float between 0 (inclusive) and 1 (exclusive).
pub fn randFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const f = prng.random().float(f64);
    return Value{ .float = f };
}

/// (rand-int n) — returns a random integer between 0 (inclusive) and n (exclusive).
pub fn randIntFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeError,
    };
    if (n <= 0) return error.ArithmeticError;
    const un: u64 = @intCast(n);
    const result = prng.random().intRangeLessThan(u64, 0, un);
    return Value{ .integer = @intCast(result) };
}

fn compareNum(a: Value, b: Value) !i2 {
    const fa = switch (a) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => return error.TypeError,
    };
    const fb = switch (b) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => return error.TypeError,
    };
    if (fa < fb) return -1;
    if (fa > fb) return 1;
    return 0;
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "abs",
        .kind = .runtime_fn,
        .func = &absFn,
        .doc = "Returns the absolute value of a.",
        .arglists = "([a])",
        .added = "1.0",
    },
    .{
        .name = "max",
        .kind = .runtime_fn,
        .func = &maxFn,
        .doc = "Returns the greatest of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "min",
        .kind = .runtime_fn,
        .func = &minFn,
        .doc = "Returns the least of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "quot",
        .kind = .runtime_fn,
        .func = &quotFn,
        .doc = "quot[ient] of dividing numerator by denominator.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "rand",
        .kind = .runtime_fn,
        .func = &randFn,
        .doc = "Returns a random floating point number between 0 (inclusive) and 1 (exclusive).",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "rand-int",
        .kind = .runtime_fn,
        .func = &randIntFn,
        .doc = "Returns a random integer between 0 (inclusive) and n (exclusive).",
        .arglists = "([n])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "abs on positive integer" {
    try testing.expectEqual(Value{ .integer = 5 }, try absFn(test_alloc, &.{Value{ .integer = 5 }}));
}

test "abs on negative integer" {
    try testing.expectEqual(Value{ .integer = 5 }, try absFn(test_alloc, &.{Value{ .integer = -5 }}));
}

test "abs on float" {
    try testing.expectEqual(Value{ .float = 3.14 }, try absFn(test_alloc, &.{Value{ .float = -3.14 }}));
}

test "max with two integers" {
    try testing.expectEqual(Value{ .integer = 10 }, try maxFn(test_alloc, &.{ Value{ .integer = 3 }, Value{ .integer = 10 } }));
}

test "max with three values" {
    try testing.expectEqual(Value{ .integer = 10 }, try maxFn(test_alloc, &.{
        Value{ .integer = 3 },
        Value{ .integer = 10 },
        Value{ .integer = 7 },
    }));
}

test "max single arg" {
    try testing.expectEqual(Value{ .integer = 42 }, try maxFn(test_alloc, &.{Value{ .integer = 42 }}));
}

test "min with two integers" {
    try testing.expectEqual(Value{ .integer = 3 }, try minFn(test_alloc, &.{ Value{ .integer = 3 }, Value{ .integer = 10 } }));
}

test "min with mixed types" {
    try testing.expectEqual(Value{ .integer = 1 }, try minFn(test_alloc, &.{
        Value{ .float = 2.5 },
        Value{ .integer = 1 },
    }));
}

test "quot integer division" {
    try testing.expectEqual(Value{ .integer = 3 }, try quotFn(test_alloc, &.{ Value{ .integer = 10 }, Value{ .integer = 3 } }));
}

test "quot negative truncates toward zero" {
    try testing.expectEqual(Value{ .integer = -3 }, try quotFn(test_alloc, &.{ Value{ .integer = -10 }, Value{ .integer = 3 } }));
}

test "quot division by zero" {
    try testing.expectError(error.ArithmeticError, quotFn(test_alloc, &.{ Value{ .integer = 10 }, Value{ .integer = 0 } }));
}

test "rand returns float in [0, 1)" {
    setSeed(12345);
    const result = try randFn(test_alloc, &.{});
    try testing.expect(result == .float);
    try testing.expect(result.float >= 0.0 and result.float < 1.0);
}

test "rand-int returns integer in [0, n)" {
    setSeed(12345);
    const result = try randIntFn(test_alloc, &.{Value{ .integer = 100 }});
    try testing.expect(result == .integer);
    try testing.expect(result.integer >= 0 and result.integer < 100);
}

test "rand-int with non-positive n is error" {
    try testing.expectError(error.ArithmeticError, randIntFn(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectError(error.ArithmeticError, randIntFn(test_alloc, &.{Value{ .integer = -5 }}));
}
