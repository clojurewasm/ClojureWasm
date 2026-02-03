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
// Helpers
// ============================================================

const Namespace = @import("../namespace.zig").Namespace;
const Var = var_mod.Var;

/// Resolve a symbol arg to a Namespace via Env.
fn resolveNs(args: []const Value) !*Namespace {
    if (args.len != 1) return error.InvalidNumberOfArguments;
    const name = switch (args[0]) {
        .symbol => |s| s.name,
        else => return error.TypeError,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    return env.findNamespace(name) orelse return error.NamespaceNotFound;
}

/// Build a {symbol -> var_ref} map from a VarMap (symbol name -> *Var).
fn varMapToValue(allocator: Allocator, map: anytype) !Value {
    var count: usize = 0;
    {
        var iter = map.iterator();
        while (iter.next()) |_| count += 1;
    }

    // Map entries are key/value pairs flattened: [k1, v1, k2, v2, ...]
    const entries = try allocator.alloc(Value, count * 2);
    var iter = map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        entries[i] = .{ .symbol = .{ .ns = null, .name = entry.key_ptr.* } };
        entries[i + 1] = .{ .var_ref = entry.value_ptr.* };
        i += 2;
    }

    const m = try allocator.create(collections.PersistentArrayMap);
    m.* = .{ .entries = entries };
    return .{ .map = m };
}

// ============================================================
// ns-interns
// ============================================================

/// (ns-interns ns)
/// Returns a map of the intern mappings for the namespace.
pub fn nsInternsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    return varMapToValue(allocator, ns.mappings);
}

// ============================================================
// ns-publics
// ============================================================

/// (ns-publics ns)
/// Returns a map of the public intern mappings for the namespace.
/// (Currently all interned vars are public — no private vars yet.)
pub fn nsPublicsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    return varMapToValue(allocator, ns.mappings);
}

// ============================================================
// ns-map
// ============================================================

/// (ns-map ns)
/// Returns a map of all the mappings for the namespace (interned + referred).
pub fn nsMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);

    // Count total entries from both maps
    var count: usize = 0;
    {
        var iter = ns.mappings.iterator();
        while (iter.next()) |_| count += 1;
    }
    {
        var iter = ns.refers.iterator();
        while (iter.next()) |_| count += 1;
    }

    const entries = try allocator.alloc(Value, count * 2);
    var i: usize = 0;

    // Interned vars first
    {
        var iter = ns.mappings.iterator();
        while (iter.next()) |entry| {
            entries[i] = .{ .symbol = .{ .ns = null, .name = entry.key_ptr.* } };
            entries[i + 1] = .{ .var_ref = entry.value_ptr.* };
            i += 2;
        }
    }

    // Referred vars
    {
        var iter = ns.refers.iterator();
        while (iter.next()) |entry| {
            entries[i] = .{ .symbol = .{ .ns = null, .name = entry.key_ptr.* } };
            entries[i + 1] = .{ .var_ref = entry.value_ptr.* };
            i += 2;
        }
    }

    const m = try allocator.create(collections.PersistentArrayMap);
    m.* = .{ .entries = entries };
    return .{ .map = m };
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
    .{
        .name = "ns-interns",
        .func = nsInternsFn,
        .doc = "Returns a map of the intern mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "ns-publics",
        .func = nsPublicsFn,
        .doc = "Returns a map of the public intern mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "ns-map",
        .func = nsMapFn,
        .doc = "Returns a map of all the mappings for the namespace.",
        .arglists = "([ns])",
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

test "ns-interns - returns map with interned vars" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // clojure.core has interned vars (from registerBuiltins)
    const result = try nsInternsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "clojure.core" } }});
    try testing.expect(result == .map);
    // Should have entries (at least the builtins)
    try testing.expect(result.map.entries.len > 0);
    // Entries are key-value pairs, so length is even
    try testing.expect(result.map.entries.len % 2 == 0);
}

test "ns-publics - same as ns-interns (no private vars)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const interns = try nsInternsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "clojure.core" } }});
    const publics = try nsPublicsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "clojure.core" } }});
    try testing.expectEqual(interns.map.entries.len, publics.map.entries.len);
}

test "ns-map - includes interns and refers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // user namespace has refers from clojure.core
    const result = try nsMapFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "user" } }});
    try testing.expect(result == .map);
    // user namespace should have referred vars (from registerBuiltins)
    try testing.expect(result.map.entries.len > 0);
}

test "ns-interns - user namespace is initially empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // user namespace has no interned vars (only refers)
    const result = try nsInternsFn(alloc, &[_]Value{.{ .symbol = .{ .ns = null, .name = "user" } }});
    try testing.expect(result == .map);
    try testing.expectEqual(@as(usize, 0), result.map.entries.len);
}
