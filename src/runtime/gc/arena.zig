//! Arena GC for Phase 1.
//!
//! Phase 1 allocates from a contiguous arena and never individually
//! frees. The whole arena is released at once via `deinit()`. Phase 5
//! adds mark-sweep GC alongside this (`runtime/gc/mark_sweep.zig`).
//!
//! Day-1 provisions for later phases:
//!   - `suppress_count`: nestable GC suppression, used during macro
//!     expansion so intermediate values aren't collected mid-flight.
//!   - `gc_stress`: comptime flag for collect-on-every-alloc stress
//!     mode (Phase 5+; flipped via build option later).
//!
//! Thread-safety: the allocator vtable is **not** thread-safe. Phase 1
//! is single-threaded so this is fine. `std.Thread.Mutex` is gone in
//! Zig 0.16, and `std.Io.Mutex.lock` requires an `Io` argument that
//! `std.mem.Allocator.VTable` callbacks cannot accept (their signatures
//! are fixed). A different lock strategy must land before Phase 15.

const std = @import("std");

/// Comptime flag for collect-on-every-alloc stress mode (Phase 5+).
/// Wired to a build option once mark-sweep lands.
pub const gc_stress = false;

/// Allocation statistics for profiling and tests.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

/// Arena-based GC. Allocates from a backing arena; no individual free.
pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,

    /// Nestable GC suppression counter. While > 0, collection is skipped.
    /// Macro expansion relies on this to keep intermediate values alive.
    suppress_count: u32 = 0,

    /// Allocation statistics for profiling.
    stats: Stats = .{},

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *ArenaGc) void {
        self.arena.deinit();
    }

    /// Stats-tracking `std.mem.Allocator` view of this arena.
    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Suppress collection (nestable; pair each call with `unsuppressCollection`).
    pub fn suppressCollection(self: *ArenaGc) void {
        self.suppress_count += 1;
    }

    /// Pop one level of suppression.
    pub fn unsuppressCollection(self: *ArenaGc) void {
        std.debug.assert(self.suppress_count > 0);
        self.suppress_count -= 1;
    }

    pub fn isSuppressed(self: *const ArenaGc) bool {
        return self.suppress_count > 0;
    }

    /// Free everything allocated so far and reset stats.
    pub fn reset(self: *ArenaGc) void {
        _ = self.arena.reset(.free_all);
        self.stats = .{};
    }

    // --- std.mem.Allocator vtable ---

    const vtable = std.mem.Allocator.VTable{
        .alloc = arenaAlloc,
        .resize = arenaResize,
        .remap = arenaRemap,
        .free = arenaFree,
    };

    fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        const result = self.arena.allocator().rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.stats.bytes_allocated += len;
            self.stats.alloc_count += 1;
        }
        return result;
    }

    fn arenaResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        const result = self.arena.allocator().rawResize(memory, alignment, new_len, ret_addr);
        if (result and new_len > memory.len) {
            self.stats.bytes_allocated += new_len - memory.len;
        }
        return result;
    }

    fn arenaRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        const result = self.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) {
            self.stats.bytes_allocated += new_len - memory.len;
        }
        return result;
    }

    fn arenaFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        // Arena doesn't free per-allocation; delegate anyway in case the
        // backing allocator wants to know.
        self.arena.allocator().rawFree(memory, alignment, ret_addr);
    }
};

// --- tests ---

const testing = std.testing;

test "ArenaGc init / deinit zeroes stats" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
}

test "ArenaGc tracks allocations via stats" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    const data = try alloc.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), data.len);
    try testing.expect(gc.stats.bytes_allocated >= 64);
    try testing.expect(gc.stats.alloc_count >= 1);

    const before = gc.stats.alloc_count;
    const data2 = try alloc.alloc(u64, 8);
    try testing.expectEqual(@as(usize, 8), data2.len);
    try testing.expect(gc.stats.alloc_count > before);
}

test "ArenaGc suppression nests" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    try testing.expect(!gc.isSuppressed());

    gc.suppressCollection();
    gc.suppressCollection();
    try testing.expect(gc.isSuppressed());

    gc.unsuppressCollection();
    try testing.expect(gc.isSuppressed());

    gc.unsuppressCollection();
    try testing.expect(!gc.isSuppressed());
}

test "ArenaGc reset clears arena and stats" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    _ = try alloc.alloc(u8, 128);
    try testing.expect(gc.stats.bytes_allocated > 0);

    gc.reset();
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
}

test "ArenaGc allocations remain valid until deinit" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    const ints = try alloc.alloc(i64, 16);
    ints[0] = 42;
    ints[15] = -1;

    const bytes = try alloc.alloc(u8, 256);
    bytes[0] = 0xAB;
    bytes[255] = 0xCD;

    try testing.expectEqual(@as(i64, 42), ints[0]);
    try testing.expectEqual(@as(i64, -1), ints[15]);
    try testing.expectEqual(@as(u8, 0xAB), bytes[0]);
    try testing.expectEqual(@as(u8, 0xCD), bytes[255]);
}

test "gc_stress flag is accessible" {
    try testing.expect(!gc_stress);
}
