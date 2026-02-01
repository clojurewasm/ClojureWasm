// Arithmetic builtin definitions — BuiltinDef metadata for +, -, *, /, etc.
//
// Comptime table of BuiltinDef entries for arithmetic and comparison
// operations. These are vm_intrinsic kind — the Compiler emits direct
// opcodes for them. Each also has a runtime fallback function (func) so
// they can be used as first-class values (e.g., (reduce + ...)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../value.zig").Value;

/// Arithmetic and comparison intrinsics registered in clojure.core.
pub const builtins = [_]BuiltinDef{
    .{
        .name = "+",
        .kind = .vm_intrinsic,
        .func = &addFn,
        .doc = "Returns the sum of nums. (+) returns 0. Does not auto-promote longs, will throw on overflow.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "-",
        .kind = .vm_intrinsic,
        .func = &subFn,
        .doc = "If no ys are supplied, returns the negation of x, else subtracts the ys from x and returns the result.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "*",
        .kind = .vm_intrinsic,
        .func = &mulFn,
        .doc = "Returns the product of nums. (*) returns 1. Does not auto-promote longs, will throw on overflow.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "/",
        .kind = .vm_intrinsic,
        .func = &divFn,
        .doc = "If no denominators are supplied, returns 1/numerator, else returns numerator divided by all of the denominators.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "mod",
        .kind = .vm_intrinsic,
        .func = &modFn,
        .doc = "Modulus of num and div. Truncates toward negative infinity.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "rem",
        .kind = .vm_intrinsic,
        .func = &remFn,
        .doc = "Remainder of dividing numerator by denominator.",
        .arglists = "([num div])",
        .added = "1.0",
    },
    .{
        .name = "=",
        .kind = .vm_intrinsic,
        .func = &eqFn,
        .doc = "Equality. Returns true if x equals y, false if not.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "not=",
        .kind = .vm_intrinsic,
        .func = &neqFn,
        .doc = "Same as (not (= obj1 obj2)).",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "<",
        .kind = .vm_intrinsic,
        .func = &ltFn,
        .doc = "Returns non-nil if nums are in monotonically increasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = ">",
        .kind = .vm_intrinsic,
        .func = &gtFn,
        .doc = "Returns non-nil if nums are in monotonically decreasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = "<=",
        .kind = .vm_intrinsic,
        .func = &leFn,
        .doc = "Returns non-nil if nums are in monotonically non-decreasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
    .{
        .name = ">=",
        .kind = .vm_intrinsic,
        .func = &geFn,
        .doc = "Returns non-nil if nums are in monotonically non-increasing order, otherwise false.",
        .arglists = "([x] [x y] [x y & more])",
        .added = "1.0",
    },
};

// --- Runtime fallback functions for first-class usage ---

fn toFloat(v: Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TypeError,
    };
}

fn binaryArith(a: Value, b: Value, comptime op: enum { add, sub, mul }) !Value {
    if (a == .integer and b == .integer) {
        return .{ .integer = switch (op) {
            .add => a.integer +% b.integer,
            .sub => a.integer -% b.integer,
            .mul => a.integer *% b.integer,
        } };
    }
    const fa = try toFloat(a);
    const fb = try toFloat(b);
    return .{ .float = switch (op) {
        .add => fa + fb,
        .sub => fa - fb,
        .mul => fa * fb,
    } };
}

fn addFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return .{ .integer = 0 };
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .add);
    return result;
}

fn subFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) return binaryArith(.{ .integer = 0 }, args[0], .sub);
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .sub);
    return result;
}

fn mulFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return .{ .integer = 1 };
    var result = args[0];
    for (args[1..]) |arg| result = try binaryArith(result, arg, .mul);
    return result;
}

fn divFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) {
        const d = try toFloat(args[0]);
        return .{ .float = 1.0 / d };
    }
    var fa = try toFloat(args[0]);
    for (args[1..]) |arg| fa /= try toFloat(arg);
    return .{ .float = fa };
}

fn modFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] == .integer and args[1] == .integer) {
        return .{ .integer = @mod(args[0].integer, args[1].integer) };
    }
    const a = try toFloat(args[0]);
    const b = try toFloat(args[1]);
    return .{ .float = @mod(a, b) };
}

fn remFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] == .integer and args[1] == .integer) {
        return .{ .integer = @rem(args[0].integer, args[1].integer) };
    }
    const a = try toFloat(args[0]);
    const b = try toFloat(args[1]);
    return .{ .float = @rem(a, b) };
}

fn eqFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) return .{ .boolean = true };
    if (args.len < 2) return error.ArityError;
    for (args[1..]) |arg| {
        if (!args[0].eql(arg)) return .{ .boolean = false };
    }
    return .{ .boolean = true };
}

fn neqFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) return .{ .boolean = false };
    if (args.len < 2) return error.ArityError;
    return .{ .boolean = !args[0].eql(args[1]) };
}

const CompareOp = enum { lt, le, gt, ge };

fn compareFn(a: Value, b: Value, comptime op: CompareOp) !bool {
    if (a == .integer and b == .integer) {
        return switch (op) {
            .lt => a.integer < b.integer,
            .le => a.integer <= b.integer,
            .gt => a.integer > b.integer,
            .ge => a.integer >= b.integer,
        };
    }
    const fa = try toFloat(a);
    const fb = try toFloat(b);
    return switch (op) {
        .lt => fa < fb,
        .le => fa <= fb,
        .gt => fa > fb,
        .ge => fa >= fb,
    };
}

fn makeCompareFn(comptime op: CompareOp) fn (Allocator, []const Value) anyerror!Value {
    return struct {
        fn func(_: Allocator, args: []const Value) anyerror!Value {
            if (args.len == 1) return .{ .boolean = true };
            if (args.len < 2) return error.ArityError;
            for (args[0 .. args.len - 1], args[1..]) |a, b| {
                if (!try compareFn(a, b, op)) return .{ .boolean = false };
            }
            return .{ .boolean = true };
        }
    }.func;
}

const ltFn = makeCompareFn(.lt);
const gtFn = makeCompareFn(.gt);
const leFn = makeCompareFn(.le);
const geFn = makeCompareFn(.ge);

// === Tests ===

test "arithmetic builtins table has 12 entries" {
    try std.testing.expectEqual(12, builtins.len);
}

test "arithmetic builtins are all vm_intrinsic" {
    for (builtins) |b| {
        try std.testing.expect(b.kind == .vm_intrinsic);
    }
}

test "arithmetic builtins have doc and arglists" {
    for (builtins) |b| {
        try std.testing.expect(b.doc != null);
        try std.testing.expect(b.arglists != null);
        try std.testing.expect(b.added != null);
    }
}

test "arithmetic builtins comptime name lookup" {
    const found = comptime blk: {
        for (&builtins) |b| {
            if (std.mem.eql(u8, b.name, "+")) break :blk b;
        }
        @compileError("+ not found");
    };
    try std.testing.expectEqualStrings("+", found.name);
    try std.testing.expect(found.kind == .vm_intrinsic);
}

test "arithmetic builtins no duplicate names" {
    comptime {
        for (builtins, 0..) |a, i| {
            for (builtins[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError("duplicate arithmetic builtin: " ++ a.name);
                }
            }
        }
    }
}
