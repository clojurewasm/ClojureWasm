// Namespace — Symbol -> Var mapping.
//
// Each Namespace manages its own Vars (intern), references to other
// namespaces' Vars (refer), and aliases to other namespaces.
// Owned by Env (runtime environment).

const std = @import("std");
const value = @import("value.zig");
const Symbol = value.Symbol;
const Value = value.Value;
const var_mod = @import("var.zig");
const Var = var_mod.Var;

/// Hash context for string-keyed maps.
const SymbolNameContext = struct {
    pub fn hash(_: SymbolNameContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: SymbolNameContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// Symbol name -> *Var map.
pub const VarMap = std.HashMapUnmanaged([]const u8, *Var, SymbolNameContext, 80);

/// Symbol name -> *Namespace alias map.
pub const NsAliasMap = std.HashMapUnmanaged([]const u8, *Namespace, SymbolNameContext, 80);

/// Namespace — manages symbol-to-var mappings.
pub const Namespace = struct {
    /// Namespace name (e.g. "clojure.core", "user").
    name: []const u8,

    /// Allocator for Var creation and map storage.
    allocator: std.mem.Allocator,

    /// Vars defined in this namespace (symbol name -> *Var).
    mappings: VarMap = .empty,

    /// Aliases to other namespaces (alias name -> *Namespace).
    aliases: NsAliasMap = .empty,

    /// Vars referred from other namespaces (symbol name -> *Var).
    refers: VarMap = .empty,

    // === Init / Deinit ===

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Namespace {
        return .{
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Namespace) void {
        // Destroy Vars owned by this namespace.
        var iter = self.mappings.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.mappings.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
        self.refers.deinit(self.allocator);
    }

    // === Var operations ===

    /// Intern a Var in this namespace.
    /// Returns existing Var if already interned, or creates a new one.
    pub fn intern(self: *Namespace, sym_name: []const u8) !*Var {
        if (self.mappings.get(sym_name)) |existing| {
            return existing;
        }

        // Dupe the name to ensure key lifetime (input may be scratch-allocated).
        const owned_name = try self.allocator.dupe(u8, sym_name);
        const new_var = try self.allocator.create(Var);
        new_var.* = .{
            .sym = .{ .name = owned_name, .ns = null },
            .ns_name = self.name,
        };
        try self.mappings.put(self.allocator, owned_name, new_var);
        return new_var;
    }

    /// Refer a Var from another namespace into this one.
    pub fn refer(self: *Namespace, sym_name: []const u8, var_ref: *Var) !void {
        try self.refers.put(self.allocator, sym_name, var_ref);
    }

    /// Set an alias to another namespace.
    pub fn setAlias(self: *Namespace, alias_name: []const u8, ns: *Namespace) !void {
        try self.aliases.put(self.allocator, alias_name, ns);
    }

    /// Get an aliased namespace.
    pub fn getAlias(self: *const Namespace, alias_name: []const u8) ?*Namespace {
        return self.aliases.get(alias_name);
    }

    /// Resolve an unqualified symbol.
    /// Priority: local mappings > refers.
    pub fn resolve(self: *const Namespace, sym_name: []const u8) ?*Var {
        if (self.mappings.get(sym_name)) |v| return v;
        if (self.refers.get(sym_name)) |v| return v;
        return null;
    }

    /// Resolve a qualified symbol (ns_name/sym_name).
    pub fn resolveQualified(self: *const Namespace, ns_name: []const u8, sym_name: []const u8) ?*Var {
        // Own namespace: check mappings + refers (same as resolve)
        if (std.mem.eql(u8, ns_name, self.name)) {
            return self.resolve(sym_name);
        }
        // Alias
        if (self.aliases.get(ns_name)) |aliased_ns| {
            return aliased_ns.mappings.get(sym_name);
        }
        return null;
    }

    /// Remove a symbol mapping.
    pub fn unmap(self: *Namespace, sym_name: []const u8) void {
        _ = self.mappings.remove(sym_name);
    }

    /// Remove an alias.
    pub fn removeAlias(self: *Namespace, alias_name: []const u8) void {
        _ = self.aliases.remove(alias_name);
    }
};

// === Tests ===

test "Namespace intern" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ns = Namespace.init(allocator, "user");
    defer ns.deinit();

    const v1 = try ns.intern("foo");
    const v2 = try ns.intern("foo");

    // Same Var returned
    try std.testing.expectEqual(v1, v2);
    try std.testing.expectEqualStrings("foo", v1.sym.name);
    try std.testing.expectEqualStrings("user", v1.ns_name);
}

test "Namespace resolve" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ns = Namespace.init(allocator, "user");
    defer ns.deinit();

    const v = try ns.intern("bar");
    v.bindRoot(.{ .integer = 42 });

    const resolved = ns.resolve("bar");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 42 }));

    // Unknown symbol
    try std.testing.expect(ns.resolve("unknown") == null);
}

test "Namespace refer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var core = Namespace.init(allocator, "clojure.core");
    defer core.deinit();

    var user = Namespace.init(allocator, "user");
    defer user.deinit();

    // Define 'map' in core
    const map_var = try core.intern("map");
    map_var.bindRoot(.{ .integer = 999 });

    // Refer into user
    try user.refer("map", map_var);

    // Resolve finds the referred Var
    const resolved = user.resolve("map");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 999 }));
}

test "Namespace refer - local takes priority" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var core = Namespace.init(allocator, "clojure.core");
    defer core.deinit();

    var user = Namespace.init(allocator, "user");
    defer user.deinit();

    const core_map = try core.intern("map");
    core_map.bindRoot(.{ .integer = 1 });

    try user.refer("map", core_map);

    // Local definition shadows refer
    const user_map = try user.intern("map");
    user_map.bindRoot(.{ .integer = 2 });

    const resolved = user.resolve("map");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 2 }));
}

test "Namespace alias and resolveQualified" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var core = Namespace.init(allocator, "clojure.core");
    defer core.deinit();

    var user = Namespace.init(allocator, "user");
    defer user.deinit();

    const map_var = try core.intern("map");
    map_var.bindRoot(.{ .integer = 999 });

    try user.setAlias("core", &core);

    // Resolve via alias: core/map
    const resolved = user.resolveQualified("core", "map");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(.{ .integer = 999 }));

    // Resolve via own name
    const own_var = try user.intern("x");
    own_var.bindRoot(.{ .integer = 1 });
    const own_resolved = user.resolveQualified("user", "x");
    try std.testing.expect(own_resolved != null);
    try std.testing.expect(own_resolved.?.deref().eql(.{ .integer = 1 }));

    // Unknown namespace
    try std.testing.expect(user.resolveQualified("unknown", "x") == null);
}

test "Namespace unmap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ns = Namespace.init(allocator, "user");
    defer ns.deinit();

    _ = try ns.intern("foo");
    try std.testing.expect(ns.resolve("foo") != null);

    ns.unmap("foo");
    try std.testing.expect(ns.resolve("foo") == null);
}

test "Namespace removeAlias" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var core = Namespace.init(allocator, "clojure.core");
    defer core.deinit();

    var user = Namespace.init(allocator, "user");
    defer user.deinit();

    try user.setAlias("core", &core);
    try std.testing.expect(user.getAlias("core") != null);

    user.removeAlias("core");
    try std.testing.expect(user.getAlias("core") == null);
}
