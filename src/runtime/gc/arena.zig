//! Arena GC interface for ClojureWasm runtime.
//!
//! Phase 1 uses arena-only allocation: objects are allocated but never
//! individually freed. The entire arena is released at once via `deinit()`.
//! Mark-Sweep GC is added in Phase 5 (gc/mark_sweep.zig).
//!
//! Day-1 provisions for future phases:
//! - `gc_mutex`: Thread.Mutex for concurrent GC (unused until Phase 15)
//! - `suppress_count`: Nestable GC suppression (for macro expansion)
//! - `gc_stress`: Comptime flag for aggressive GC testing

const std = @import("std");

/// Comptime flag for GC stress testing. When true, collection is triggered
/// on every allocation (Phase 5+). Controlled via build option.
pub const gc_stress = false;

/// GC allocation statistics.
pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

/// Arena-based GC. Allocates from a contiguous arena; no individual free.
/// The entire arena is released via `deinit()`.
pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,

    /// Mutex for thread-safe allocation (Day 1 provision, unused until Phase 15).
    gc_mutex: std.Thread.Mutex = .{},

    /// Nestable GC suppression counter. When > 0, collection is skipped.
    /// Used during macro expansion to prevent collecting intermediate values.
    suppress_count: u32 = 0,

    /// Allocation statistics for profiling.
    stats: Stats = .{},

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *ArenaGc) void {
        self.arena.deinit();
    }

    /// Returns a std.mem.Allocator that tracks allocation statistics.
    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Suppress GC collection (nestable).
    pub fn suppressCollection(self: *ArenaGc) void {
        self.suppress_count += 1;
    }

    /// Unsuppress GC collection (nestable).
    pub fn unsuppressCollection(self: *ArenaGc) void {
        std.debug.assert(self.suppress_count > 0);
        self.suppress_count -= 1;
    }

    /// Whether collection is currently suppressed.
    pub fn isSuppressed(self: *const ArenaGc) bool {
        return self.suppress_count > 0;
    }

    /// Reset the arena, freeing all allocated memory.
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
        self.gc_mutex.lock();
        defer self.gc_mutex.unlock();

        const result = self.arena.allocator().rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.stats.bytes_allocated += len;
            self.stats.alloc_count += 1;
        }
        return result;
    }

    fn arenaResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        self.gc_mutex.lock();
        defer self.gc_mutex.unlock();

        const result = self.arena.allocator().rawResize(memory, alignment, new_len, ret_addr);
        if (result) {
            if (new_len > memory.len) {
                self.stats.bytes_allocated += new_len - memory.len;
            }
        }
        return result;
    }

    fn arenaRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        self.gc_mutex.lock();
        defer self.gc_mutex.unlock();

        const result = self.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > memory.len) {
                self.stats.bytes_allocated += new_len - memory.len;
            }
        }
        return result;
    }

    fn arenaFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        self.gc_mutex.lock();
        defer self.gc_mutex.unlock();

        // Arena doesn't individually free, but delegate anyway
        self.arena.allocator().rawFree(memory, alignment, ret_addr);
    }
};

// --- Tests ---

const testing = std.testing;

test "ArenaGc init/deinit" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
}

test "ArenaGc allocate and track stats" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    // Allocate a slice
    const data = try alloc.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), data.len);
    try testing.expect(gc.stats.bytes_allocated >= 64);
    try testing.expect(gc.stats.alloc_count >= 1);

    // Allocate another
    const count_before = gc.stats.alloc_count;
    const data2 = try alloc.alloc(u64, 8);
    try testing.expectEqual(@as(usize, 8), data2.len);
    try testing.expect(gc.stats.alloc_count > count_before);
}

test "ArenaGc suppress/unsuppress" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    try testing.expect(!gc.isSuppressed());

    gc.suppressCollection();
    try testing.expect(gc.isSuppressed());

    // Nested suppression
    gc.suppressCollection();
    try testing.expect(gc.isSuppressed());

    gc.unsuppressCollection();
    try testing.expect(gc.isSuppressed()); // still suppressed

    gc.unsuppressCollection();
    try testing.expect(!gc.isSuppressed()); // now unsuppressed
}

test "ArenaGc reset clears stats" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    const alloc = gc.allocator();
    _ = try alloc.alloc(u8, 128);
    try testing.expect(gc.stats.bytes_allocated > 0);

    gc.reset();
    try testing.expectEqual(@as(usize, 0), gc.stats.bytes_allocated);
    try testing.expectEqual(@as(u64, 0), gc.stats.alloc_count);
}

test "ArenaGc multiple allocations" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    // Allocate various types
    const ints = try alloc.alloc(i64, 16);
    try testing.expectEqual(@as(usize, 16), ints.len);

    const bytes = try alloc.alloc(u8, 256);
    try testing.expectEqual(@as(usize, 256), bytes.len);

    // Write and verify
    ints[0] = 42;
    ints[15] = -1;
    try testing.expectEqual(@as(i64, 42), ints[0]);
    try testing.expectEqual(@as(i64, -1), ints[15]);

    bytes[0] = 0xAB;
    bytes[255] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), bytes[0]);
    try testing.expectEqual(@as(u8, 0xCD), bytes[255]);
}

test "gc_stress flag exists" {
    // Just verify the comptime flag is accessible
    try testing.expect(!gc_stress);
}
