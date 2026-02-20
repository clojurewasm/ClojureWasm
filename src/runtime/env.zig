// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Env — runtime environment.
//!
//! Owns the Namespace registry.
//! Each VM instance holds its own Env.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ns_mod = @import("namespace.zig");
const Namespace = ns_mod.Namespace;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Symbol = value_mod.Symbol;

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
    namespaces: NsMap = .empty,

    /// Current namespace (set during evaluation).
    current_ns: ?*Namespace = null,

    /// GC instance pointer (opaque to avoid circular import with gc.zig).
    /// Set by main.zig after bootstrap. VM and TreeWalk cast to *MarkSweepGc.
    gc: ?*anyopaque = null,

    /// Arena for AST node allocations (reader/analyzer output).
    /// Backed by env.allocator (GPA). Not tracked by GC — persists for
    /// program lifetime. Prevents GC from sweeping AST Nodes that TreeWalk
    /// closures reference during evaluation (D70).
    node_arena: std.heap.ArenaAllocator,

    /// GPA-allocated heap Symbols from bootstrap (registry + syncNsVar).
    /// Freed in deinit to avoid GPA leak reports.
    owned_symbols: [16]*const Symbol = undefined,
    owned_symbol_count: usize = 0,

    pub fn init(allocator: Allocator) Env {
        return .{ .allocator = allocator, .node_arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Env) void {
        var iter = self.namespaces.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*); // owned_name from findOrCreateNamespace()
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.namespaces.deinit(self.allocator);
        self.node_arena.deinit();
        // Free bootstrap Symbols allocated via GPA
        for (self.owned_symbols[0..self.owned_symbol_count]) |sym| {
            self.allocator.destroy(sym);
        }
    }

    /// Track a GPA-allocated Symbol for cleanup at deinit.
    pub fn trackOwnedSymbol(self: *Env, val: Value) void {
        if (val.tag() != .symbol) return;
        if (self.owned_symbol_count >= 16) return;
        self.owned_symbols[self.owned_symbol_count] = val.asSymbolHeap();
        self.owned_symbol_count += 1;
    }

    /// Replace a tracked Symbol (for syncNsVar which rebinds *ns*).
    /// Frees the old Symbol and tracks the new one.
    pub fn replaceOwnedSymbol(self: *Env, old_val: Value, new_val: Value) void {
        if (old_val.tag() == .symbol) {
            const old_ptr = old_val.asSymbolHeap();
            // Remove old from tracking
            for (self.owned_symbols[0..self.owned_symbol_count], 0..) |sym, i| {
                if (sym == old_ptr) {
                    self.allocator.destroy(old_ptr);
                    self.owned_symbols[i] = self.owned_symbols[self.owned_symbol_count - 1];
                    self.owned_symbol_count -= 1;
                    break;
                }
            }
        }
        self.trackOwnedSymbol(new_val);
    }

    /// Allocator for reader/analyzer output (AST Nodes, Forms).
    /// Not tracked by GC — Nodes persist for closure lifetime.
    pub fn nodeAllocator(self: *Env) Allocator {
        return self.node_arena.allocator();
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

    /// Register an alias name that points to an existing namespace.
    /// Used for cljw.xxx → clojure.java.xxx aliases (F141).
    pub fn registerNamespaceAlias(self: *Env, alias_name: []const u8, target: *Namespace) !void {
        if (self.namespaces.get(alias_name) != null) return; // already exists
        const owned_name = try self.allocator.dupe(u8, alias_name);
        try self.namespaces.put(self.allocator, owned_name, target);
    }

    /// Remove a namespace by name. Returns the removed namespace, or null.
    pub fn removeNamespace(self: *Env, name: []const u8) ?*Namespace {
        if (self.namespaces.fetchRemove(name)) |kv| {
            // Clean up the removed namespace's resources
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
            return null;
        }
        return null;
    }

    /// Create a lightweight thread-local clone of this Env.
    ///
    /// Shares the namespace HashMap backing storage (read-only access)
    /// but has its own current_ns, node_arena, and gc pointer.
    /// Used by thread pool workers to evaluate Clojure in parallel.
    /// The clone does NOT own the namespace data — deinit is a no-op
    /// for shared resources.
    pub fn threadClone(self: *const Env) Env {
        return .{
            .allocator = self.allocator,
            .namespaces = self.namespaces,
            .current_ns = self.current_ns,
            .gc = self.gc,
            .node_arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }
};

// === Tests ===

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
    v.bindRoot(Value.initInteger(42));

    // Resolve through namespace
    const resolved = ns.resolve("foo");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(Value.initInteger(42)));
}

test "Env multiple namespaces with refer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    const core = try env.findOrCreateNamespace("clojure.core");
    const user = try env.findOrCreateNamespace("user");

    const plus_var = try core.intern("+");
    plus_var.bindRoot(Value.initInteger(1));

    try user.refer("+", plus_var);

    const resolved = user.resolve("+");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(Value.initInteger(1)));
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
