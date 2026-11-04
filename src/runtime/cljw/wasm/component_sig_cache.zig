// SPDX-License-Identifier: EPL-2.0
//! Per-handle export-signature cache for `wasm/component-call`
//! (CLJW-COMPONENT-CALL-CACHE). The component analogue of the core
//! `Loaded.sig_cache` (engine.zig).
//!
//! Without it every `component-call` built a fresh arena, walked the export
//! table by name (`exportedFuncIndex`, a `mem.eql` scan) and re-resolved the
//! whole `WitType` tree (`resolveFuncSig`) before lowering a single argument.
//! A resolved `FuncSig` depends only on the component's immutable `TypeInfo`,
//! so it is resolved once per (handle, export name) and kept for the handle's
//! lifetime. Its trees live in one arena owned by the cache; label and field
//! names borrow from the `Opened`'s `TypeInfo`, which outlives the cache
//! (the box tears the cache down before the `Opened`).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/component-call

const std = @import("std");
const zwasm = @import("zwasm");

const comp = zwasm.feature.component.host;
pub const FuncSig = comp.FuncSig;

pub const SigCache = struct {
    /// Owns every cached `FuncSig` tree and every key.
    arena: std.heap.ArenaAllocator,
    /// Export name -> resolved signature. A name that does not resolve is
    /// not cached, so a missing export keeps raising on every call.
    map: std.StringHashMapUnmanaged(FuncSig) = .empty,

    pub fn init(gpa: std.mem.Allocator) SigCache {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *SigCache) void {
        // Keys and map storage both live in the arena.
        self.arena.deinit();
    }

    /// The signature of export `name` on `opened`, resolving it on first use.
    /// `null` when the name does not resolve to a concrete func (or its
    /// signature holds an unsupported type) — the caller raises not-found,
    /// exactly as the uncached path did.
    pub fn get(self: *SigCache, opened: *const comp.Opened, name: []const u8) std.mem.Allocator.Error!?FuncSig {
        if (self.map.get(name)) |sig| return sig;
        const a = self.arena.allocator();
        // Same `catch null` as the uncached path: a resolve failure reads as
        // export-not-found.
        const sig = (opened.resolveFuncSig(a, name) catch null) orelse return null;
        // The caller's `name` is a GC string: the key must be an owned copy.
        const key = try a.dupe(u8, name);
        try self.map.put(a, key, sig);
        return sig;
    }

    pub fn count(self: *const SigCache) usize {
        return self.map.count();
    }
};

test "an empty cache tears down cleanly" {
    var c = SigCache.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.count());
}
