// Transient collection builtins — transient, persistent!, conj!, assoc!, dissoc!, disj!, pop!
//
// Transient collections are mutable builders for persistent collections.
// Created via (transient coll), mutated in place, finalized via (persistent! t).
// After persistent!, the transient is consumed and further mutation throws.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentVector = value_mod.PersistentVector;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const TransientVector = value_mod.TransientVector;
const TransientArrayMap = value_mod.TransientArrayMap;
const TransientHashSet = value_mod.TransientHashSet;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");

// ============================================================
// Implementations
// ============================================================

/// (transient coll) — creates a transient version of a persistent collection.
pub fn transientFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to transient", .{args.len});
    return switch (args[0]) {
        .vector => |vec| Value{ .transient_vector = try TransientVector.initFrom(allocator, vec) },
        .map => |m| Value{ .transient_map = try TransientArrayMap.initFrom(allocator, m) },
        .set => |s| Value{ .transient_set = try TransientHashSet.initFrom(allocator, s) },
        else => err.setErrorFmt(.eval, .type_error, .{}, "transient not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (persistent! tcoll) — creates a persistent version from a transient.
pub fn persistentBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to persistent!", .{args.len});
    return switch (args[0]) {
        .transient_vector => |tv| Value{ .vector = tv.persistent(allocator) catch return transientConsumedError("persistent!") },
        .transient_map => |tm| Value{ .map = tm.persistent(allocator) catch return transientConsumedError("persistent!") },
        .transient_set => |ts| Value{ .set = ts.persistent(allocator) catch return transientConsumedError("persistent!") },
        else => err.setErrorFmt(.eval, .type_error, .{}, "persistent! not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (conj! tcoll val) — adds val to transient collection. Returns tcoll.
pub fn conjBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to conj!", .{args.len});
    if (args.len == 1) return args[0]; // (conj! tcoll) => tcoll
    return switch (args[0]) {
        .transient_vector => |tv| Value{ .transient_vector = tv.conj(allocator, args[1]) catch return transientConsumedError("conj!") },
        .transient_map => |tm| Value{ .transient_map = tm.conjEntry(allocator, args[1]) catch |e| return transientError(e, "conj!") },
        .transient_set => |ts| Value{ .transient_set = ts.conj(allocator, args[1]) catch return transientConsumedError("conj!") },
        else => err.setErrorFmt(.eval, .type_error, .{}, "conj! not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (assoc! tcoll key val) — associates key with val in transient map/vector.
pub fn assocBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to assoc!", .{args.len});
    return switch (args[0]) {
        .transient_vector => |tv| {
            const idx = switch (args[1]) {
                .integer => |n| blk: {
                    if (n < 0) return err.setErrorFmt(.eval, .value_error, .{}, "assoc! index out of bounds: {d}", .{n});
                    break :blk @as(usize, @intCast(n));
                },
                else => return err.setErrorFmt(.eval, .type_error, .{}, "assoc! on vector requires integer key, got {s}", .{@tagName(args[1])}),
            };
            return Value{ .transient_vector = tv.assocAt(allocator, idx, args[2]) catch |e| {
                return switch (e) {
                    error.TransientUsedAfterPersistent => transientConsumedError("assoc!"),
                    error.IndexOutOfBounds => err.setErrorFmt(.eval, .value_error, .{}, "assoc! index out of bounds", .{}),
                    else => err.setErrorFmt(.eval, .type_error, .{}, "assoc! failed", .{}),
                };
            } };
        },
        .transient_map => |tm| Value{ .transient_map = tm.assocKV(allocator, args[1], args[2]) catch return transientConsumedError("assoc!") },
        else => err.setErrorFmt(.eval, .type_error, .{}, "assoc! not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (dissoc! tmap key) — removes key from transient map.
pub fn dissocBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to dissoc!", .{args.len});
    return switch (args[0]) {
        .transient_map => |tm| Value{ .transient_map = tm.dissocKey(args[1]) catch return transientConsumedError("dissoc!") },
        else => err.setErrorFmt(.eval, .type_error, .{}, "dissoc! not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (disj! tset val) — removes val from transient set.
pub fn disjBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to disj!", .{args.len});
    return switch (args[0]) {
        .transient_set => |ts| Value{ .transient_set = ts.disj(args[1]) catch return transientConsumedError("disj!") },
        else => err.setErrorFmt(.eval, .type_error, .{}, "disj! not supported on {s}", .{@tagName(args[0])}),
    };
}

/// (pop! tvec) — removes last element from transient vector.
pub fn popBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pop!", .{args.len});
    return switch (args[0]) {
        .transient_vector => |tv| Value{ .transient_vector = tv.pop() catch |e| {
            return switch (e) {
                error.TransientUsedAfterPersistent => transientConsumedError("pop!"),
                error.CantPopEmpty => err.setErrorFmt(.eval, .value_error, .{}, "Can't pop empty vector", .{}),
            };
        } },
        else => err.setErrorFmt(.eval, .type_error, .{}, "pop! not supported on {s}", .{@tagName(args[0])}),
    };
}

// ============================================================
// Helpers
// ============================================================

fn transientConsumedError(fn_name: []const u8) anyerror!Value {
    return err.setErrorFmt(.eval, .value_error, .{}, "Transient used after persistent! in {s}", .{fn_name});
}

fn transientError(e: anyerror, fn_name: []const u8) anyerror!Value {
    return switch (e) {
        error.TransientUsedAfterPersistent => transientConsumedError(fn_name),
        error.MapEntryMustBePair => err.setErrorFmt(.eval, .value_error, .{}, "conj! on map expects vector of 2 elements", .{}),
        error.MapConjRequiresVectorOrMap => err.setErrorFmt(.eval, .type_error, .{}, "conj! on map expects vector or map entry", .{}),
        else => err.setErrorFmt(.eval, .type_error, .{}, "{s} failed", .{fn_name}),
    };
}

// ============================================================
// Builtin table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "transient",
        .func = &transientFn,
        .doc = "Returns a new, transient version of the collection, in constant time.",
        .arglists = "([coll])",
        .added = "1.1",
    },
    .{
        .name = "persistent!",
        .func = &persistentBangFn,
        .doc = "Returns a new, persistent version of the transient collection, in constant time. The transient collection cannot be used after this call.",
        .arglists = "([coll])",
        .added = "1.1",
    },
    .{
        .name = "conj!",
        .func = &conjBangFn,
        .doc = "Adds val to the transient collection, and return coll. The collection must be transient.",
        .arglists = "([coll] [coll val])",
        .added = "1.1",
    },
    .{
        .name = "assoc!",
        .func = &assocBangFn,
        .doc = "When applied to a transient map, adds mapping of key(s) to val(s). When applied to a transient vector, sets the val at index.",
        .arglists = "([coll key val])",
        .added = "1.1",
    },
    .{
        .name = "dissoc!",
        .func = &dissocBangFn,
        .doc = "Returns a transient map that doesn't contain a mapping for key(s).",
        .arglists = "([map key])",
        .added = "1.1",
    },
    .{
        .name = "disj!",
        .func = &disjBangFn,
        .doc = "disj[oin]. Returns a transient set of the same type, that does not contain val.",
        .arglists = "([set val])",
        .added = "1.1",
    },
    .{
        .name = "pop!",
        .func = &popBangFn,
        .doc = "Removes the last item from a transient vector. If the collection is empty, throws an exception.",
        .arglists = "([coll])",
        .added = "1.1",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "transient vector - basic conj! and persistent!" {
    const allocator = testing.allocator;

    // Create persistent vector [1 2 3]
    const items = try allocator.alloc(Value, 3);
    items[0] = .{ .integer = 1 };
    items[1] = .{ .integer = 2 };
    items[2] = .{ .integer = 3 };
    const pv = try allocator.create(PersistentVector);
    pv.* = .{ .items = items };
    defer allocator.destroy(pv);
    defer allocator.free(items);

    // (transient [1 2 3])
    const tv_val = try transientFn(allocator, &.{Value{ .vector = pv }});
    try testing.expect(tv_val == .transient_vector);
    const tv = tv_val.transient_vector;
    defer allocator.destroy(tv);
    defer tv.items.deinit(allocator);

    // (conj! tv 4)
    _ = try conjBangFn(allocator, &.{ tv_val, Value{ .integer = 4 } });
    try testing.expectEqual(@as(usize, 4), tv.count());

    // (persistent! tv)
    const result = try persistentBangFn(allocator, &.{tv_val});
    try testing.expect(result == .vector);
    defer allocator.free(result.vector.items);
    defer allocator.destroy(result.vector);

    try testing.expectEqual(@as(usize, 4), result.vector.count());
    try testing.expect(result.vector.nth(0).?.eql(.{ .integer = 1 }));
    try testing.expect(result.vector.nth(3).?.eql(.{ .integer = 4 }));

    // Transient is consumed — further ops should fail
    try testing.expectError(error.ValueError, persistentBangFn(allocator, &.{tv_val}));
}

test "transient map - assoc! dissoc! persistent!" {
    const allocator = testing.allocator;

    // Create persistent map {:a 1}
    const entries = try allocator.alloc(Value, 2);
    entries[0] = .{ .keyword = .{ .name = "a", .ns = null } };
    entries[1] = .{ .integer = 1 };
    const pm = try allocator.create(PersistentArrayMap);
    pm.* = .{ .entries = entries };
    defer allocator.destroy(pm);
    defer allocator.free(entries);

    // (transient {:a 1})
    const tm_val = try transientFn(allocator, &.{Value{ .map = pm }});
    try testing.expect(tm_val == .transient_map);
    const tm = tm_val.transient_map;
    defer allocator.destroy(tm);
    defer tm.entries.deinit(allocator);

    // (assoc! tm :b 2)
    _ = try assocBangFn(allocator, &.{
        tm_val,
        Value{ .keyword = .{ .name = "b", .ns = null } },
        Value{ .integer = 2 },
    });
    try testing.expectEqual(@as(usize, 2), tm.count());

    // (dissoc! tm :a)
    _ = try dissocBangFn(allocator, &.{
        tm_val,
        Value{ .keyword = .{ .name = "a", .ns = null } },
    });
    try testing.expectEqual(@as(usize, 1), tm.count());

    // (persistent! tm)
    const result = try persistentBangFn(allocator, &.{tm_val});
    try testing.expect(result == .map);
    defer allocator.free(result.map.entries);
    defer allocator.destroy(result.map);

    try testing.expectEqual(@as(usize, 1), result.map.count());
}

test "transient set - conj! disj! persistent!" {
    const allocator = testing.allocator;

    // Create persistent set #{1 2}
    const set_items = try allocator.alloc(Value, 2);
    set_items[0] = .{ .integer = 1 };
    set_items[1] = .{ .integer = 2 };
    const ps = try allocator.create(PersistentHashSet);
    ps.* = .{ .items = set_items };
    defer allocator.destroy(ps);
    defer allocator.free(set_items);

    // (transient #{1 2})
    const ts_val = try transientFn(allocator, &.{Value{ .set = ps }});
    try testing.expect(ts_val == .transient_set);
    const ts = ts_val.transient_set;
    defer allocator.destroy(ts);
    defer ts.items.deinit(allocator);

    // (conj! ts 3)
    _ = try conjBangFn(allocator, &.{ ts_val, Value{ .integer = 3 } });
    try testing.expectEqual(@as(usize, 3), ts.count());

    // (conj! ts 2) — duplicate, no-op
    _ = try conjBangFn(allocator, &.{ ts_val, Value{ .integer = 2 } });
    try testing.expectEqual(@as(usize, 3), ts.count());

    // (disj! ts 1)
    _ = try disjBangFn(allocator, &.{ ts_val, Value{ .integer = 1 } });
    try testing.expectEqual(@as(usize, 2), ts.count());

    // (persistent! ts)
    const result = try persistentBangFn(allocator, &.{ts_val});
    try testing.expect(result == .set);
    defer allocator.free(result.set.items);
    defer allocator.destroy(result.set);

    try testing.expectEqual(@as(usize, 2), result.set.count());
}
