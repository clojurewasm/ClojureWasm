// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Wasm bytecode predecoder — converts variable-width bytecode to fixed-width
//! 8-byte instructions at module load time. Eliminates LEB128 decode and
//! bounds checks at dispatch time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;

/// Fixed-width 8-byte predecoded instruction.
pub const PreInstr = extern struct {
    opcode: u16,
    extra: u16,
    operand: u32,
};

comptime {
    std.debug.assert(@sizeOf(PreInstr) == 8);
}

/// Predecoded function IR — code array + constant pool.
pub const IrFunc = struct {
    code: []PreInstr,
    pool64: []u64, // i64.const, f64.const values
    alloc: Allocator,

    pub fn deinit(self: *IrFunc) void {
        self.alloc.free(self.code);
        if (self.pool64.len > 0) self.alloc.free(self.pool64);
    }
};

// Internal marker opcodes for data words
pub const OP_IF_DATA: u16 = 0xFF00;
pub const OP_BR_TABLE_ENTRY: u16 = 0xFF01;

// Prefix bases for flattened opcodes
pub const MISC_BASE: u16 = 0xFC00;
pub const SIMD_BASE: u16 = 0xFD00;

/// Block arity encoding in extra field:
/// - bits 14:0 = arity value (0 or 1 for simple cases)
/// - bit 15 = 1 if value is a type_index (resolve arity at runtime)
pub const ARITY_TYPE_INDEX_FLAG: u16 = 0x8000;

pub const PredecodeError = error{
    UnsupportedSimd,
    OutOfMemory,
    InvalidWasm,
};

const BlockEntry = struct {
    kind: enum { block, loop, @"if" },
    ir_pos: u32,
    has_else: bool = false,
    else_ir_pos: u32 = 0,
};

/// Predecode wasm bytecode into fixed-width IR.
/// Returns null if the function contains unsupported opcodes (e.g., SIMD).
pub fn predecode(alloc: Allocator, bytecode: []const u8) PredecodeError!?*IrFunc {
    var code: std.ArrayList(PreInstr) = .empty;
    errdefer code.deinit(alloc);
    var pool64: std.ArrayList(u64) = .empty;
    errdefer pool64.deinit(alloc);
    var block_stack: std.ArrayList(BlockEntry) = .empty;
    defer block_stack.deinit(alloc);

    var reader = Reader.init(bytecode);

    while (reader.hasMore()) {
        const byte = reader.readByte() catch break;

        switch (byte) {
            // -- Block structure --
            0x02 => { // block
                const arity_enc = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x02, .extra = arity_enc, .operand = 0 });
                try block_stack.append(alloc, .{ .kind = .block, .ir_pos = pos });
            },
            0x03 => { // loop
                _ = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x03, .extra = 0, .operand = pos + 1 });
                try block_stack.append(alloc, .{ .kind = .loop, .ir_pos = pos });
            },
            0x04 => { // if
                const arity_enc = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x04, .extra = arity_enc, .operand = 0 });
                try code.append(alloc, .{ .opcode = OP_IF_DATA, .extra = 0, .operand = 0 });
                try block_stack.append(alloc, .{ .kind = .@"if", .ir_pos = pos });
            },
            0x05 => { // else
                if (block_stack.items.len > 0) {
                    const top = &block_stack.items[block_stack.items.len - 1];
                    const else_pos: u32 = @intCast(code.items.len);
                    try code.append(alloc, .{ .opcode = 0x05, .extra = 0, .operand = 0 });
                    code.items[top.ir_pos].operand = else_pos + 1;
                    top.has_else = true;
                    top.else_ir_pos = else_pos;
                }
            },
            0x0B => { // end
                const end_pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x0B, .extra = 0, .operand = 0 });
                if (block_stack.pop()) |entry| {
                    const after_end = end_pos + 1;
                    switch (entry.kind) {
                        .block => {
                            code.items[entry.ir_pos].operand = after_end;
                        },
                        .loop => {},
                        .@"if" => {
                            if (entry.has_else) {
                                code.items[entry.else_ir_pos].operand = after_end;
                                code.items[entry.ir_pos + 1].operand = after_end;
                                code.items[entry.ir_pos + 1].extra = 1;
                            } else {
                                code.items[entry.ir_pos].operand = after_end;
                                code.items[entry.ir_pos + 1].operand = after_end;
                                code.items[entry.ir_pos + 1].extra = 0;
                            }
                        },
                    }
                }
            },

            // -- Branch --
            0x0C => { // br
                const depth = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0C, .extra = 0, .operand = depth });
            },
            0x0D => { // br_if
                const depth = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0D, .extra = 0, .operand = depth });
            },
            0x0E => { // br_table
                const count = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0E, .extra = 0, .operand = count });
                for (0..count + 1) |_| {
                    const depth = reader.readU32() catch return error.InvalidWasm;
                    try code.append(alloc, .{ .opcode = OP_BR_TABLE_ENTRY, .extra = 0, .operand = depth });
                }
            },

            // -- Call --
            0x10 => { // call
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x10, .extra = 0, .operand = idx });
            },
            0x11 => { // call_indirect
                const type_idx = reader.readU32() catch return error.InvalidWasm;
                const table_idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x11, .extra = @intCast(table_idx), .operand = type_idx });
            },

            // -- Simple control --
            0x00 => try emit0(alloc, &code, 0x00), // unreachable
            0x01 => try emit0(alloc, &code, 0x01), // nop
            0x0F => try emit0(alloc, &code, 0x0F), // return

            // -- Parametric --
            0x1A => try emit0(alloc, &code, 0x1A), // drop
            0x1B => try emit0(alloc, &code, 0x1B), // select
            0x1C => { // select_t
                const n = reader.readU32() catch return error.InvalidWasm;
                for (0..n) |_| _ = reader.readByte() catch return error.InvalidWasm;
                try emit0(alloc, &code, 0x1B);
            },

            // -- Variable access --
            0x20, 0x21, 0x22, 0x23, 0x24 => {
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = 0, .operand = idx });
            },

            // -- Table access --
            0x25, 0x26 => {
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = 0, .operand = idx });
            },

            // -- Memory load/store (alignment + offset) --
            0x28...0x3E => {
                const align_val = reader.readU32() catch return error.InvalidWasm;
                const offset = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = @intCast(align_val), .operand = offset });
            },

            // -- Memory misc --
            0x3F, 0x40 => {
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = 0, .operand = idx });
            },

            // -- Constants --
            0x41 => { // i32.const
                const val = reader.readI32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x41, .extra = 0, .operand = @bitCast(val) });
            },
            0x42 => { // i64.const
                const val = reader.readI64() catch return error.InvalidWasm;
                const pool_idx: u32 = @intCast(pool64.items.len);
                try pool64.append(alloc, @bitCast(val));
                try code.append(alloc, .{ .opcode = 0x42, .extra = 0, .operand = pool_idx });
            },
            0x43 => { // f32.const
                const bytes = reader.readBytes(4) catch return error.InvalidWasm;
                const val = std.mem.readInt(u32, bytes[0..4], .little);
                try code.append(alloc, .{ .opcode = 0x43, .extra = 0, .operand = val });
            },
            0x44 => { // f64.const
                const bytes = reader.readBytes(8) catch return error.InvalidWasm;
                const val = std.mem.readInt(u64, bytes[0..8], .little);
                const pool_idx: u32 = @intCast(pool64.items.len);
                try pool64.append(alloc, val);
                try code.append(alloc, .{ .opcode = 0x44, .extra = 0, .operand = pool_idx });
            },

            // -- No-operand opcodes (comparison, arithmetic, conversion, sign extension) --
            0x45...0xC4 => try emit0(alloc, &code, @intCast(byte)),

            // -- Reference types --
            0xD0 => { // ref_null
                _ = reader.readByte() catch return error.InvalidWasm;
                try emit0(alloc, &code, 0xD0);
            },
            0xD1 => try emit0(alloc, &code, 0xD1), // ref_is_null
            0xD2 => { // ref_func
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0xD2, .extra = 0, .operand = idx });
            },

            // -- Misc prefix (0xFC) --
            0xFC => {
                if (!try predecodeMisc(alloc, &code, &reader)) return error.InvalidWasm;
            },

            // -- SIMD prefix (0xFD) — not supported, fall back --
            0xFD => {
                code.deinit(alloc);
                pool64.deinit(alloc);
                return null;
            },

            else => try emit0(alloc, &code, @intCast(byte)),
        }
    }

    const ir = try alloc.create(IrFunc);
    ir.* = .{
        .code = try code.toOwnedSlice(alloc),
        .pool64 = if (pool64.items.len > 0) try pool64.toOwnedSlice(alloc) else &.{},
        .alloc = alloc,
    };
    return ir;
}

fn emit0(alloc: Allocator, code: *std.ArrayList(PreInstr), op: u16) !void {
    try code.append(alloc, .{ .opcode = op, .extra = 0, .operand = 0 });
}

fn readBlockTypeEncoded(reader: *Reader) !u16 {
    if (reader.pos >= reader.bytes.len) return error.EndOfStream;
    const byte = reader.bytes[reader.pos];
    if (byte == 0x40) {
        reader.pos += 1;
        return 0;
    }
    if (byte >= 0x6F and byte <= 0x7F) {
        reader.pos += 1;
        return 1;
    }
    const idx = try reader.readI33();
    return ARITY_TYPE_INDEX_FLAG | @as(u16, @intCast(@as(u32, @intCast(idx))));
}

fn predecodeMisc(alloc: Allocator, code: *std.ArrayList(PreInstr), reader: *Reader) !bool {
    const sub = reader.readU32() catch return false;
    const ir_op: u16 = MISC_BASE | @as(u16, @intCast(sub & 0xFF));
    switch (sub) {
        // trunc_sat ops (no immediate)
        0x00...0x07 => try emit0(alloc, code, ir_op),
        // memory.copy (dst_memidx + src_memidx)
        0x0A => {
            const dst = reader.readU32() catch return false;
            const src = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(dst), .operand = src });
        },
        // memory.fill (memidx)
        0x0B => {
            const memidx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = memidx });
        },
        // memory.init (data_idx + memidx)
        0x08 => {
            const data_idx = reader.readU32() catch return false;
            const memidx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(memidx), .operand = data_idx });
        },
        // data.drop
        0x09 => {
            const data_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = data_idx });
        },
        // table.copy (dst + src)
        0x0C => {
            const dst = reader.readU32() catch return false;
            const src = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(dst), .operand = src });
        },
        // table.init (elem_idx + table_idx)
        0x0D => {
            const elem_idx = reader.readU32() catch return false;
            const table_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(table_idx), .operand = elem_idx });
        },
        // table.fill, table.grow, table.size (table_idx)
        0x0E, 0x0F, 0x10 => {
            const table_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = table_idx });
        },
        // elem.drop
        0x11 => {
            const elem_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = elem_idx });
        },
        else => try emit0(alloc, code, ir_op),
    }
    return true;
}

/// Resolve block arity from encoded extra field.
pub fn resolveArity(extra: u16, types: anytype) usize {
    if (extra & ARITY_TYPE_INDEX_FLAG != 0) {
        const idx = extra & ~ARITY_TYPE_INDEX_FLAG;
        if (idx < types.len) return types[idx].results.len;
        return 0;
    }
    return extra;
}
