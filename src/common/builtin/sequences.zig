// Sequence utility functions — range, repeat, iterate, empty?, contains?, keys, vals.
//
// Runtime functions (kind = .runtime_fn) dispatched via BuiltinFn.
// Phase 6a additions to the standard library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const PersistentVector = value_mod.PersistentVector;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;

// ============================================================
// Implementations
// ============================================================

/// (empty? coll) — returns true if coll has no items, or coll is nil.
pub fn emptyFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => Value{ .boolean = true },
        .list => |lst| Value{ .boolean = lst.count() == 0 },
        .vector => |vec| Value{ .boolean = vec.count() == 0 },
        .map => |m| Value{ .boolean = m.count() == 0 },
        .set => |s| Value{ .boolean = s.count() == 0 },
        .string => |s| Value{ .boolean = s.len == 0 },
        else => error.TypeError,
    };
}

/// (range n), (range start end), (range start end step) — returns a list of numbers.
/// Eager implementation (not lazy). All-integer args produce integer results.
pub fn rangeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0 or args.len > 3) return error.ArityError;

    // Extract numeric values as f64 for uniform handling
    const start_val: f64 = if (args.len == 1) 0.0 else try toFloat(args[0]);
    const end_val: f64 = if (args.len == 1) try toFloat(args[0]) else try toFloat(args[1]);
    const step_val: f64 = if (args.len == 3) try toFloat(args[2]) else 1.0;

    if (step_val == 0.0) return error.ArithmeticError;

    // Determine if all inputs are integers (for integer output)
    const all_int = allIntegers(args);

    // Calculate count
    var count: usize = 0;
    if (step_val > 0) {
        var v = start_val;
        while (v < end_val) : (v += step_val) {
            count += 1;
            if (count > 1_000_000) return error.OutOfMemory; // safety limit
        }
    } else {
        var v = start_val;
        while (v > end_val) : (v += step_val) {
            count += 1;
            if (count > 1_000_000) return error.OutOfMemory;
        }
    }

    // Build list
    const items = try allocator.alloc(Value, count);
    var v = start_val;
    for (items) |*item| {
        if (all_int) {
            item.* = Value{ .integer = @intFromFloat(v) };
        } else {
            item.* = Value{ .float = v };
        }
        v += step_val;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (repeat n x) — returns a list of x repeated n times.
pub fn repeatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const n = switch (args[0]) {
        .integer => |i| if (i < 0) return error.ArithmeticError else @as(usize, @intCast(i)),
        else => return error.TypeError,
    };
    if (n > 1_000_000) return error.OutOfMemory;

    const items = try allocator.alloc(Value, n);
    for (items) |*item| {
        item.* = args[1];
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (contains? coll key) — true if key is present in coll.
/// For maps: key lookup. For sets: membership. For vectors: index in range.
pub fn containsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .map => |m| Value{ .boolean = m.get(args[1]) != null },
        .set => |s| Value{ .boolean = s.contains(args[1]) },
        .vector => |vec| switch (args[1]) {
            .integer => |i| Value{ .boolean = i >= 0 and @as(usize, @intCast(i)) < vec.count() },
            else => Value{ .boolean = false },
        },
        .nil => Value{ .boolean = false },
        else => error.TypeError,
    };
}

/// (keys map) — returns a list of the map's keys.
pub fn keysFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] == .nil) return Value.nil;
    const m = switch (args[0]) {
        .map => |m| m,
        else => return error.TypeError,
    };
    const n = m.count();
    if (n == 0) return Value.nil;
    const items = try allocator.alloc(Value, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        items[i] = m.entries[i * 2];
    }
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (vals map) — returns a list of the map's values.
pub fn valsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] == .nil) return Value.nil;
    const m = switch (args[0]) {
        .map => |m| m,
        else => return error.TypeError,
    };
    const n = m.count();
    if (n == 0) return Value.nil;
    const items = try allocator.alloc(Value, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        items[i] = m.entries[i * 2 + 1];
    }
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

fn toFloat(v: Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TypeError,
    };
}

fn allIntegers(args: []const Value) bool {
    for (args) |a| {
        switch (a) {
            .integer => {},
            else => return false,
        }
    }
    return true;
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "empty?",
        .kind = .runtime_fn,
        .func = &emptyFn,
        .doc = "Returns true if coll has no items - same as (not (seq coll)). Please use the idiom (seq x) rather than (not (empty? x)).",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "range",
        .kind = .runtime_fn,
        .func = &rangeFn,
        .doc = "Returns a list of nums from start (inclusive) to end (exclusive), by step.",
        .arglists = "([end] [start end] [start end step])",
        .added = "1.0",
    },
    .{
        .name = "repeat",
        .kind = .runtime_fn,
        .func = &repeatFn,
        .doc = "Returns a list of xs repeated n times.",
        .arglists = "([n x])",
        .added = "1.0",
    },
    .{
        .name = "contains?",
        .kind = .runtime_fn,
        .func = &containsFn,
        .doc = "Returns true if key is present in the given collection, otherwise returns false.",
        .arglists = "([coll key])",
        .added = "1.0",
    },
    .{
        .name = "keys",
        .kind = .runtime_fn,
        .func = &keysFn,
        .doc = "Returns a sequence of the map's keys, in the same order as (seq map).",
        .arglists = "([map])",
        .added = "1.0",
    },
    .{
        .name = "vals",
        .kind = .runtime_fn,
        .func = &valsFn,
        .doc = "Returns a sequence of the map's values, in the same order as (seq map).",
        .arglists = "([map])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "empty? on nil returns true" {
    const result = try emptyFn(test_alloc, &.{Value.nil});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on empty list returns true" {
    var lst = PersistentList{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty list returns false" {
    const items = [_]Value{.{ .integer = 1 }};
    var lst = PersistentList{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? on empty vector returns true" {
    var vec = PersistentVector{ .items = &.{} };
    const result = try emptyFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty vector returns false" {
    const items = [_]Value{.{ .integer = 1 }};
    var vec = PersistentVector{ .items = &items };
    const result = try emptyFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? on empty string returns true" {
    const result = try emptyFn(test_alloc, &.{Value{ .string = "" }});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "empty? on non-empty string returns false" {
    const result = try emptyFn(test_alloc, &.{Value{ .string = "hello" }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "empty? arity check" {
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{}));
    try testing.expectError(error.ArityError, emptyFn(test_alloc, &.{ Value.nil, Value.nil }));
}

// --- range tests ---

test "range with single arg (range 5)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{Value{ .integer = 5 }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.count());
    // Should be 0, 1, 2, 3, 4
    try testing.expectEqual(Value{ .integer = 0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[4]);
}

test "range with two args (range 2 6)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{ Value{ .integer = 2 }, Value{ .integer = 6 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.list.count());
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 5 }, result.list.items[3]);
}

test "range with three args (range 0 10 3)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 0 },
        Value{ .integer = 10 },
        Value{ .integer = 3 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 4), result.list.count());
    // 0, 3, 6, 9
    try testing.expectEqual(Value{ .integer = 0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 9 }, result.list.items[3]);
}

test "range with negative step" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 5 },
        Value{ .integer = 0 },
        Value{ .integer = -1 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.count());
    try testing.expectEqual(Value{ .integer = 5 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[4]);
}

test "range with float produces floats" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .float = 0.0 },
        Value{ .float = 1.0 },
        Value{ .float = 0.5 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expectEqual(Value{ .float = 0.0 }, result.list.items[0]);
    try testing.expectEqual(Value{ .float = 0.5 }, result.list.items[1]);
}

test "range empty when start >= end" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try rangeFn(arena.allocator(), &.{
        Value{ .integer = 5 },
        Value{ .integer = 3 },
    });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "range zero step is error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try testing.expectError(error.ArithmeticError, rangeFn(arena.allocator(), &.{
        Value{ .integer = 0 },
        Value{ .integer = 10 },
        Value{ .integer = 0 },
    }));
}

test "range arity check" {
    try testing.expectError(error.ArityError, rangeFn(test_alloc, &.{}));
}

// --- repeat tests ---

test "repeat 3 times" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try repeatFn(arena.allocator(), &.{ Value{ .integer = 3 }, Value{ .integer = 42 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expectEqual(Value{ .integer = 42 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 42 }, result.list.items[2]);
}

test "repeat 0 times" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try repeatFn(arena.allocator(), &.{ Value{ .integer = 0 }, Value{ .string = "x" } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "repeat arity check" {
    try testing.expectError(error.ArityError, repeatFn(test_alloc, &.{Value{ .integer = 3 }}));
}

// --- contains? tests ---

test "contains? on map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const yes = try containsFn(test_alloc, &.{ Value{ .map = &m }, Value{ .keyword = .{ .name = "a", .ns = null } } });
    try testing.expectEqual(Value{ .boolean = true }, yes);
    const no = try containsFn(test_alloc, &.{ Value{ .map = &m }, Value{ .keyword = .{ .name = "z", .ns = null } } });
    try testing.expectEqual(Value{ .boolean = false }, no);
}

test "contains? on vector checks index" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 } };
    var vec = PersistentVector{ .items = &items };
    const yes = try containsFn(test_alloc, &.{ Value{ .vector = &vec }, Value{ .integer = 0 } });
    try testing.expectEqual(Value{ .boolean = true }, yes);
    const no = try containsFn(test_alloc, &.{ Value{ .vector = &vec }, Value{ .integer = 5 } });
    try testing.expectEqual(Value{ .boolean = false }, no);
}

test "contains? on nil returns false" {
    const result = try containsFn(test_alloc, &.{ Value.nil, Value{ .integer = 0 } });
    try testing.expectEqual(Value{ .boolean = false }, result);
}

// --- keys/vals tests ---

test "keys on map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try keysFn(arena.allocator(), &.{Value{ .map = &m }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expect(result.list.items[0].eql(Value{ .keyword = .{ .name = "a", .ns = null } }));
}

test "keys on nil returns nil" {
    const result = try keysFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "vals on map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try valsFn(arena.allocator(), &.{Value{ .map = &m }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[1]);
}

test "vals on nil returns nil" {
    const result = try valsFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}
