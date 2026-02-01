// GcStrategy — vtable-based GC abstraction (SS5).
//
// Provides a trait interface for garbage collection strategies.
// Initial implementation: ArenaGc (arena allocator, no-op collect).

const std = @import("std");
const Alignment = std.mem.Alignment;

/// Placeholder for GC root set. Will be populated when VM stack
/// walking is implemented (Task 2.7+).
pub const RootSet = struct {};

/// GC allocation statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

/// Vtable-based GC strategy trait.
///
/// Follows the Zig fat-pointer idiom (same pattern as std.mem.Allocator):
/// a type-erased pointer + vtable of function pointers.
pub const GcStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8,
        collect: *const fn (ptr: *anyopaque, roots: RootSet) void,
        shouldCollect: *const fn (ptr: *anyopaque) bool,
        stats: *const fn (ptr: *anyopaque) Stats,
    };

    pub fn alloc(self: GcStrategy, size: usize, alignment: Alignment) ?[*]u8 {
        return self.vtable.alloc(self.ptr, size, alignment);
    }

    pub fn collect(self: GcStrategy, roots: RootSet) void {
        self.vtable.collect(self.ptr, roots);
    }

    pub fn shouldCollect(self: GcStrategy) bool {
        return self.vtable.shouldCollect(self.ptr);
    }

    pub fn stats(self: GcStrategy) Stats {
        return self.vtable.stats(self.ptr);
    }
};

/// Arena-based GC stub — wraps ArenaAllocator with no-op collect.
///
/// This is the initial GC strategy: all allocations go through an arena,
/// and collection is deferred (no-op). The arena frees everything on deinit.
pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,

    const vtable: GcStrategy.VTable = .{
        .alloc = &arenaAlloc,
        .collect = &arenaCollect,
        .shouldCollect = &arenaShouldCollect,
        .stats = &arenaStats,
    };

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *ArenaGc) void {
        self.arena.deinit();
    }

    /// Returns GcStrategy fat pointer for this instance.
    pub fn strategy(self: *ArenaGc) GcStrategy {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Returns a std.mem.Allocator backed by this ArenaGc.
    /// Useful for Zig stdlib compatibility (ArrayList, HashMap, etc.).
    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn arenaAlloc(ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ptr));
        const result = self.arena.allocator().rawAlloc(size, alignment, @returnAddress()) orelse return null;
        self.bytes_allocated += size;
        self.alloc_count += 1;
        return result;
    }

    fn arenaCollect(_: *anyopaque, _: RootSet) void {
        // No-op: arena frees everything on deinit.
    }

    fn arenaShouldCollect(_: *anyopaque) bool {
        return false;
    }

    fn arenaStats(ptr: *anyopaque) Stats {
        const self: *ArenaGc = @ptrCast(@alignCast(ptr));
        return .{
            .bytes_allocated = self.bytes_allocated,
            .alloc_count = self.alloc_count,
        };
    }
};

// === Tests ===

test "ArenaGc init creates valid instance" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const s = gc.strategy().stats();
    try std.testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), s.alloc_count);
}

test "ArenaGc alloc returns non-null pointer" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const ptr = gc.strategy().alloc(64, .@"1");
    try std.testing.expect(ptr != null);
}

test "ArenaGc shouldCollect returns false" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    try std.testing.expect(!gc.strategy().shouldCollect());
}

test "ArenaGc collect is no-op" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    // Should not crash
    gc.strategy().collect(.{});
}

test "ArenaGc stats tracks allocation count" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();
    _ = strat.alloc(32, .@"1");
    _ = strat.alloc(64, .@"1");

    const s = strat.stats();
    try std.testing.expectEqual(@as(u64, 2), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 96), s.bytes_allocated);
}

test "ArenaGc allocator returns usable std.mem.Allocator" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    // Should be able to allocate and use memory through std.mem.Allocator
    const slice = try alloc.alloc(u8, 128);
    @memset(slice, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[127]);
}

test "Multiple allocations tracked correctly" {
    var gc = ArenaGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();

    // Allocate various sizes
    _ = strat.alloc(8, .@"1");
    _ = strat.alloc(16, .@"1");
    _ = strat.alloc(32, .@"1");
    _ = strat.alloc(64, .@"1");

    const s = strat.stats();
    try std.testing.expectEqual(@as(u64, 4), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 120), s.bytes_allocated);
}
