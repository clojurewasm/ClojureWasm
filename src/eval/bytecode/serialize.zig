// SPDX-License-Identifier: EPL-2.0
//! Bytecode serializer + deserializer skeleton — §9.14 row 12.2 cycle 1.
//!
//! Wire format (versioned per ADR-0034 § format-version policy
//! "decoder-only permanent compatibility"):
//!
//!   [0..4]   magic  = "CLJW"
//!   [4..6]   version (u16 little-endian, currently 1)
//!   [6..10]  instr_count (u32 little-endian)
//!   [10..]   instructions = instr_count * (opcode:u8 + operand:u16le)
//!
//! Cycle-1 scope: header + Instruction stream only. Constants pool,
//! call_sites side-table, libspecs side-table all defer to D-100
//! (Phase 12 substantive deliverables — multi-cycle work). The
//! cycle-1 round-trip property proves the byte-framing + version
//! handshake; subsequent cycles extend the body coverage without
//! breaking the wire format (decoder reads `version` first +
//! dispatches to the matching reader, per ADR-0034 D11
//! `cljw-formats/<version>.edn` archive layer).

const std = @import("std");
const opcode_mod = @import("../backend/vm/opcode.zig");
const Instruction = opcode_mod.Instruction;
const Opcode = opcode_mod.Opcode;

pub const MAGIC: [4]u8 = .{ 'C', 'L', 'J', 'W' };
pub const VERSION: u16 = 1;

pub const SerializeError = error{
    OutOfMemory,
    WriteFailed,
};

pub const DeserializeError = error{
    BytecodeTruncated,
    BadMagic,
    UnsupportedVersion,
    UnknownOpcode,
};

/// Serialize a slice of Instructions into a freshly-allocated
/// byte buffer. Caller owns the returned slice (free via the same
/// allocator).
pub fn serializeInstructions(allocator: std.mem.Allocator, instrs: []const Instruction) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll(&MAGIC);
    try aw.writer.writeInt(u16, VERSION, .little);
    try aw.writer.writeInt(u32, @intCast(instrs.len), .little);
    for (instrs) |ins| {
        try aw.writer.writeByte(@intFromEnum(ins.opcode));
        try aw.writer.writeInt(u16, ins.operand, .little);
    }
    return try aw.toOwnedSlice();
}

/// Deserialize a byte buffer back into a freshly-allocated
/// `[]Instruction`. Caller owns the returned slice (free via the
/// same allocator).
pub fn deserializeInstructions(allocator: std.mem.Allocator, bytes: []const u8) ![]Instruction {
    if (bytes.len < 10) return DeserializeError.BytecodeTruncated;
    if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return DeserializeError.BadMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != VERSION) return DeserializeError.UnsupportedVersion;
    const count = std.mem.readInt(u32, bytes[6..10], .little);
    const body_bytes_needed = @as(usize, count) * 3; // op(1) + operand(2)
    if (bytes.len < 10 + body_bytes_needed) return DeserializeError.BytecodeTruncated;

    const out = try allocator.alloc(Instruction, count);
    errdefer allocator.free(out);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const base = 10 + (@as(usize, i) * 3);
        const op_raw = bytes[base];
        const op = std.enums.fromInt(Opcode, op_raw) orelse return DeserializeError.UnknownOpcode;
        const operand = std.mem.readInt(u16, bytes[base + 1 ..][0..2], .little);
        out[i] = .{ .opcode = op, .operand = operand };
    }
    return out;
}

// --- tests ---

const testing = std.testing;

test "header magic + version round-trips on empty instruction list" {
    const bytes = try serializeInstructions(testing.allocator, &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len == 10);
    try testing.expectEqualSlices(u8, &MAGIC, bytes[0..4]);
    try testing.expectEqual(@as(u16, VERSION), std.mem.readInt(u16, bytes[4..6], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[6..10], .little));

    const round = try deserializeInstructions(testing.allocator, bytes);
    defer testing.allocator.free(round);
    try testing.expectEqual(@as(usize, 0), round.len);
}

test "round-trips a 3-instruction chunk preserving opcode + operand" {
    const original = [_]Instruction{
        .{ .opcode = .op_const, .operand = 42 },
        .{ .opcode = .op_ret, .operand = 0 },
        .{ .opcode = .op_pop, .operand = 7 },
    };
    const bytes = try serializeInstructions(testing.allocator, &original);
    defer testing.allocator.free(bytes);
    const round = try deserializeInstructions(testing.allocator, bytes);
    defer testing.allocator.free(round);
    try testing.expectEqual(original.len, round.len);
    for (original, round) |a, b| {
        try testing.expectEqual(a.opcode, b.opcode);
        try testing.expectEqual(a.operand, b.operand);
    }
}

test "bad magic rejected with BadMagic" {
    const bytes = [_]u8{ 'X', 'X', 'X', 'X', 1, 0, 0, 0, 0, 0 };
    try testing.expectError(
        DeserializeError.BadMagic,
        deserializeInstructions(testing.allocator, &bytes),
    );
}

test "truncated buffer rejected with BytecodeTruncated" {
    const bytes = [_]u8{'C'};
    try testing.expectError(
        DeserializeError.BytecodeTruncated,
        deserializeInstructions(testing.allocator, &bytes),
    );
}

test "unsupported version rejected with UnsupportedVersion" {
    const bytes = [_]u8{ 'C', 'L', 'J', 'W', 99, 0, 0, 0, 0, 0 };
    try testing.expectError(
        DeserializeError.UnsupportedVersion,
        deserializeInstructions(testing.allocator, &bytes),
    );
}
