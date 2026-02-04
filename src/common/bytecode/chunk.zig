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
    code: std.ArrayList(Instruction),
    /// Constant pool.
    constants: std.ArrayList(Value),
    /// Source line per instruction (parallel to code).
    lines: std.ArrayList(u32),
    /// Current source line — set by compiler before emitting.
    current_line: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .code = .empty,
            .constants = .empty,
            .lines = .empty,
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.lines.deinit(self.allocator);
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
        try self.lines.append(self.allocator, self.current_line);
    }

    /// Emit an instruction without operand.
    pub fn emitOp(self: *Chunk, op: OpCode) !void {
        try self.code.append(self.allocator, .{ .op = op });
        try self.lines.append(self.allocator, self.current_line);
    }

    /// Return the current instruction offset (for jump patching).
    pub fn currentOffset(self: *const Chunk) usize {
        return self.code.items.len;
    }

    /// Emit a jump instruction with placeholder operand. Returns the offset to patch later.
    pub fn emitJump(self: *Chunk, op: OpCode) !usize {
        const offset = self.code.items.len;
        try self.code.append(self.allocator, .{ .op = op, .operand = 0xFFFF });
        try self.lines.append(self.allocator, self.current_line);
        return offset;
    }

    /// Patch a previously emitted jump to target the current offset.
    pub fn patchJump(self: *Chunk, offset: usize) void {
        const jump_dist = self.code.items.len - offset - 1;
        self.code.items[offset].operand = @intCast(jump_dist);
    }

    /// Emit a backward jump (for loops) to the given target offset.
    /// Operand is the positive distance; VM subtracts it from ip.
    pub fn emitLoop(self: *Chunk, loop_start: usize) !void {
        const dist = self.code.items.len - loop_start + 1;
        try self.emit(.jump_back, @intCast(dist));
    }

    /// Dump bytecode to writer for debugging.
    pub fn dump(self: *const Chunk, w: *std.Io.Writer) !void {
        try w.writeAll("=== Bytecode Dump ===\n");

        if (self.constants.items.len > 0) {
            try w.writeAll("\n--- Constants ---\n");
            for (self.constants.items, 0..) |c, ci| {
                try w.print("  [{d:>3}] ", .{ci});
                try dumpValue(c, w);
                try w.writeByte('\n');
            }
        }

        try w.writeAll("\n--- Instructions ---\n");
        for (self.code.items, 0..) |instr, ip| {
            try w.print("  {d:>4}: ", .{ip});
            try dumpInstruction(instr, self.constants.items, w);
            try w.writeByte('\n');
        }

        try w.print("\n({d} instructions, {d} constants)\n", .{
            self.code.items.len,
            self.constants.items.len,
        });
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
    /// Parent stack slots to capture (one per captured variable).
    /// Used by VM closure op to read values from non-contiguous stack positions.
    capture_slots: []const u16 = &.{},
    /// Named fn has self-reference as first local (for recursion).
    has_self_ref: bool = false,
    /// Instruction sequence.
    code: []const Instruction,
    /// Constant pool.
    constants: []const Value,
    /// Source line per instruction (parallel to code).
    lines: []const u32 = &.{},

    /// Dump function prototype to writer for debugging.
    pub fn dump(self: *const FnProto, w: *std.Io.Writer) !void {
        try w.print("\n--- fn {s} (arity={d}{s}) ---\n", .{
            self.name orelse "<anonymous>",
            self.arity,
            if (self.variadic) @as([]const u8, " variadic") else "",
        });

        if (self.constants.len > 0) {
            try w.writeAll("  Constants:\n");
            for (self.constants, 0..) |c, ci| {
                try w.print("    [{d:>3}] ", .{ci});
                try dumpValue(c, w);
                try w.writeByte('\n');
            }
        }

        for (self.code, 0..) |instr, ip| {
            try w.print("    {d:>4}: ", .{ip});
            try dumpInstruction(instr, self.constants, w);
            try w.writeByte('\n');
        }
    }
};

/// Dump a single instruction with context-aware operand formatting.
fn dumpInstruction(instr: Instruction, constants: []const Value, w: *std.Io.Writer) !void {
    const op_name = @tagName(instr.op);
    try w.print("{s:<20}", .{op_name});

    switch (instr.op) {
        .const_load => {
            try w.print(" #{d}", .{instr.operand});
            if (instr.operand < constants.len) {
                try w.writeAll("  ; ");
                try dumpValue(constants[instr.operand], w);
            }
        },
        .local_load, .local_store => {
            try w.print(" slot={d}", .{instr.operand});
        },
        .upvalue_load, .upvalue_store => {
            try w.print(" upval={d}", .{instr.operand});
        },
        .var_load, .var_load_dynamic, .def, .def_macro => {
            try w.print(" #{d}", .{instr.operand});
            if (instr.operand < constants.len) {
                try w.writeAll("  ; ");
                try dumpValue(constants[instr.operand], w);
            }
        },
        .jump, .jump_if_false, .jump_back => {
            try w.print(" {d}", .{instr.operand});
        },
        .call, .tail_call, .recur => {
            try w.print(" {d}", .{instr.operand});
        },
        .list_new, .vec_new, .set_new => {
            try w.print(" n={d}", .{instr.operand});
        },
        .map_new => {
            try w.print(" pairs={d}", .{instr.operand});
        },
        .closure => {
            // Operand: constant pool index of fn template
            const const_idx: u16 = instr.operand;
            try w.print(" #{d}", .{const_idx});
            if (const_idx < constants.len) {
                try w.writeAll("  ; ");
                try dumpValue(constants[const_idx], w);
            }
        },
        else => {},
    }
}

/// Dump a value in a compact readable form.
fn dumpValue(val: Value, w: *std.Io.Writer) !void {
    switch (val) {
        .nil => try w.writeAll("nil"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .char => |c| try w.print("\\{u}", .{c}),
        .string => |s| try w.print("\"{s}\"", .{s}),
        .symbol => |s| {
            if (s.ns) |ns| {
                try w.print("{s}/{s}", .{ ns, s.name });
            } else {
                try w.writeAll(s.name);
            }
        },
        .keyword => |k| {
            try w.writeByte(':');
            if (k.ns) |ns| {
                try w.print("{s}/", .{ns});
            }
            try w.writeAll(k.name);
        },
        .fn_val => try w.writeAll("#<fn>"),
        else => try w.print("<{s}>", .{@tagName(val)}),
    }
}

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
    // Operand is positive distance (VM subtracts it from ip)
    try std.testing.expect(jump_instr.operand > 0);
}

test "Chunk.dump basic output" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(.{ .integer = 42 });
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.pop);
    try chunk.emitOp(.ret);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try chunk.dump(&w);
    const output = w.buffered();

    // Header
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Bytecode Dump ===") != null);
    // Constants section
    try std.testing.expect(std.mem.indexOf(u8, output, "Constants") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
    // Instructions section
    try std.testing.expect(std.mem.indexOf(u8, output, "Instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const_load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pop") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ret") != null);
    // Footer
    try std.testing.expect(std.mem.indexOf(u8, output, "3 instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1 constants") != null);
}

test "Chunk.dump const_load shows constant value comment" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    _ = try chunk.addConstant(.{ .symbol = .{ .name = "foo", .ns = null } });
    try chunk.emit(.const_load, 0);
    try chunk.emitOp(.ret);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try chunk.dump(&w);
    const output = w.buffered();

    // const_load should show "; foo" as comment
    try std.testing.expect(std.mem.indexOf(u8, output, "; foo") != null);
}

test "Chunk.dump jump instructions show offset" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const jmp = try chunk.emitJump(.jump_if_false);
    try chunk.emitOp(.nil);
    chunk.patchJump(jmp);
    try chunk.emitOp(.ret);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try chunk.dump(&w);
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "jump_if_false") != null);
}

test "FnProto.dump output" {
    const code = [_]Instruction{
        .{ .op = .local_load, .operand = 0 },
        .{ .op = .ret },
    };
    const constants = [_]Value{.{ .integer = 10 }};

    const proto = FnProto{
        .name = "my-fn",
        .arity = 1,
        .variadic = false,
        .local_count = 1,
        .code = &code,
        .constants = &constants,
    };

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try proto.dump(&w);
    const output = w.buffered();

    // Header with fn name and arity
    try std.testing.expect(std.mem.indexOf(u8, output, "fn my-fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "arity=1") != null);
    // Instructions
    try std.testing.expect(std.mem.indexOf(u8, output, "local_load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "slot=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ret") != null);
}

test "FnProto.dump variadic" {
    const code = [_]Instruction{.{ .op = .ret }};
    const constants = [_]Value{};

    const proto = FnProto{
        .name = null,
        .arity = 0,
        .variadic = true,
        .local_count = 0,
        .code = &code,
        .constants = &constants,
    };

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try proto.dump(&w);
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "<anonymous>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "variadic") != null);
}

test "Chunk lines track current_line per instruction" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    chunk.current_line = 3;
    try chunk.emitOp(.nil); // line 3
    chunk.current_line = 5;
    try chunk.emit(.const_load, 0); // line 5
    chunk.current_line = 7;
    _ = try chunk.emitJump(.jump_if_false); // line 7

    try std.testing.expectEqual(@as(usize, 3), chunk.lines.items.len);
    try std.testing.expectEqual(@as(u32, 3), chunk.lines.items[0]);
    try std.testing.expectEqual(@as(u32, 5), chunk.lines.items[1]);
    try std.testing.expectEqual(@as(u32, 7), chunk.lines.items[2]);
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
