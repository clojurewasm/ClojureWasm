//! Chunk and FnProto — bytecode containers.
//!
//! Chunk holds an instruction sequence and constant pool for top-level code.
//! FnProto holds the same for a compiled function body.

const std = @import("std");
const opcodes = @import("opcodes.zig");
const value_mod = @import("../value.zig");

pub const OpCode = opcodes.OpCode;
pub const Instruction = opcodes.Instruction;
pub const Value = value_mod.Value;

/// Compiled bytecode container (top-level or function body).
pub const Chunk = struct {
    allocator: std.mem.Allocator,
    /// Instruction sequence.
    code: std.ArrayListUnmanaged(Instruction),
    /// Constant pool.
    constants: std.ArrayListUnmanaged(Value),

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .code = .empty,
            .constants = .empty,
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    /// Add a value to the constant pool and return its index.
    pub fn addConstant(self: *Chunk, val: Value) !u16 {
        const idx = self.constants.items.len;
        if (idx > std.math.maxInt(u16)) return error.Overflow;
        try self.constants.append(self.allocator, val);
        return @intCast(idx);
    }

    /// Emit an instruction with operand.
    pub fn emit(self: *Chunk, op: OpCode, operand: u16) !void {
        try self.code.append(self.allocator, .{ .op = op, .operand = operand });
    }

    /// Emit an instruction without operand.
    pub fn emitOp(self: *Chunk, op: OpCode) !void {
        try self.code.append(self.allocator, .{ .op = op });
    }

    /// Return the current instruction offset (for jump patching).
    pub fn currentOffset(self: *const Chunk) usize {
        return self.code.items.len;
    }

    /// Emit a jump instruction with placeholder operand. Returns the offset to patch later.
    pub fn emitJump(self: *Chunk, op: OpCode) !usize {
        const offset = self.code.items.len;
        try self.code.append(self.allocator, .{ .op = op, .operand = 0xFFFF });
        return offset;
    }

    /// Patch a previously emitted jump to target the current offset.
    pub fn patchJump(self: *Chunk, offset: usize) void {
        const jump_dist = self.code.items.len - offset - 1;
        self.code.items[offset].operand = @intCast(jump_dist);
    }

    /// Emit a backward jump (for loops) to the given target offset.
    pub fn emitLoop(self: *Chunk, loop_start: usize) !void {
        const dist = self.code.items.len - loop_start + 1;
        const operand: u16 = @bitCast(-@as(i16, @intCast(dist)));
        try self.emit(.jump_back, operand);
    }
};

/// Compiled function prototype.
pub const FnProto = struct {
    name: ?[]const u8,
    arity: u8,
    variadic: bool,
    /// Number of local variable slots (including parameters).
    local_count: u16,
    /// Number of captured variables from parent scope.
    capture_count: u16 = 0,
    /// Instruction sequence.
    code: []const Instruction,
    /// Constant pool.
    constants: []const Value,
};

// === Tests ===

test "Chunk basic emit and addConstant" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    // Add a constant
    const idx = try chunk.addConstant(.{ .integer = 42 });
    try std.testing.expectEqual(@as(u16, 0), idx);
    try std.testing.expectEqual(@as(usize, 1), chunk.constants.items.len);

    // Emit instructions
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    try std.testing.expectEqual(@as(usize, 2), chunk.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, chunk.code.items[0].op);
    try std.testing.expectEqual(@as(u16, 0), chunk.code.items[0].operand);
    try std.testing.expectEqual(OpCode.ret, chunk.code.items[1].op);
}

test "Chunk jump patching" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const jump_offset = try chunk.emitJump(.jump_if_false);
    try chunk.emitOp(.nil);
    try chunk.emitOp(.nil);
    chunk.patchJump(jump_offset);

    try std.testing.expectEqual(@as(u16, 2), chunk.code.items[jump_offset].operand);
}

test "Chunk currentOffset" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    try std.testing.expectEqual(@as(usize, 0), chunk.currentOffset());
    try chunk.emitOp(.nil);
    try std.testing.expectEqual(@as(usize, 1), chunk.currentOffset());
    try chunk.emitOp(.pop);
    try std.testing.expectEqual(@as(usize, 2), chunk.currentOffset());
}

test "Chunk emitLoop backward jump" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const loop_start = chunk.currentOffset();
    try chunk.emitOp(.nil);
    try chunk.emitOp(.pop);
    try chunk.emitLoop(loop_start);

    const jump_instr = chunk.code.items[chunk.code.items.len - 1];
    try std.testing.expectEqual(OpCode.jump_back, jump_instr.op);
    const signed = jump_instr.signedOperand();
    try std.testing.expect(signed < 0);
}

test "FnProto creation" {
    const code = [_]Instruction{
        .{ .op = .nil },
        .{ .op = .ret },
    };
    const constants = [_]Value{};

    const proto = FnProto{
        .name = "my-fn",
        .arity = 2,
        .variadic = false,
        .local_count = 2,
        .code = &code,
        .constants = &constants,
    };

    try std.testing.expectEqualStrings("my-fn", proto.name.?);
    try std.testing.expectEqual(@as(u8, 2), proto.arity);
    try std.testing.expect(!proto.variadic);
    try std.testing.expectEqual(@as(u16, 2), proto.local_count);
    try std.testing.expectEqual(@as(usize, 2), proto.code.len);
    try std.testing.expectEqual(@as(usize, 0), proto.constants.len);
}
