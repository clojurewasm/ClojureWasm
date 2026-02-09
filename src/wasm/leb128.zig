// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! LEB128 variable-length integer decoding for Wasm binary format.
//!
//! Thin wrapper over std.leb that operates on byte slices with a position
//! cursor, matching the pattern used by the Wasm module decoder.

const std = @import("std");

pub const Error = error{ Overflow, EndOfStream };

/// A cursor into a byte slice for sequential LEB128 reads.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .pos = 0 };
    }

    /// Read an unsigned LEB128-encoded u32.
    pub fn readU32(self: *Reader) Error!u32 {
        return readUnsigned(u32, self);
    }

    /// Read a signed LEB128-encoded i32.
    pub fn readI32(self: *Reader) Error!i32 {
        return readSigned(i32, self);
    }

    /// Read an unsigned LEB128-encoded u64.
    pub fn readU64(self: *Reader) Error!u64 {
        return readUnsigned(u64, self);
    }

    /// Read a signed LEB128-encoded i64.
    pub fn readI64(self: *Reader) Error!i64 {
        return readSigned(i64, self);
    }

    /// Read a signed 33-bit integer (used for block types in Wasm).
    /// Encoded as signed LEB128, but we read as i64 and check range.
    pub fn readI33(self: *Reader) Error!i64 {
        const val = try readSigned(i64, self);
        if (val < -@as(i64, 1) << 32 or val >= @as(i64, 1) << 32) return error.Overflow;
        return val;
    }

    /// Read a single byte (for fixed-width fields like section IDs).
    pub fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return error.EndOfStream;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    /// Read a fixed-size slice of bytes.
    pub fn readBytes(self: *Reader, len: usize) Error![]const u8 {
        if (self.pos + len > self.bytes.len) return error.EndOfStream;
        const slice = self.bytes[self.pos..][0..len];
        self.pos += len;
        return slice;
    }

    /// Read a 32-bit float (little-endian, 4 bytes).
    pub fn readF32(self: *Reader) Error!f32 {
        const bytes = try self.readBytes(4);
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    /// Read a 64-bit float (little-endian, 8 bytes).
    pub fn readF64(self: *Reader) Error!f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// Check if there are more bytes to read.
    pub fn hasMore(self: *const Reader) bool {
        return self.pos < self.bytes.len;
    }

    /// Remaining bytes in the slice.
    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    /// Create a sub-reader for a given number of bytes.
    pub fn subReader(self: *Reader, len: usize) Error!Reader {
        if (self.pos + len > self.bytes.len) return error.EndOfStream;
        const sub = Reader{
            .bytes = self.bytes[self.pos..][0..len],
            .pos = 0,
        };
        self.pos += len;
        return sub;
    }
};

/// Internal: adapter that makes Reader work with std.leb functions.
const ByteReader = struct {
    reader: *Reader,

    pub fn readByte(self: *ByteReader) Error!u8 {
        return self.reader.readByte();
    }
};

fn readUnsigned(comptime T: type, reader: *Reader) Error!T {
    var br = ByteReader{ .reader = reader };
    return std.leb.readUleb128(T, &br) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.EndOfStream => return error.EndOfStream,
    };
}

fn readSigned(comptime T: type, reader: *Reader) Error!T {
    var br = ByteReader{ .reader = reader };
    return std.leb.readIleb128(T, &br) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.EndOfStream => return error.EndOfStream,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "readU32 — basic values" {
    // 0
    var r = Reader.init(&[_]u8{0x00});
    try testing.expectEqual(@as(u32, 0), try r.readU32());

    // 1
    r = Reader.init(&[_]u8{0x01});
    try testing.expectEqual(@as(u32, 1), try r.readU32());

    // 127 (single byte max)
    r = Reader.init(&[_]u8{0x7F});
    try testing.expectEqual(@as(u32, 127), try r.readU32());

    // 128 (two bytes)
    r = Reader.init(&[_]u8{ 0x80, 0x01 });
    try testing.expectEqual(@as(u32, 128), try r.readU32());

    // 624485 (example from Wikipedia)
    r = Reader.init(&[_]u8{ 0xE5, 0x8E, 0x26 });
    try testing.expectEqual(@as(u32, 624485), try r.readU32());
}

test "readI32 — positive and negative values" {
    // 0
    var r = Reader.init(&[_]u8{0x00});
    try testing.expectEqual(@as(i32, 0), try r.readI32());

    // 1
    r = Reader.init(&[_]u8{0x01});
    try testing.expectEqual(@as(i32, 1), try r.readI32());

    // -1
    r = Reader.init(&[_]u8{0x7F});
    try testing.expectEqual(@as(i32, -1), try r.readI32());

    // -64
    r = Reader.init(&[_]u8{0x40});
    try testing.expectEqual(@as(i32, -64), try r.readI32());

    // 63
    r = Reader.init(&[_]u8{0x3F});
    try testing.expectEqual(@as(i32, 63), try r.readI32());

    // -128
    r = Reader.init(&[_]u8{ 0x80, 0x7F });
    try testing.expectEqual(@as(i32, -128), try r.readI32());

    // 128
    r = Reader.init(&[_]u8{ 0x80, 0x01 });
    try testing.expectEqual(@as(i32, 128), try r.readI32());

    // -123456
    r = Reader.init(&[_]u8{ 0xC0, 0xBB, 0x78 });
    try testing.expectEqual(@as(i32, -123456), try r.readI32());
}

test "readU64 — large values" {
    // 0x8000000000000000
    var r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    try testing.expectEqual(@as(u64, 0x8000000000000000), try r.readU64());
}

test "readI64 — min/max" {
    // -1
    var r = Reader.init(&[_]u8{ 0x7F });
    try testing.expectEqual(@as(i64, -1), try r.readI64());

    // i64 min (-0x8000000000000000)
    r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F });
    try testing.expectEqual(@as(i64, -0x8000000000000000), try r.readI64());
}

test "readI33 — block type values" {
    // -1 (empty block 0x40 in Wasm)
    var r = Reader.init(&[_]u8{0x7F});
    try testing.expectEqual(@as(i64, -1), try r.readI33());

    // 0 (type index 0)
    r = Reader.init(&[_]u8{0x00});
    try testing.expectEqual(@as(i64, 0), try r.readI33());

    // -64 (ValType i32 = 0x7F, encoded as signed -1... actually let me reconsider)
    // In Wasm, block type 0x7F means val_type i32, encoded as a single byte
    // readI33 reads it as signed LEB128 → -1
    r = Reader.init(&[_]u8{0x40});
    try testing.expectEqual(@as(i64, -64), try r.readI33());
}

test "readByte and readBytes" {
    var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });

    try testing.expectEqual(@as(u8, 0x01), try r.readByte());
    const slice = try r.readBytes(2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x03 }, slice);
    try testing.expectEqual(@as(u8, 0x04), try r.readByte());
    try testing.expect(!r.hasMore());
}

test "readF32 and readF64" {
    // f32: 1.0 = 0x3F800000
    var r = Reader.init(&[_]u8{ 0x00, 0x00, 0x80, 0x3F });
    try testing.expectEqual(@as(f32, 1.0), try r.readF32());

    // f64: 1.0 = 0x3FF0000000000000
    r = Reader.init(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F });
    try testing.expectEqual(@as(f64, 1.0), try r.readF64());
}

test "sequential reads" {
    // Read multiple values from one buffer
    var r = Reader.init(&[_]u8{
        0x03, // u32: 3
        0x7F, // i32: -1
        0x80, 0x01, // u32: 128
    });

    try testing.expectEqual(@as(u32, 3), try r.readU32());
    try testing.expectEqual(@as(i32, -1), try r.readI32());
    try testing.expectEqual(@as(u32, 128), try r.readU32());
    try testing.expect(!r.hasMore());
}

test "subReader — scoped reading" {
    var r = Reader.init(&[_]u8{ 0x03, 0x41, 0x42, 0x43, 0x7F });

    const len = try r.readU32(); // 3
    try testing.expectEqual(@as(u32, 3), len);

    var sub = try r.subReader(len);
    const bytes = try sub.readBytes(3);
    try testing.expectEqualSlices(u8, "ABC", bytes);
    try testing.expect(!sub.hasMore());

    // Parent reader advanced past the sub-reader's bytes
    try testing.expectEqual(@as(i32, -1), try r.readI32());
}

test "overflow — truncated input" {
    var r = Reader.init(&[_]u8{0x80}); // continuation bit set, no follow-up
    try testing.expectError(error.EndOfStream, r.readU32());
}

test "overflow — value too large for u32" {
    // 5-byte encoding that overflows u32
    var r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x40 });
    try testing.expectError(error.Overflow, r.readU32());
}
