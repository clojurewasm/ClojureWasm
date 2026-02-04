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
// Bitwise operations
// ============================================================

fn requireInt(v: Value) !i64 {
    return switch (v) {
        .integer => |i| i,
        else => error.TypeError,
    };
}

/// (bit-and x y) — bitwise AND
pub fn bitAndFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a & b };
}

/// (bit-or x y) — bitwise OR
pub fn bitOrFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a | b };
}

/// (bit-xor x y) — bitwise XOR
pub fn bitXorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a ^ b };
}

/// (bit-not x) — bitwise complement
pub fn bitNotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const a = try requireInt(args[0]);
    return Value{ .integer = ~a };
}

/// (bit-shift-left x n) — left shift
pub fn bitShiftLeftFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .integer = x << shift };
}

/// (bit-shift-right x n) — arithmetic right shift
pub fn bitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .integer = x >> shift };
}

/// (unsigned-bit-shift-right x n) — logical (unsigned) right shift
pub fn unsignedBitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    const ux: u64 = @bitCast(x);
    return Value{ .integer = @bitCast(ux >> shift) };
}

/// (bit-set x n) — set bit n
pub fn bitSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .integer = x | (@as(i64, 1) << shift) };
}

/// (bit-clear x n) — clear bit n
pub fn bitClearFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .integer = x & ~(@as(i64, 1) << shift) };
}

/// (bit-flip x n) — flip bit n
pub fn bitFlipFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .integer = x ^ (@as(i64, 1) << shift) };
}

/// (bit-test x n) — test bit n, returns boolean
pub fn bitTestFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return error.ArithmeticError;
    const shift: u6 = @intCast(n);
    return Value{ .boolean = (x & (@as(i64, 1) << shift)) != 0 };
}

// ============================================================
// Numeric coercion functions
// ============================================================

/// (int x) — Coerce to integer (truncate float).
fn intCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .integer => args[0],
        .float => |f| Value{ .integer = @intFromFloat(f) },
        else => error.TypeError,
    };
}

/// (float x) — Coerce to float.
fn floatCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => args[0],
        .integer => |i| Value{ .float = @floatFromInt(i) },
        else => error.TypeError,
    };
}

/// (num x) — Coerce to Number (identity for numbers).
fn numFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .integer, .float => args[0],
        else => error.TypeError,
    };
}

/// (char x) — Coerce int to character string.
fn charFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const code: u21 = switch (args[0]) {
        .integer => |i| if (i >= 0 and i <= 0x10FFFF)
            @intCast(i)
        else
            return error.ArithmeticError,
        .string => |s| blk: {
            if (s.len == 0) return error.ArithmeticError;
            const view = std.unicode.Utf8View.initUnchecked(s);
            var it = view.iterator();
            break :blk it.nextCodepoint() orelse return error.ArithmeticError;
        },
        else => return error.TypeError,
    };
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &buf) catch return error.ArithmeticError;
    const str = allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    return Value{ .string = str };
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "abs",
        .func = &absFn,
        .doc = "Returns the absolute value of a.",
        .arglists = "([a])",
        .added = "1.0",
    },
    .{
        .name = "max",
        .func = &maxFn,
        .doc = "Returns the greatest of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "min",
        .func = &minFn,
        .doc = "Returns the least of the nums.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "quot",
        .func = &quotFn,
        .doc = "quot[ient] of dividing numerator by denominator.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "rand",
        .func = &randFn,
        .doc = "Returns a random floating point number between 0 (inclusive) and 1 (exclusive).",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "rand-int",
        .func = &randIntFn,
        .doc = "Returns a random integer between 0 (inclusive) and n (exclusive).",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "bit-and",
        .func = &bitAndFn,
        .doc = "Bitwise and.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-or",
        .func = &bitOrFn,
        .doc = "Bitwise or.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-xor",
        .func = &bitXorFn,
        .doc = "Bitwise exclusive or.",
        .arglists = "([x y])",
        .added = "1.0",
    },
    .{
        .name = "bit-not",
        .func = &bitNotFn,
        .doc = "Bitwise complement.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "bit-shift-left",
        .func = &bitShiftLeftFn,
        .doc = "Bitwise shift left.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-shift-right",
        .func = &bitShiftRightFn,
        .doc = "Bitwise shift right.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "unsigned-bit-shift-right",
        .func = &unsignedBitShiftRightFn,
        .doc = "Bitwise shift right, without sign-extension.",
        .arglists = "([x n])",
        .added = "1.6",
    },
    .{
        .name = "bit-set",
        .func = &bitSetFn,
        .doc = "Set bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-clear",
        .func = &bitClearFn,
        .doc = "Clear bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-flip",
        .func = &bitFlipFn,
        .doc = "Flip bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "bit-test",
        .func = &bitTestFn,
        .doc = "Test bit at index n.",
        .arglists = "([x n])",
        .added = "1.0",
    },
    .{
        .name = "int",
        .func = &intCoerceFn,
        .doc = "Coerce to int",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "long",
        .func = &intCoerceFn,
        .doc = "Coerce to long",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "short",
        .func = &intCoerceFn,
        .doc = "Coerce to short",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "byte",
        .func = &intCoerceFn,
        .doc = "Coerce to byte",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "float",
        .func = &floatCoerceFn,
        .doc = "Coerce to float",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "double",
        .func = &floatCoerceFn,
        .doc = "Coerce to double",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "num",
        .func = &numFn,
        .doc = "Coerce to Number",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "char",
        .func = &charFn,
        .doc = "Coerce to char",
        .arglists = "([x])",
        .added = "1.1",
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

test "bit-and" {
    try testing.expectEqual(Value{ .integer = 0b1000 }, try bitAndFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 0b1100 } }));
}

test "bit-or" {
    try testing.expectEqual(Value{ .integer = 0b1110 }, try bitOrFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 0b1100 } }));
}

test "bit-xor" {
    try testing.expectEqual(Value{ .integer = 0b0110 }, try bitXorFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 0b1100 } }));
}

test "bit-not" {
    const result = try bitNotFn(test_alloc, &.{Value{ .integer = 0 }});
    try testing.expectEqual(Value{ .integer = -1 }, result);
}

test "bit-shift-left" {
    try testing.expectEqual(Value{ .integer = 8 }, try bitShiftLeftFn(test_alloc, &.{ Value{ .integer = 1 }, Value{ .integer = 3 } }));
}

test "bit-shift-right" {
    try testing.expectEqual(Value{ .integer = 2 }, try bitShiftRightFn(test_alloc, &.{ Value{ .integer = 8 }, Value{ .integer = 2 } }));
}

test "unsigned-bit-shift-right" {
    // -1 is all 1s, unsigned shift fills with 0s
    const result = try unsignedBitShiftRightFn(test_alloc, &.{ Value{ .integer = -1 }, Value{ .integer = 1 } });
    try testing.expectEqual(Value{ .integer = std.math.maxInt(i64) }, result);
}

test "bit-set" {
    try testing.expectEqual(Value{ .integer = 0b1010 }, try bitSetFn(test_alloc, &.{ Value{ .integer = 0b1000 }, Value{ .integer = 1 } }));
}

test "bit-clear" {
    try testing.expectEqual(Value{ .integer = 0b1000 }, try bitClearFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 1 } }));
}

test "bit-flip" {
    try testing.expectEqual(Value{ .integer = 0b1110 }, try bitFlipFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 2 } }));
}

test "bit-test" {
    try testing.expectEqual(Value{ .boolean = true }, try bitTestFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 1 } }));
    try testing.expectEqual(Value{ .boolean = false }, try bitTestFn(test_alloc, &.{ Value{ .integer = 0b1010 }, Value{ .integer = 2 } }));
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
