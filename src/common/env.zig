// Env — runtime environment (instantiated, no threadlocal).
//
// Owns the ErrorContext (D3a) and Namespace registry (Task 2.2).
// Each VM instance holds its own Env.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("error.zig");
const ns_mod = @import("namespace.zig");
const Namespace = ns_mod.Namespace;

/// Hash context for string-keyed namespace map.
const StrContext = struct {
    pub fn hash(_: StrContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StrContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// Namespace name -> *Namespace map.
pub const NsMap = std.HashMapUnmanaged([]const u8, *Namespace, StrContext, 80);

/// Runtime environment — instantiated per VM.
pub const Env = struct {
    allocator: Allocator,
    error_ctx: err.ErrorContext = .{},
    namespaces: NsMap = .empty,

    /// Current namespace (set during evaluation).
    current_ns: ?*Namespace = null,

    pub fn init(allocator: Allocator) Env {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Env) void {
        var iter = self.namespaces.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.namespaces.deinit(self.allocator);
    }

    /// Find an existing namespace by name, or create it if it doesn't exist.
    pub fn findOrCreateNamespace(self: *Env, name: []const u8) !*Namespace {
        if (self.namespaces.get(name)) |existing| {
            return existing;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        const ns = try self.allocator.create(Namespace);
        ns.* = Namespace.init(self.allocator, owned_name);
        try self.namespaces.put(self.allocator, owned_name, ns);
        return ns;
    }

    /// Find an existing namespace by name. Returns null if not found.
    pub fn findNamespace(self: *const Env, name: []const u8) ?*Namespace {
        return self.namespaces.get(name);
    }
};

// === Tests ===

test "Env init creates valid error context" {
    var env = Env.init(std.heap.page_allocator);
    defer env.deinit();

    // ErrorContext should be usable
    const e = env.error_ctx.setError(.{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "test error",
    });
    try std.testing.expectEqual(error.SyntaxError, e);

    const info = env.error_ctx.getLastError().?;
    try std.testing.expectEqualStrings("test error", info.message);
}

test "Env findOrCreateNamespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    const ns1 = try env.findOrCreateNamespace("user");
    const ns2 = try env.findOrCreateNamespace("user");

    // Same namespace returned
    try std.testing.expectEqual(ns1, ns2);
    try std.testing.expectEqualStrings("user", ns1.name);
}

test "Env findNamespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    // Not found before creation
    try std.testing.expect(env.findNamespace("user") == null);

    _ = try env.findOrCreateNamespace("user");

    // Found after creation
    try std.testing.expect(env.findNamespace("user") != null);
}

test "Env namespace intern and resolve" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    const ns = try env.findOrCreateNamespace("user");
    const v = try ns.intern("foo");
    v.bindRoot(.{ .integer = 42 });

    // Resolve through namespace
    const resolved = ns.resolve("foo");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 42 }));
}

test "Env multiple namespaces with refer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    const core = try env.findOrCreateNamespace("clojure.core");
    const user = try env.findOrCreateNamespace("user");

    const plus_var = try core.intern("+");
    plus_var.bindRoot(.{ .integer = 1 });

    try user.refer("+", plus_var);

    const resolved = user.resolve("+");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 1 }));
}

test "Env current_ns" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    try std.testing.expect(env.current_ns == null);

    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    try std.testing.expectEqualStrings("user", env.current_ns.?.name);
}
