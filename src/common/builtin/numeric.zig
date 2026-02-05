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
const err = @import("../error.zig");

// ============================================================
// Implementations
// ============================================================

/// (abs n) — returns the absolute value of n.
pub fn absFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to abs", .{args.len});
    return switch (args[0]) {
        .integer => |i| Value{ .integer = if (i < 0) -i else i },
        .float => |f| Value{ .float = @abs(f) },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0])}),
    };
}

/// (max x y & more) — returns the greatest of the nums.
pub fn maxFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to max", .{args.len});
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
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to min", .{args.len});
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
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to quot", .{args.len});
    return switch (args[0]) {
        .integer => |a| switch (args[1]) {
            .integer => |b| blk: {
                if (b == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                break :blk Value{ .integer = @divTrunc(a, b) };
            },
            .float => |b| blk: {
                if (b == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                const fa: f64 = @floatFromInt(a);
                break :blk Value{ .float = @trunc(fa / b) };
            },
            else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[1])}),
        },
        .float => |a| switch (args[1]) {
            .integer => |b| blk: {
                if (b == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                const fb: f64 = @floatFromInt(b);
                break :blk Value{ .float = @trunc(a / fb) };
            },
            .float => |b| blk: {
                if (b == 0.0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Divide by zero", .{});
                break :blk Value{ .float = @trunc(a / b) };
            },
            else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[1])}),
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0])}),
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
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rand", .{args.len});
    const f = prng.random().float(f64);
    return Value{ .float = f };
}

/// (rand-int n) — returns a random integer between 0 (inclusive) and n (exclusive).
pub fn randIntFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rand-int", .{args.len});
    const n = switch (args[0]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(args[0])}),
    };
    if (n <= 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "rand-int argument must be positive, got {d}", .{n});
    const un: u64 = @intCast(n);
    const result = prng.random().intRangeLessThan(u64, 0, un);
    return Value{ .integer = @intCast(result) };
}

fn compareNum(a: Value, b: Value) !i2 {
    const fa = switch (a) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(a)}),
    };
    const fb = switch (b) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(b)}),
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
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(v)}),
    };
}

/// (bit-and x y) — bitwise AND
pub fn bitAndFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-and", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a & b };
}

/// (bit-or x y) — bitwise OR
pub fn bitOrFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-or", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a | b };
}

/// (bit-xor x y) — bitwise XOR
pub fn bitXorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-xor", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a ^ b };
}

/// (bit-and-not x y) — bitwise AND with complement of y
pub fn bitAndNotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-and-not", .{args.len});
    const a = try requireInt(args[0]);
    const b = try requireInt(args[1]);
    return Value{ .integer = a & ~b };
}

/// (bit-not x) — bitwise complement
pub fn bitNotFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-not", .{args.len});
    const a = try requireInt(args[0]);
    return Value{ .integer = ~a };
}

/// (bit-shift-left x n) — left shift
pub fn bitShiftLeftFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-shift-left", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    return Value{ .integer = x << shift };
}

/// (bit-shift-right x n) — arithmetic right shift
pub fn bitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-shift-right", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    return Value{ .integer = x >> shift };
}

/// (unsigned-bit-shift-right x n) — logical (unsigned) right shift
pub fn unsignedBitShiftRightFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to unsigned-bit-shift-right", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    // JVM semantics: truncate shift amount to low 6 bits (n & 63)
    const shift: u6 = @truncate(@as(u64, @bitCast(n)));
    const ux: u64 = @bitCast(x);
    return Value{ .integer = @bitCast(ux >> shift) };
}

/// (bit-set x n) — set bit n
pub fn bitSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-set", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value{ .integer = x | (@as(i64, 1) << shift) };
}

/// (bit-clear x n) — clear bit n
pub fn bitClearFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-clear", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value{ .integer = x & ~(@as(i64, 1) << shift) };
}

/// (bit-flip x n) — flip bit n
pub fn bitFlipFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-flip", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value{ .integer = x ^ (@as(i64, 1) << shift) };
}

/// (bit-test x n) — test bit n, returns boolean
pub fn bitTestFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bit-test", .{args.len});
    const x = try requireInt(args[0]);
    const n = try requireInt(args[1]);
    if (n < 0 or n > 63) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Bit index {d} out of range [0, 63]", .{n});
    const shift: u6 = @intCast(n);
    return Value{ .boolean = (x & (@as(i64, 1) << shift)) != 0 };
}

// ============================================================
// Numeric coercion functions
// ============================================================

/// (int x) — Coerce to integer (truncate float).
fn intCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to int", .{args.len});
    return switch (args[0]) {
        .integer => args[0],
        .float => |f| Value{ .integer = @intFromFloat(f) },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to integer", .{@tagName(args[0])}),
    };
}

/// (float x) — Coerce to float.
fn floatCoerceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to float", .{args.len});
    return switch (args[0]) {
        .float => args[0],
        .integer => |i| Value{ .float = @floatFromInt(i) },
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to float", .{@tagName(args[0])}),
    };
}

/// (num x) — Coerce to Number (identity for numbers).
fn numFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to num", .{args.len});
    return switch (args[0]) {
        .integer, .float => args[0],
        else => err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to number", .{@tagName(args[0])}),
    };
}

/// (char x) — Coerce int to character string.
fn charFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to char", .{args.len});
    const code: u21 = switch (args[0]) {
        .integer => |i| if (i >= 0 and i <= 0x10FFFF)
            @intCast(i)
        else
            return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Value {d} out of Unicode range", .{i}),
        .string => |s| blk: {
            if (s.len == 0) return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Cannot convert empty string to char", .{});
            const view = std.unicode.Utf8View.initUnchecked(s);
            var it = view.iterator();
            break :blk it.nextCodepoint() orelse return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Cannot convert string to char", .{});
        },
        else => return err.setErrorFmt(.eval, .type_error, .{}, "Cannot cast {s} to char", .{@tagName(args[0])}),
    };
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &buf) catch return err.setErrorFmt(.eval, .arithmetic_error, .{}, "Invalid Unicode codepoint", .{});
    const str = allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    return Value{ .string = str };
}

/// (parse-long s) — Parses string to integer, returns nil if not valid.
fn parseLongFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-long", .{args.len});
    const s = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-long expects a string argument", .{}),
    };
    const val = std.fmt.parseInt(i64, s, 10) catch return Value.nil;
    return Value{ .integer = val };
}

/// (parse-double s) — Parses string to double, returns nil if not valid.
fn parseDoubleFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-double", .{args.len});
    const s = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-double expects a string argument", .{}),
    };
    const val = std.fmt.parseFloat(f64, s) catch return Value.nil;
    return Value{ .float = val };
}

/// (parse-uuid s) — Parses string as UUID, returns the UUID string if valid, nil if not.
/// Throws on non-string input. UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
fn parseUuidFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-uuid", .{args.len});
    const s = switch (args[0]) {
        .string => |str| str,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "parse-uuid expects a string argument", .{}),
    };
    if (isValidUuid(s)) {
        return Value{ .string = s };
    }
    return .nil;
}

/// Validate UUID format: 8-4-4-4-12 hex digits with dashes.
fn isValidUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    // Check dash positions: 8, 13, 18, 23
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return false;
    // Check all other positions are hex digits
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!isHexDigit(c)) return false;
    }
    return true;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// (__pow base exp) — returns base raised to the power of exp (as double).
pub fn powFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __pow", .{args.len});
    const base = switch (args[0]) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__pow expects a number", .{}),
    };
    const exp = switch (args[1]) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__pow expects a number", .{}),
    };
    return Value{ .float = std.math.pow(f64, base, exp) };
}

/// (__sqrt n) — returns the square root of n (as double).
pub fn sqrtFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __sqrt", .{args.len});
    const n = switch (args[0]) {
        .integer => |v| @as(f64, @floatFromInt(v)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__sqrt expects a number", .{}),
    };
    return Value{ .float = @sqrt(n) };
}

/// (__round n) — returns the closest long to n.
pub fn roundFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __round", .{args.len});
    const n = switch (args[0]) {
        .integer => |v| return Value{ .integer = v },
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__round expects a number", .{}),
    };
    return Value{ .integer = @intFromFloat(@round(n)) };
}

/// (__ceil n) — returns the smallest integer >= n (as double).
pub fn ceilFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __ceil", .{args.len});
    const n = switch (args[0]) {
        .integer => |v| @as(f64, @floatFromInt(v)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__ceil expects a number", .{}),
    };
    return Value{ .float = @ceil(n) };
}

/// (__floor n) — returns the largest integer <= n (as double).
pub fn floorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __floor", .{args.len});
    const n = switch (args[0]) {
        .integer => |v| @as(f64, @floatFromInt(v)),
        .float => |f| f,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__floor expects a number", .{}),
    };
    return Value{ .float = @floor(n) };
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
        .name = "bit-and-not",
        .func = &bitAndNotFn,
        .doc = "Bitwise and with complement.",
        .arglists = "([x y])",
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
    .{
        .name = "parse-long",
        .func = &parseLongFn,
        .doc = "Parses the string argument as a signed decimal integer, returning nil if not valid.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "parse-double",
        .func = &parseDoubleFn,
        .doc = "Parses the string argument as a double, returning nil if not valid.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "parse-uuid",
        .func = &parseUuidFn,
        .doc = "Parses the string argument as a UUID. Returns the UUID if valid, nil if not.",
        .arglists = "([s])",
        .added = "1.11",
    },
    .{
        .name = "__pow",
        .func = &powFn,
        .doc = "Returns base raised to the power of exp.",
        .arglists = "([base exp])",
        .added = "1.0",
    },
    .{
        .name = "__sqrt",
        .func = &sqrtFn,
        .doc = "Returns the square root of n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__round",
        .func = &roundFn,
        .doc = "Returns the closest long to n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__ceil",
        .func = &ceilFn,
        .doc = "Returns the smallest integer value >= n.",
        .arglists = "([n])",
        .added = "1.0",
    },
    .{
        .name = "__floor",
        .func = &floorFn,
        .doc = "Returns the largest integer value <= n.",
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

test "parse-long valid integer" {
    try testing.expectEqual(Value{ .integer = 42 }, try parseLongFn(test_alloc, &.{Value{ .string = "42" }}));
}

test "parse-long negative" {
    try testing.expectEqual(Value{ .integer = -7 }, try parseLongFn(test_alloc, &.{Value{ .string = "-7" }}));
}

test "parse-long invalid returns nil" {
    try testing.expectEqual(Value.nil, try parseLongFn(test_alloc, &.{Value{ .string = "abc" }}));
}

test "parse-long float string returns nil" {
    try testing.expectEqual(Value.nil, try parseLongFn(test_alloc, &.{Value{ .string = "3.14" }}));
}

test "parse-double valid" {
    const result = try parseDoubleFn(test_alloc, &.{Value{ .string = "3.14" }});
    try testing.expect(result == .float);
    try testing.expect(result.float == 3.14);
}

test "parse-double invalid returns nil" {
    try testing.expectEqual(Value.nil, try parseDoubleFn(test_alloc, &.{Value{ .string = "xyz" }}));
}

test "parse-long non-string throws TypeError" {
    try testing.expectError(error.TypeError, parseLongFn(test_alloc, &.{Value{ .integer = 42 }}));
}
