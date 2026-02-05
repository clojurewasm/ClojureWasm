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

/// Mark-sweep GC — tracks allocations, marks live objects, sweeps dead ones.
///
/// Wraps a backing allocator: every allocation is tracked in a HashMap.
/// Mark phase: callers mark live pointers via markPtr().
/// Sweep phase: all unmarked allocations are freed through the backing allocator.
pub const MarkSweepGc = struct {
    backing: std.mem.Allocator,
    allocations: std.AutoArrayHashMapUnmanaged(usize, AllocInfo) = .empty,
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
    collect_count: u64 = 0,
    threshold: usize = 1024 * 1024, // 1MB default

    pub const AllocInfo = struct {
        len: usize,
        alignment: Alignment,
        marked: bool,
    };

    const allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = &msAlloc,
        .resize = &msResize,
        .remap = &msRemap,
        .free = &msFree,
    };

    const gc_vtable: GcStrategy.VTable = .{
        .alloc = &gcAlloc,
        .collect = &gcCollect,
        .shouldCollect = &gcShouldCollect,
        .stats = &gcStats,
    };

    pub fn init(backing: std.mem.Allocator) MarkSweepGc {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *MarkSweepGc) void {
        // Free all tracked allocations through backing
        const keys = self.allocations.keys();
        const vals = self.allocations.values();
        for (keys, vals) |addr, info| {
            const ptr: [*]u8 = @ptrFromInt(addr);
            self.backing.rawFree(ptr[0..info.len], info.alignment, 0);
        }
        self.allocations.deinit(self.backing);
    }

    /// Returns a std.mem.Allocator that tracks all allocations through this GC.
    pub fn allocator(self: *MarkSweepGc) std.mem.Allocator {
        return .{ .ptr = @ptrCast(self), .vtable = &allocator_vtable };
    }

    /// Returns GcStrategy fat pointer for this instance.
    pub fn strategy(self: *MarkSweepGc) GcStrategy {
        return .{ .ptr = @ptrCast(self), .vtable = &gc_vtable };
    }

    /// Mark a pointer as live. The pointer must have been allocated through this GC.
    pub fn markPtr(self: *MarkSweepGc, ptr: anytype) void {
        const addr = @intFromPtr(ptr);
        if (self.allocations.getPtr(addr)) |info| {
            info.marked = true;
        }
    }

    /// Sweep all unmarked allocations, freeing their memory.
    /// Marked allocations have their mark bit reset for the next cycle.
    pub fn sweep(self: *MarkSweepGc) void {
        var freed_bytes: usize = 0;
        var freed_count: u64 = 0;
        var i: usize = 0;
        while (i < self.allocations.count()) {
            const vals = self.allocations.values();
            if (!vals[i].marked) {
                const keys = self.allocations.keys();
                const addr = keys[i];
                const info = vals[i];
                const ptr: [*]u8 = @ptrFromInt(addr);
                self.backing.rawFree(ptr[0..info.len], info.alignment, 0);
                freed_bytes += info.len;
                freed_count += 1;
                self.allocations.swapRemoveAt(i);
                // Don't increment — swapRemove moved last element to i
            } else {
                self.allocations.values()[i].marked = false;
                i += 1;
            }
        }
        self.bytes_allocated -|= freed_bytes;
        self.alloc_count -|= freed_count;
        self.collect_count += 1;
    }

    /// Return the number of currently tracked (live) allocations.
    pub fn liveCount(self: *const MarkSweepGc) usize {
        return self.allocations.count();
    }

    // --- std.mem.Allocator VTable implementations ---

    fn msAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations.put(self.backing, @intFromPtr(result), .{
            .len = len,
            .alignment = alignment,
            .marked = false,
        }) catch {
            // Failed to track — free the allocation and return null
            self.backing.rawFree(result[0..len], alignment, 0);
            return null;
        };
        self.bytes_allocated += len;
        self.alloc_count += 1;
        return result;
    }

    fn msResize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        if (self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            const addr = @intFromPtr(memory.ptr);
            if (self.allocations.getPtr(addr)) |info| {
                self.bytes_allocated = self.bytes_allocated - info.len + new_len;
                info.len = new_len;
            }
            return true;
        }
        return false;
    }

    fn msRemap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        const old_addr = @intFromPtr(memory.ptr);
        const new_addr = @intFromPtr(result);
        if (old_addr == new_addr) {
            if (self.allocations.getPtr(old_addr)) |info| {
                self.bytes_allocated = self.bytes_allocated - info.len + new_len;
                info.len = new_len;
            }
        } else {
            // Address changed — remove old entry, add new
            if (self.allocations.get(old_addr)) |old_info| {
                self.bytes_allocated -|= old_info.len;
                self.alloc_count -|= 1;
                _ = self.allocations.swapRemove(old_addr);
            }
            self.allocations.put(self.backing, new_addr, .{
                .len = new_len,
                .alignment = alignment,
                .marked = false,
            }) catch return null;
            self.bytes_allocated += new_len;
            self.alloc_count += 1;
        }
        return result;
    }

    fn msFree(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        const addr = @intFromPtr(memory.ptr);
        if (self.allocations.get(addr)) |info| {
            self.bytes_allocated -|= info.len;
            self.alloc_count -|= 1;
            _ = self.allocations.swapRemove(addr);
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    // --- GcStrategy VTable implementations ---

    fn gcAlloc(ptr: *anyopaque, size: usize, alignment: Alignment) ?[*]u8 {
        return msAlloc(ptr, size, alignment, 0);
    }

    fn gcCollect(ptr: *anyopaque, _: RootSet) void {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        self.sweep();
    }

    fn gcShouldCollect(ptr: *anyopaque) bool {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
        return self.bytes_allocated >= self.threshold;
    }

    fn gcStats(ptr: *anyopaque) Stats {
        const self: *MarkSweepGc = @ptrCast(@alignCast(ptr));
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

// === MarkSweepGc Tests ===

test "MarkSweepGc init creates valid instance" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const s = gc.strategy().stats();
    try std.testing.expectEqual(@as(usize, 0), s.bytes_allocated);
    try std.testing.expectEqual(@as(u64, 0), s.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
}

test "MarkSweepGc allocator returns usable std.mem.Allocator" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const slice = try a.alloc(u8, 128);
    @memset(slice, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), slice[127]);
}

test "MarkSweepGc tracks allocations" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);

    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
    try std.testing.expect(gc.bytes_allocated > 0);
    try std.testing.expectEqual(@as(u64, 2), gc.alloc_count);
}

test "MarkSweepGc sweep frees unmarked allocations" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const p1 = try a.create(u64);
    _ = try a.create(u64); // p2 — not marked

    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());

    gc.markPtr(p1);
    gc.sweep();

    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 1), gc.collect_count);
}

test "MarkSweepGc sweep frees all when nothing marked" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);
    _ = try a.create(u64);

    gc.sweep();

    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), gc.bytes_allocated);
}

test "MarkSweepGc free removes from tracking" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    const p1 = try a.create(u64);
    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());

    a.destroy(p1);
    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
}

test "MarkSweepGc multiple collect cycles" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();

    // Cycle 1: allocate 3, keep 1
    const p1 = try a.create(u64);
    _ = try a.create(u64);
    _ = try a.create(u64);
    gc.markPtr(p1);
    gc.sweep();
    try std.testing.expectEqual(@as(usize, 1), gc.liveCount());

    // Cycle 2: allocate 2 more, keep p1 + p4
    const p4 = try a.create(u64);
    _ = try a.create(u64);
    gc.markPtr(p1);
    gc.markPtr(p4);
    gc.sweep();
    try std.testing.expectEqual(@as(usize, 2), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 2), gc.collect_count);
}

test "MarkSweepGc shouldCollect respects threshold" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    gc.threshold = 64;

    try std.testing.expect(!gc.strategy().shouldCollect());

    const a = gc.allocator();
    _ = try a.alloc(u8, 128);

    try std.testing.expect(gc.strategy().shouldCollect());
}

test "MarkSweepGc strategy vtable alloc works" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const strat = gc.strategy();
    const p = strat.alloc(64, .@"1");
    try std.testing.expect(p != null);

    const s = strat.stats();
    try std.testing.expect(s.bytes_allocated >= 64);
    try std.testing.expectEqual(@as(u64, 1), s.alloc_count);
}

test "MarkSweepGc strategy collect triggers sweep" {
    var gc = MarkSweepGc.init(std.testing.allocator);
    defer gc.deinit();

    const a = gc.allocator();
    _ = try a.create(u64);
    _ = try a.create(u64);

    gc.strategy().collect(.{});

    try std.testing.expectEqual(@as(usize, 0), gc.liveCount());
    try std.testing.expectEqual(@as(u64, 1), gc.collect_count);
}
