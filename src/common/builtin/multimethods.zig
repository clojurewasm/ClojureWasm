// Multimethod operation builtins — methods, get-method, remove-method,
// remove-all-methods, prefers, prefer-method.
//
// These operate on MultiFn values created by defmulti/defmethod.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const MultiFn = value_mod.MultiFn;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;

/// (methods multifn) => map of dispatch-val -> method-fn
pub fn methodsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    return Value{ .map = mf.methods };
}

/// (get-method multifn dispatch-val) => method-fn or nil
pub fn getMethodFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    return mf.methods.get(args[1]) orelse .nil;
}

/// (remove-method multifn dispatch-val) => multifn
/// Removes the method associated with dispatch-val.
pub fn removeMethodFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    const old_entries = mf.methods.entries;
    const dispatch_val = args[1];

    // Count entries to keep (skip matching key-value pair)
    var keep_count: usize = 0;
    var i: usize = 0;
    while (i < old_entries.len) : (i += 2) {
        if (!old_entries[i].eql(dispatch_val)) {
            keep_count += 2;
        }
    }

    if (keep_count == old_entries.len) {
        // Key not found — no change
        return args[0];
    }

    const new_entries = try allocator.alloc(Value, keep_count);
    var j: usize = 0;
    i = 0;
    while (i < old_entries.len) : (i += 2) {
        if (!old_entries[i].eql(dispatch_val)) {
            new_entries[j] = old_entries[i];
            new_entries[j + 1] = old_entries[i + 1];
            j += 2;
        }
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = new_entries };
    mf.methods = new_map;

    return args[0];
}

/// (remove-all-methods multifn) => multifn
/// Removes all methods from the multimethod.
pub fn removeAllMethodsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };

    const empty_map = try allocator.create(PersistentArrayMap);
    empty_map.* = .{ .entries = &.{} };
    mf.methods = empty_map;

    return args[0];
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "methods",
        .func = &methodsFn,
        .doc = "Given a multimethod, returns a map of dispatch values -> dispatch fns",
        .arglists = "([multifn])",
        .added = "1.0",
    },
    .{
        .name = "get-method",
        .func = &getMethodFn,
        .doc = "Given a multimethod and a dispatch value, returns the dispatch fn that would apply to that value, or nil if none apply and no default",
        .arglists = "([multifn dispatch-val])",
        .added = "1.0",
    },
    .{
        .name = "remove-method",
        .func = &removeMethodFn,
        .doc = "Removes the method of multimethod associated with dispatch-value.",
        .arglists = "([multifn dispatch-val])",
        .added = "1.0",
    },
    .{
        .name = "remove-all-methods",
        .func = &removeAllMethodsFn,
        .doc = "Removes all of the methods of multimethod.",
        .arglists = "([multifn])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "methods - returns method map" {
    var entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } },
        .{ .integer = 2 },
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = .nil,
        .methods = &map,
    };

    const args = [_]Value{.{ .multi_fn = &mf }};
    const result = try methodsFn(testing.allocator, &args);
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 4), result.map.entries.len);
}

test "get-method - returns method or nil" {
    var entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .integer = 42 },
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = .nil,
        .methods = &map,
    };

    // Found
    const args1 = [_]Value{ .{ .multi_fn = &mf }, .{ .keyword = .{ .name = "a", .ns = null } } };
    const r1 = try getMethodFn(testing.allocator, &args1);
    try testing.expectEqual(Value{ .integer = 42 }, r1);

    // Not found
    const args2 = [_]Value{ .{ .multi_fn = &mf }, .{ .keyword = .{ .name = "b", .ns = null } } };
    const r2 = try getMethodFn(testing.allocator, &args2);
    try testing.expectEqual(Value.nil, r2);
}

test "remove-method - removes dispatch entry" {
    var entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } },
        .{ .integer = 2 },
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = .nil,
        .methods = &map,
    };

    const args = [_]Value{ .{ .multi_fn = &mf }, .{ .keyword = .{ .name = "a", .ns = null } } };
    const result = try removeMethodFn(testing.allocator, &args);
    try testing.expect(result == .multi_fn);
    try testing.expectEqual(@as(usize, 2), mf.methods.entries.len);

    // Verify :b remains
    const get_args = [_]Value{ .{ .multi_fn = &mf }, .{ .keyword = .{ .name = "b", .ns = null } } };
    const b_val = try getMethodFn(testing.allocator, &get_args);
    try testing.expectEqual(Value{ .integer = 2 }, b_val);

    // Clean up
    testing.allocator.free(mf.methods.entries);
    testing.allocator.destroy(mf.methods);
}

test "remove-all-methods - clears all methods" {
    var entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } },
        .{ .integer = 1 },
    };
    var map = PersistentArrayMap{ .entries = &entries };
    var mf = MultiFn{
        .name = "test-mf",
        .dispatch_fn = .nil,
        .methods = &map,
    };

    const args = [_]Value{.{ .multi_fn = &mf }};
    const result = try removeAllMethodsFn(testing.allocator, &args);
    try testing.expect(result == .multi_fn);
    try testing.expectEqual(@as(usize, 0), mf.methods.entries.len);

    testing.allocator.destroy(mf.methods);
}
