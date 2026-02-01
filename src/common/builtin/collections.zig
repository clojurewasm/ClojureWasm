// Collection intrinsic functions — first, rest, cons, conj, assoc, get, nth, count.
//
// Runtime functions (kind = .runtime_fn) dispatched via BuiltinFn.
// These operate on the persistent collection types defined in collections.zig.

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

/// (first coll) — returns the first element, or nil if empty/nil.
pub fn firstFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => |lst| lst.first(),
        .vector => |vec| if (vec.items.len > 0) vec.items[0] else .nil,
        .nil => .nil,
        else => error.TypeError,
    };
}

/// (rest coll) — returns everything after first, or empty list.
pub fn restFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => |lst| blk: {
            const r = lst.rest();
            const new_list = try allocator.create(PersistentList);
            new_list.* = r;
            break :blk Value{ .list = new_list };
        },
        .vector => |vec| blk: {
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = if (vec.items.len > 0) vec.items[1..] else &.{} };
            break :blk Value{ .list = new_list };
        },
        .nil => blk: {
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = &.{} };
            break :blk Value{ .list = new_list };
        },
        else => error.TypeError,
    };
}

/// (cons x seq) — prepend x to seq, returns a list.
pub fn consFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const x = args[0];
    const seq_items = switch (args[1]) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        .nil => @as([]const Value, &.{}),
        else => return error.TypeError,
    };

    const new_items = try allocator.alloc(Value, seq_items.len + 1);
    new_items[0] = x;
    @memcpy(new_items[1..], seq_items);

    const new_list = try allocator.create(PersistentList);
    new_list.* = .{ .items = new_items };
    return Value{ .list = new_list };
}

/// (conj coll x) — add to collection (front for list, back for vector).
pub fn conjFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const coll = args[0];
    // conj adds remaining args one at a time
    var current = coll;
    for (args[1..]) |x| {
        current = try conjOne(allocator, current, x);
    }
    return current;
}

fn conjOne(allocator: Allocator, coll: Value, x: Value) anyerror!Value {
    switch (coll) {
        .list => |lst| {
            const new_items = try allocator.alloc(Value, lst.items.len + 1);
            new_items[0] = x;
            @memcpy(new_items[1..], lst.items);
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items };
            return Value{ .list = new_list };
        },
        .vector => |vec| {
            const new_items = try allocator.alloc(Value, vec.items.len + 1);
            @memcpy(new_items[0..vec.items.len], vec.items);
            new_items[vec.items.len] = x;
            const new_vec = try allocator.create(PersistentVector);
            new_vec.* = .{ .items = new_items };
            return Value{ .vector = new_vec };
        },
        .set => |s| {
            // Add element if not already present
            if (s.contains(x)) return coll;
            const new_items = try allocator.alloc(Value, s.items.len + 1);
            @memcpy(new_items[0..s.items.len], s.items);
            new_items[s.items.len] = x;
            const new_set = try allocator.create(PersistentHashSet);
            new_set.* = .{ .items = new_items };
            return Value{ .set = new_set };
        },
        .nil => {
            // (conj nil x) => (x) — returns a list
            const new_items = try allocator.alloc(Value, 1);
            new_items[0] = x;
            const new_list = try allocator.create(PersistentList);
            new_list.* = .{ .items = new_items };
            return Value{ .list = new_list };
        },
        else => return error.TypeError,
    }
}

/// (assoc map key val & kvs) — associate key(s) with val(s) in map.
pub fn assocFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;
    const base = args[0];
    const base_entries = switch (base) {
        .map => |m| m.entries,
        .nil => @as([]const Value, &.{}),
        else => return error.TypeError,
    };

    // Build new entries: copy base, then override/add pairs
    var entries = std.ArrayList(Value).empty;
    try entries.appendSlice(allocator, base_entries);

    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = args[i];
        const val = args[i + 1];
        // Try to find existing key and replace
        var found = false;
        var j: usize = 0;
        while (j < entries.items.len) : (j += 2) {
            if (entries.items[j].eql(key)) {
                entries.items[j + 1] = val;
                found = true;
                break;
            }
        }
        if (!found) {
            try entries.append(allocator, key);
            try entries.append(allocator, val);
        }
    }

    const new_map = try allocator.create(PersistentArrayMap);
    new_map.* = .{ .entries = entries.items };
    return Value{ .map = new_map };
}

/// (get map key) or (get map key not-found) — lookup in map or set.
pub fn getFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const not_found: Value = if (args.len == 3) args[2] else .nil;
    return switch (args[0]) {
        .map => |m| m.get(args[1]) orelse not_found,
        .set => |s| if (s.contains(args[1])) args[1] else not_found,
        .nil => not_found,
        else => not_found,
    };
}

/// (nth coll index) or (nth coll index not-found) — indexed access.
pub fn nthFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const idx_val = args[1];
    if (idx_val != .integer) return error.TypeError;
    const idx = idx_val.integer;
    if (idx < 0) {
        if (args.len == 3) return args[2];
        return error.IndexOutOfBounds;
    }
    const uidx: usize = @intCast(idx);

    return switch (args[0]) {
        .vector => |vec| vec.nth(uidx) orelse if (args.len == 3) args[2] else error.IndexOutOfBounds,
        .list => |lst| if (uidx < lst.items.len) lst.items[uidx] else if (args.len == 3) args[2] else error.IndexOutOfBounds,
        .nil => if (args.len == 3) args[2] else error.IndexOutOfBounds,
        else => error.TypeError,
    };
}

/// (count coll) — number of elements.
pub fn countFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .integer = @intCast(switch (args[0]) {
        .list => |lst| lst.count(),
        .vector => |vec| vec.count(),
        .map => |m| m.count(),
        .set => |s| s.count(),
        .nil => @as(usize, 0),
        .string => |s| s.len,
        else => return error.TypeError,
    }) };
}

/// (list & items) — returns a new list containing the items.
pub fn listFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (seq coll) — returns a seq on the collection. Returns nil if empty.
pub fn seqFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => .nil,
        .list => |lst| if (lst.items.len == 0) .nil else args[0],
        .vector => |vec| {
            if (vec.items.len == 0) return .nil;
            // Return as-is (vector is sequential)
            return args[0];
        },
        else => error.TypeError,
    };
}

/// (concat) / (concat x) / (concat x y ...) — concatenate sequences.
pub fn concatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        const lst = try allocator.create(PersistentList);
        lst.* = .{ .items = &.{} };
        return Value{ .list = lst };
    }

    // Collect all items from all sequences
    var total: usize = 0;
    for (args) |arg| {
        total += switch (arg) {
            .nil => @as(usize, 0),
            .list => |lst| lst.items.len,
            .vector => |vec| vec.items.len,
            else => return error.TypeError,
        };
    }

    const items = try allocator.alloc(Value, total);
    var idx: usize = 0;
    for (args) |arg| {
        const src = switch (arg) {
            .nil => &[_]Value{},
            .list => |lst| lst.items,
            .vector => |vec| vec.items,
            else => unreachable,
        };
        @memcpy(items[idx .. idx + src.len], src);
        idx += src.len;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// (reverse coll) — returns a list of items in reverse order.
pub fn reverseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = switch (args[0]) {
        .nil => return .nil,
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => return error.TypeError,
    };
    if (items.len == 0) return .nil;

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const lst = try allocator.create(PersistentList);
    lst.* = .{ .items = new_items };
    return Value{ .list = lst };
}

/// (into to from) — returns a new coll with items from `from` conj'd onto `to`.
pub fn intoFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const from_items = switch (args[1]) {
        .nil => return args[0],
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => return error.TypeError,
    };
    if (from_items.len == 0) return args[0];

    var current = args[0];
    for (from_items) |item| {
        current = try conjFn(allocator, &.{ current, item });
    }
    return current;
}

/// (apply f args) / (apply f x y args) — calls f with args from final collection.
pub fn applyFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    const f = args[0];
    const last_arg = args[args.len - 1];

    // Collect spread args from last collection
    const spread_items = switch (last_arg) {
        .nil => @as([]const Value, &.{}),
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => return error.TypeError,
    };

    // Build final args: middle args + spread items
    const middle_count = args.len - 2; // exclude f and last_arg
    const total = middle_count + spread_items.len;
    const call_args = try allocator.alloc(Value, total);
    if (middle_count > 0) {
        @memcpy(call_args[0..middle_count], args[1 .. args.len - 1]);
    }
    if (spread_items.len > 0) {
        @memcpy(call_args[middle_count..], spread_items);
    }

    // Call the function
    return switch (f) {
        .builtin_fn => |func| func(allocator, call_args),
        else => error.TypeError,
    };
}

/// (vector & items) — creates a vector from arguments.
pub fn vectorFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// (hash-map & kvs) — creates a map from key-value pairs.
pub fn hashMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);
    const map = try allocator.create(PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value{ .map = map };
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "first",
        .kind = .runtime_fn,
        .func = &firstFn,
        .doc = "Returns the first item in the collection. Calls seq on its argument. If coll is nil, returns nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "rest",
        .kind = .runtime_fn,
        .func = &restFn,
        .doc = "Returns a possibly empty seq of the items after the first. Calls seq on its argument.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "cons",
        .kind = .runtime_fn,
        .func = &consFn,
        .doc = "Returns a new seq where x is the first element and seq is the rest.",
        .arglists = "([x seq])",
        .added = "1.0",
    },
    .{
        .name = "conj",
        .kind = .runtime_fn,
        .func = &conjFn,
        .doc = "conj[oin]. Returns a new collection with the xs 'added'.",
        .arglists = "([coll x] [coll x & xs])",
        .added = "1.0",
    },
    .{
        .name = "assoc",
        .kind = .runtime_fn,
        .func = &assocFn,
        .doc = "assoc[iate]. When applied to a map, returns a new map that contains the mapping of key(s) to val(s).",
        .arglists = "([map key val] [map key val & kvs])",
        .added = "1.0",
    },
    .{
        .name = "get",
        .kind = .runtime_fn,
        .func = &getFn,
        .doc = "Returns the value mapped to key, not-found or nil if key not present.",
        .arglists = "([map key] [map key not-found])",
        .added = "1.0",
    },
    .{
        .name = "nth",
        .kind = .runtime_fn,
        .func = &nthFn,
        .doc = "Returns the value at the index.",
        .arglists = "([coll index] [coll index not-found])",
        .added = "1.0",
    },
    .{
        .name = "count",
        .kind = .runtime_fn,
        .func = &countFn,
        .doc = "Returns the number of items in the collection.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "list",
        .kind = .runtime_fn,
        .func = &listFn,
        .doc = "Creates a new list containing the items.",
        .arglists = "([& items])",
        .added = "1.0",
    },
    .{
        .name = "seq",
        .kind = .runtime_fn,
        .func = &seqFn,
        .doc = "Returns a seq on the collection. If the collection is empty, returns nil.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "concat",
        .kind = .runtime_fn,
        .func = &concatFn,
        .doc = "Returns a lazy seq representing the concatenation of the elements in the supplied colls.",
        .arglists = "([] [x] [x y] [x y & zs])",
        .added = "1.0",
    },
    .{
        .name = "reverse",
        .kind = .runtime_fn,
        .func = &reverseFn,
        .doc = "Returns a seq of the items in coll in reverse order.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "into",
        .kind = .runtime_fn,
        .func = &intoFn,
        .doc = "Returns a new coll consisting of to-coll with all of the items of from-coll conjoined.",
        .arglists = "([to from])",
        .added = "1.0",
    },
    .{
        .name = "apply",
        .kind = .runtime_fn,
        .func = &applyFn,
        .doc = "Applies fn f to the argument list formed by prepending intervening arguments to args.",
        .arglists = "([f args] [f x args] [f x y args] [f x y z args])",
        .added = "1.0",
    },
    .{
        .name = "vector",
        .kind = .runtime_fn,
        .func = &vectorFn,
        .doc = "Creates a new vector containing the args.",
        .arglists = "([& args])",
        .added = "1.0",
    },
    .{
        .name = "hash-map",
        .kind = .runtime_fn,
        .func = &hashMapFn,
        .doc = "Returns a new hash map with supplied mappings.",
        .arglists = "([& keyvals])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "first on list" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var lst = PersistentList{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expect(result.eql(.{ .integer = 1 }));
}

test "first on empty list" {
    var lst = PersistentList{ .items = &.{} };
    const result = try firstFn(test_alloc, &.{Value{ .list = &lst }});
    try testing.expect(result.isNil());
}

test "first on nil" {
    const result = try firstFn(test_alloc, &.{Value.nil});
    try testing.expect(result.isNil());
}

test "first on vector" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 } };
    var vec = PersistentVector{ .items = &items };
    const result = try firstFn(test_alloc, &.{Value{ .vector = &vec }});
    try testing.expect(result.eql(.{ .integer = 10 }));
}

test "rest on list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try restFn(arena.allocator(), &.{Value{ .list = &lst }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.count());
}

test "rest on nil returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try restFn(arena.allocator(), &.{Value.nil});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 0), result.list.count());
}

test "cons prepends to list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try consFn(arena.allocator(), &.{ Value{ .integer = 1 }, Value{ .list = &lst } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expect(result.list.first().eql(.{ .integer = 1 }));
}

test "cons onto nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try consFn(arena.allocator(), &.{ Value{ .integer = 1 }, Value.nil });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.count());
}

test "conj to list prepends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value{ .list = &lst }, Value{ .integer = 1 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.count());
    try testing.expect(result.list.first().eql(.{ .integer = 1 }));
}

test "conj to vector appends" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var vec = PersistentVector{ .items = &items };
    const result = try conjFn(arena.allocator(), &.{ Value{ .vector = &vec }, Value{ .integer = 3 } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.count());
    try testing.expect(result.vector.nth(2).?.eql(.{ .integer = 3 }));
}

test "conj nil returns list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = try conjFn(arena.allocator(), &.{ Value.nil, Value{ .integer = 1 } });
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 1), result.list.count());
}

test "assoc adds to map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "b", .ns = null } },
        Value{ .integer = 2 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 2), result.map.count());
}

test "assoc replaces existing key" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try assocFn(arena.allocator(), &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "a", .ns = null } },
        Value{ .integer = 99 },
    });
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 1), result.map.count());
    const v = result.map.get(.{ .keyword = .{ .name = "a", .ns = null } });
    try testing.expect(v.?.eql(.{ .integer = 99 }));
}

test "get from map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "a", .ns = null } },
    });
    try testing.expect(result.eql(.{ .integer = 1 }));
}

test "get missing key returns nil" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "z", .ns = null } },
    });
    try testing.expect(result.isNil());
}

test "get with not-found" {
    const entries = [_]Value{};
    var m = PersistentArrayMap{ .entries = &entries };
    const result = try getFn(test_alloc, &.{
        Value{ .map = &m },
        Value{ .keyword = .{ .name = "z", .ns = null } },
        Value{ .integer = -1 },
    });
    try testing.expect(result.eql(.{ .integer = -1 }));
}

test "nth on vector" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 1 },
    });
    try testing.expect(result.eql(.{ .integer = 20 }));
}

test "nth out of bounds" {
    const items = [_]Value{ .{ .integer = 10 } };
    var vec = PersistentVector{ .items = &items };
    try testing.expectError(error.IndexOutOfBounds, nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 5 },
    }));
}

test "nth with not-found" {
    const items = [_]Value{ .{ .integer = 10 } };
    var vec = PersistentVector{ .items = &items };
    const result = try nthFn(test_alloc, &.{
        Value{ .vector = &vec },
        Value{ .integer = 5 },
        Value{ .integer = -1 },
    });
    try testing.expect(result.eql(.{ .integer = -1 }));
}

test "count on various types" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    var lst = PersistentList{ .items = &items };
    var vec = PersistentVector{ .items = &items };

    try testing.expectEqual(Value{ .integer = 2 }, try countFn(test_alloc, &.{Value{ .list = &lst }}));
    try testing.expectEqual(Value{ .integer = 2 }, try countFn(test_alloc, &.{Value{ .vector = &vec }}));
    try testing.expectEqual(Value{ .integer = 0 }, try countFn(test_alloc, &.{Value.nil}));
    try testing.expectEqual(Value{ .integer = 5 }, try countFn(test_alloc, &.{Value{ .string = "hello" }}));
}

test "builtins table has 16 entries" {
    try testing.expectEqual(16, builtins.len);
}

test "reverse list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var lst = PersistentList{ .items = &items };
    const result = try reverseFn(alloc, &.{Value{ .list = &lst }});
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 3 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[2]);
}

test "reverse nil" {
    const result = try reverseFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .nil);
}

test "apply with builtin_fn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (apply count [[1 2 3]]) -> 3
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var inner_vec = PersistentVector{ .items = &items };
    const arg_items = [_]Value{Value{ .vector = &inner_vec }};
    var arg_list = PersistentList{ .items = &arg_items };
    const result = try applyFn(alloc, &.{
        Value{ .builtin_fn = &countFn },
        Value{ .list = &arg_list },
    });
    try testing.expectEqual(Value{ .integer = 3 }, result);
}

test "builtins all have func" {
    for (builtins) |b| {
        try testing.expect(b.func != null);
        try testing.expect(b.kind == .runtime_fn);
    }
}
