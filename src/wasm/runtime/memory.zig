// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Wasm linear memory — page-based allocation with typed read/write.
//
// Each page is 64 KiB. Memory grows in page increments with optional max limit.
// All reads/writes are bounds-checked. Little-endian byte order per Wasm spec.

const std = @import("std");
const mem = std.mem;

pub const PAGE_SIZE: u32 = 64 * 1024; // 64 KiB
pub const MAX_PAGES: u32 = 64 * 1024; // 4 GiB theoretical max

pub const Memory = struct {
    alloc: mem.Allocator,
    min: u32,
    max: ?u32,
    data: std.ArrayList(u8),

    pub fn init(alloc: mem.Allocator, min: u32, max: ?u32) Memory {
        return .{
            .alloc = alloc,
            .min = min,
            .max = max,
            .data = .empty,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.data.deinit(self.alloc);
    }

    /// Allocate initial pages (called during instantiation).
    pub fn allocateInitial(self: *Memory) !void {
        if (self.min > 0) {
            _ = try self.grow(self.min);
        }
    }

    /// Current size in pages.
    pub fn size(self: *const Memory) u32 {
        return @truncate(self.data.items.len / PAGE_SIZE);
    }

    /// Current size in bytes.
    pub fn sizeBytes(self: *const Memory) u33 {
        return @truncate(self.data.items.len);
    }

    /// Grow memory by num_pages. Returns old size in pages, or error if exceeds max.
    pub fn grow(self: *Memory, num_pages: u32) !u32 {
        const effective_max = @min(self.max orelse MAX_PAGES, MAX_PAGES);
        if (self.size() + num_pages > effective_max)
            return error.OutOfBoundsMemoryAccess;

        const old_size = self.size();
        const old_bytes = self.data.items.len;
        const new_bytes = @as(usize, PAGE_SIZE) * num_pages;
        _ = try self.data.resize(self.alloc, old_bytes + new_bytes);
        @memset(self.data.items[old_bytes..][0..new_bytes], 0);
        return old_size;
    }

    /// Copy data into memory at the given address.
    pub fn copy(self: *Memory, address: u32, data: []const u8) !void {
        const end = @as(u64, address) + data.len;
        if (end > self.data.items.len) return error.OutOfBoundsMemoryAccess;
        mem.copyForwards(u8, self.data.items[address..][0..data.len], data);
    }

    /// Fill n bytes at dst_address with value. Bounds-checked.
    pub fn fill(self: *Memory, dst_address: u32, n: u32, value: u8) !void {
        const end = @as(u64, dst_address) + n;
        if (end > self.data.items.len) return error.OutOfBoundsMemoryAccess;
        @memset(self.data.items[dst_address..][0..n], value);
    }

    /// Copy n bytes from src to dst within this memory (overlap-safe).
    pub fn copyWithin(self: *Memory, dst: u32, src: u32, n: u32) !void {
        const dst_end = @as(u64, dst) + n;
        const src_end = @as(u64, src) + n;
        const len = self.data.items.len;
        if (dst_end > len or src_end > len) return error.OutOfBoundsMemoryAccess;

        const src_slice = self.data.items[src..][0..n];
        const dst_slice = self.data.items[dst..][0..n];
        if (dst <= src) {
            mem.copyForwards(u8, dst_slice, src_slice);
        } else {
            mem.copyBackwards(u8, dst_slice, src_slice);
        }
    }

    /// Read a typed value at offset + address (little-endian).
    pub fn read(self: *const Memory, comptime T: type, offset: u32, address: u32) !T {
        const effective = @as(u33, offset) + @as(u33, address);
        if (effective + @sizeOf(T) > self.data.items.len) return error.OutOfBoundsMemoryAccess;

        const ptr: *const [@sizeOf(T)]u8 = @ptrCast(&self.data.items[effective]);
        return switch (T) {
            u8, u16, u32, u64, i8, i16, i32, i64 => mem.readInt(T, ptr, .little),
            u128 => mem.readInt(u128, ptr, .little),
            f32 => @bitCast(mem.readInt(u32, @ptrCast(ptr), .little)),
            f64 => @bitCast(mem.readInt(u64, @ptrCast(ptr), .little)),
            else => @compileError("Memory.read: unsupported type " ++ @typeName(T)),
        };
    }

    /// Write a typed value at offset + address (little-endian).
    pub fn write(self: *Memory, comptime T: type, offset: u32, address: u32, value: T) !void {
        const effective = @as(u33, offset) + @as(u33, address);
        if (effective + @sizeOf(T) > self.data.items.len) return error.OutOfBoundsMemoryAccess;

        const ptr: *[@sizeOf(T)]u8 = @ptrCast(&self.data.items[effective]);
        switch (T) {
            u8, u16, u32, u64, i8, i16, i32, i64 => mem.writeInt(T, ptr, value, .little),
            u128 => mem.writeInt(u128, ptr, value, .little),
            f32 => mem.writeInt(u32, @ptrCast(ptr), @bitCast(value), .little),
            f64 => mem.writeInt(u64, @ptrCast(ptr), @bitCast(value), .little),
            else => @compileError("Memory.write: unsupported type " ++ @typeName(T)),
        }
    }

    /// Raw byte slice for direct access.
    pub fn memory(self: *Memory) []u8 {
        return self.data.items;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Memory — init and grow" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();

    try testing.expectEqual(@as(u32, 0), m.size());
    try testing.expectEqual(@as(u33, 0), m.sizeBytes());

    const old = try m.grow(1);
    try testing.expectEqual(@as(u32, 0), old);
    try testing.expectEqual(@as(u32, 1), m.size());
    try testing.expectEqual(@as(u33, PAGE_SIZE), m.sizeBytes());
}

test "Memory — allocateInitial" {
    var m = Memory.init(testing.allocator, 2, null);
    defer m.deinit();

    try m.allocateInitial();
    try testing.expectEqual(@as(u32, 2), m.size());
}

test "Memory — grow respects max" {
    var m = Memory.init(testing.allocator, 0, 2);
    defer m.deinit();

    _ = try m.grow(1);
    _ = try m.grow(1);
    try testing.expectError(error.OutOfBoundsMemoryAccess, m.grow(1));
    try testing.expectEqual(@as(u32, 2), m.size());
}

test "Memory — read/write u8" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try testing.expectEqual(@as(u8, 0), try m.read(u8, 0, 0));
    try m.write(u8, 0, 0, 42);
    try testing.expectEqual(@as(u8, 42), try m.read(u8, 0, 0));
}

test "Memory — read/write u32 little-endian" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.write(u32, 0, 100, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try m.read(u32, 0, 100));

    // Verify little-endian byte order
    try testing.expectEqual(@as(u8, 0xEF), try m.read(u8, 0, 100));
    try testing.expectEqual(@as(u8, 0xBE), try m.read(u8, 0, 101));
    try testing.expectEqual(@as(u8, 0xAD), try m.read(u8, 0, 102));
    try testing.expectEqual(@as(u8, 0xDE), try m.read(u8, 0, 103));
}

test "Memory — read/write with offset" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.write(u32, 4, 100, 0x12345678);
    try testing.expectEqual(@as(u32, 0x12345678), try m.read(u32, 4, 100));
    // Same as reading at address 104 with offset 0
    try testing.expectEqual(@as(u32, 0x12345678), try m.read(u32, 0, 104));
}

test "Memory — read/write f32 and f64" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.write(f32, 0, 0, 3.14);
    try testing.expectApproxEqAbs(@as(f32, 3.14), try m.read(f32, 0, 0), 0.001);

    try m.write(f64, 0, 8, 2.718281828);
    try testing.expectApproxEqAbs(@as(f64, 2.718281828), try m.read(f64, 0, 8), 0.000001);
}

test "Memory — bounds checking" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    // Last valid byte
    try m.write(u8, 0, PAGE_SIZE - 1, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), try m.read(u8, 0, PAGE_SIZE - 1));

    // Out of bounds
    try testing.expectError(error.OutOfBoundsMemoryAccess, m.read(u8, 0, PAGE_SIZE));
    try testing.expectError(error.OutOfBoundsMemoryAccess, m.write(u8, 0, PAGE_SIZE, 0));

    // u16 at last byte overflows
    try testing.expectError(error.OutOfBoundsMemoryAccess, m.read(u16, 0, PAGE_SIZE - 1));
}

test "Memory — copy" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.copy(0, "Hello");
    try testing.expectEqual(@as(u8, 'H'), try m.read(u8, 0, 0));
    try testing.expectEqual(@as(u8, 'o'), try m.read(u8, 0, 4));
}

test "Memory — copy out of bounds" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try testing.expectError(error.OutOfBoundsMemoryAccess, m.copy(PAGE_SIZE - 2, "ABC"));
}

test "Memory — fill" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.fill(10, 5, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), try m.read(u8, 0, 10));
    try testing.expectEqual(@as(u8, 0xAA), try m.read(u8, 0, 14));
    try testing.expectEqual(@as(u8, 0x00), try m.read(u8, 0, 15));
}

test "Memory — copyWithin non-overlapping" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.copy(0, "ABCD");
    try m.copyWithin(100, 0, 4);
    try testing.expectEqual(@as(u8, 'A'), try m.read(u8, 0, 100));
    try testing.expectEqual(@as(u8, 'D'), try m.read(u8, 0, 103));
}

test "Memory — copyWithin overlapping forward" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    try m.copy(0, "ABCDEF");
    try m.copyWithin(2, 0, 4); // copy "ABCD" to offset 2
    try testing.expectEqual(@as(u8, 'A'), try m.read(u8, 0, 0));
    try testing.expectEqual(@as(u8, 'B'), try m.read(u8, 0, 1));
    try testing.expectEqual(@as(u8, 'A'), try m.read(u8, 0, 2));
    try testing.expectEqual(@as(u8, 'B'), try m.read(u8, 0, 3));
    try testing.expectEqual(@as(u8, 'C'), try m.read(u8, 0, 4));
    try testing.expectEqual(@as(u8, 'D'), try m.read(u8, 0, 5));
}

test "Memory — cross-page write" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(2);

    try m.write(u16, 0, PAGE_SIZE - 1, 0xDEAD);
    try testing.expectEqual(@as(u16, 0xDEAD), try m.read(u16, 0, PAGE_SIZE - 1));
}

test "Memory — raw memory access" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();
    _ = try m.grow(1);

    const slice = m.memory();
    try testing.expectEqual(@as(usize, PAGE_SIZE), slice.len);
    slice[0] = 0xFF;
    try testing.expectEqual(@as(u8, 0xFF), try m.read(u8, 0, 0));
}

test "Memory — zero pages" {
    var m = Memory.init(testing.allocator, 0, null);
    defer m.deinit();

    try testing.expectEqual(@as(u32, 0), m.size());
    try testing.expectEqual(@as(usize, 0), m.memory().len);
    try testing.expectError(error.OutOfBoundsMemoryAccess, m.read(u8, 0, 0));
}
