// Namespace operations — all-ns, find-ns, ns-name, create-ns, the-ns.
//
// Namespaces are represented as symbols (their name) in the Value system.
// This avoids adding a new Value variant while providing functional API (D47).

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../value.zig").Value;
const collections = @import("../collections.zig");
const bootstrap = @import("../bootstrap.zig");

// ============================================================
// the-ns
// ============================================================

/// (the-ns x)
/// If x is a symbol, finds namespace by name and returns the symbol.
/// Throws if namespace not found.
pub fn theNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidNumberOfArguments;
    const name = switch (args[0]) {
        .symbol => |s| s.name,
        else => return error.TypeError,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    if (env.findNamespace(name) == null) return error.NamespaceNotFound;
    return .{ .symbol = .{ .ns = null, .name = name } };
}

// ============================================================
// all-ns
// ============================================================

/// (all-ns)
/// Returns a list of all namespace names as symbols.
pub fn allNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.InvalidNumberOfArguments;
    const env = bootstrap.macro_eval_env orelse return error.EvalError;

    var ns_iter = env.namespaces.iterator();
    var count: usize = 0;
    while (ns_iter.next()) |_| {
        count += 1;
    }

    const items = try allocator.alloc(Value, count);
    ns_iter = env.namespaces.iterator();
    var i: usize = 0;
    while (ns_iter.next()) |entry| {
        items[i] = .{ .symbol = .{ .ns = null, .name = entry.key_ptr.* } };
        i += 1;
    }

    const lst = try allocator.create(collections.PersistentList);
    lst.* = .{ .items = items };
    return .{ .list = lst };
}

// ============================================================
// find-ns
// ============================================================

/// (find-ns sym)
/// Returns the namespace named by symbol, or nil if not found.
pub fn findNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidNumberOfArguments;
    const name = switch (args[0]) {
        .symbol => |s| s.name,
        else => return error.TypeError,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    if (env.findNamespace(name)) |ns| {
        return .{ .symbol = .{ .ns = null, .name = ns.name } };
    }
    return .nil;
}

// ============================================================
// ns-name
// ============================================================

/// (ns-name ns)
/// Returns the name of the namespace as a symbol.
pub fn nsNameFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidNumberOfArguments;
    return switch (args[0]) {
        .symbol => |s| .{ .symbol = .{ .ns = null, .name = s.name } },
        else => error.TypeError,
    };
}

// ============================================================
// create-ns
// ============================================================

/// (create-ns sym)
/// Finds or creates a namespace named by symbol. Returns the namespace symbol.
pub fn createNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidNumberOfArguments;
    const name = switch (args[0]) {
        .symbol => |s| s.name,
        else => return error.TypeError,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const ns = try env.findOrCreateNamespace(name);
    return .{ .symbol = .{ .ns = null, .name = ns.name } };
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "the-ns",
        .func = theNsFn,
        .doc = "If passed a namespace, returns it. Else, when passed a symbol, returns the namespace named by it, throwing an exception if not found.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "all-ns",
        .func = allNsFn,
        .doc = "Returns a sequence of all namespaces.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "find-ns",
        .func = findNsFn,
        .doc = "Returns the namespace named by the symbol or nil if it doesn't exist.",
        .arglists = "([sym])",
        .added = "1.0",
    },
    .{
        .name = "ns-name",
        .func = nsNameFn,
        .doc = "Returns the name of the namespace, a symbol.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "create-ns",
        .func = createNsFn,
        .doc = "Create a new namespace named by the symbol if one doesn't already exist, returns it or the already-existing namespace of the same name.",
        .arglists = "([sym])",
        .added = "1.0",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const Env = @import("../env.zig").Env;
const registry = @import("registry.zig");

fn setupTestEnv(alloc: Allocator) !*Env {
    const env = try alloc.create(Env);
    env.* = Env.init(alloc);
    try registry.registerBuiltins(env);
    bootstrap.macro_eval_env = env;
    return env;
}

test "find-ns - existing namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try findNsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "clojure.core" } }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("clojure.core", result.symbol.name);
}

test "find-ns - nonexistent namespace returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try findNsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "nonexistent" } }});
    try testing.expectEqual(Value.nil, result);
}

test "all-ns - contains clojure.core and user" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try allNsFn(alloc, &[_]Value{});
    try testing.expect(result == .list);
    try testing.expect(result.list.items.len >= 2); // at least clojure.core and user

    var found_core = false;
    var found_user = false;
    for (result.list.items) |item| {
        if (item == .symbol) {
            if (std.mem.eql(u8, item.symbol.name, "clojure.core")) found_core = true;
            if (std.mem.eql(u8, item.symbol.name, "user")) found_user = true;
        }
    }
    try testing.expect(found_core);
    try testing.expect(found_user);
}

test "ns-name - returns symbol" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try nsNameFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "user" } }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("user", result.symbol.name);
}

test "create-ns - creates new namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // Verify namespace doesn't exist yet
    try testing.expect(env.findNamespace("test.new") == null);

    const result = try createNsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "test.new" } }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("test.new", result.symbol.name);

    // Verify namespace was created
    try testing.expect(env.findNamespace("test.new") != null);
}

test "the-ns - existing namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try theNsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "user" } }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("user", result.symbol.name);
}

test "the-ns - nonexistent namespace errors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = theNsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "nonexistent" } }});
    try testing.expectError(error.NamespaceNotFound, result);
}
