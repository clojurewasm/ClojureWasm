// SPDX-License-Identifier: EPL-2.0
//! Bytecode opcode set and per-chunk container for the VM backend.
//!
//! The VM backend (ROADMAP §4.4, ADR-0005) runs alongside the
//! TreeWalk backend. Both must produce bit-for-bit identical Values
//! under `Evaluator.compare` (ADR-0022); the opcode semantics
//! therefore mirror TreeWalk's observable behaviour rather than
//! introducing a new evaluation model.
//!
//! Phase 4 task 4.4 lands only the data shape: the `Opcode` enum,
//! the `Instruction` triple, and the immutable `BytecodeChunk`
//! container. The compiler (task 4.5) and dispatch loop (task 4.6)
//! consume these declarations.
//!
//! Per ROADMAP §9.6's note, the 15 opcodes here are the **starting**
//! set. `loop*` / `recur` / closure-capture work in task 4.7 may
//! add ops via `[ ]` insertions inside §9.6 without an ADR (only
//! ROADMAP §4.4 / §13 changes need one, per §17.2).

const std = @import("std");
const Value = @import("../../../runtime/value/value.zig").Value;

/// Bytecode operations dispatched by the VM.
///
/// Each operand's semantics depend on the opcode:
///   - `op_const`           operand = index into the chunk's constant pool
///   - `op_load_local` /
///     `op_store_local`     operand = frame slot index
///   - `op_get_var`         operand = constants index of a heap-tagged
///                          `Var` Value (analyzer pre-resolves the
///                          pointer; the VM decodes and calls
///                          `Var.deref`)
///   - `op_def`             operand = packed `(flags << 13) | name_idx`
///                          where the low 13 bits are the constants
///                          index of the symbol-name `String` Value
///                          (max `DEF_NAME_IDX_MAX`) and the high
///                          3 bits carry `DEF_FLAG_DYNAMIC /
///                          DEF_FLAG_MACRO / DEF_FLAG_PRIVATE`. The
///                          VM passes the name bytes to `env.intern`
///                          and stamps the flags on the resulting Var.
///   - `op_jump` /
///     `op_jump_if_false`   operand = signed instruction offset (bitcast to i16)
///   - `op_call` /
///     `op_invoke_builtin`  operand = argument count
///   - `op_make_fn`         operand = constants index of the FnProto
///   - `op_recur`           operand = binding count
///   - `op_push_handler`    operand = signed forward offset to the
///                          handler entry (`i16` via `@bitCast`).
///                          The dispatcher records `{ catch_ip,
///                          saved_sp }` and, on `error.ThrownValue`
///                          from the protected region, jumps to the
///                          handler with the thrown Value pushed.
///   - `op_pop_handler`     operand unused — pops the innermost
///                          handler entry (normal try exit)
///   - `op_match_class`     operand = constants index of the catch
///                          class-name `String`. Peeks the top Value
///                          and pushes `true_val` / `false_val`
///                          based on whether the class matches
///                          (`ExceptionInfo` ⇒ `.ex_info` tag,
///                          other names ⇒ false until later phases
///                          extend the table)
///   - `op_ret` / `op_pop` /
///     `op_dup` / `op_throw` operand unused
pub const Opcode = enum(u8) {
    op_const = 0x00,
    op_load_local = 0x01,
    op_store_local = 0x02,
    op_def = 0x03,
    op_get_var = 0x04,
    op_jump = 0x05,
    op_jump_if_false = 0x06,
    op_call = 0x07,
    op_ret = 0x08,
    op_pop = 0x09,
    op_dup = 0x0A,
    op_throw = 0x0B,
    op_make_fn = 0x0C,
    op_recur = 0x0D,
    op_invoke_builtin = 0x0E,
    op_push_handler = 0x0F,
    op_pop_handler = 0x10,
    op_match_class = 0x11,
    /// `(in-ns 'foo.bar)` — operand = constants index of the heap String
    /// holding the target namespace name. VM dispatch decodes the
    /// string, calls `env.findOrCreateNs` + sets `current_ns`, and
    /// pushes nil (matches `tree_walk::evalInNs` per ADR-0032).
    op_in_ns = 0x12,
    /// `[a b c]` vector literal — operand = element count N. VM
    /// dispatch pops N stack values (top-most = last element), builds
    /// a fresh PersistentVector via `vector.empty()` + `vector.conj`,
    /// and pushes it. Closes D-060 (Phase 6.16.a-3.2).
    op_vector_literal = 0x13,
};

/// `op_def` operand layout — see the Opcode docstring.
pub const DEF_NAME_IDX_MASK: u16 = 0x1FFF;
pub const DEF_NAME_IDX_MAX: u16 = DEF_NAME_IDX_MASK;
pub const DEF_FLAG_DYNAMIC: u16 = 1 << 13;
pub const DEF_FLAG_MACRO: u16 = 1 << 14;
pub const DEF_FLAG_PRIVATE: u16 = 1 << 15;

/// A single VM instruction. Fixed-width (opcode + u16 operand).
///
/// The typed struct is deliberate; ClojureWasm v1 uses a flat
/// `[]u8` stream for JIT-friendly cache density, but cw v2 keeps
/// the typed form for safety and debuggability. JIT-era byte
/// packing is Phase 17+ work.
pub const Instruction = struct {
    opcode: Opcode,
    operand: u16 = 0,
};

/// Compiled bytecode for a single function or top-level form.
///
/// The chunk is immutable after compile. The compiler (task 4.5)
/// owns the slices through the analyzer arena; the VM borrows them
/// for the duration of a call.
pub const BytecodeChunk = struct {
    instructions: []const Instruction,
    constants: []const Value,
};

test "opcode enum tags are stable u8 values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.op_const));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Opcode.op_load_local));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(Opcode.op_store_local));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(Opcode.op_def));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(Opcode.op_get_var));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(Opcode.op_jump));
    try std.testing.expectEqual(@as(u8, 0x06), @intFromEnum(Opcode.op_jump_if_false));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(Opcode.op_call));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(Opcode.op_ret));
    try std.testing.expectEqual(@as(u8, 0x09), @intFromEnum(Opcode.op_pop));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(Opcode.op_dup));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(Opcode.op_throw));
    try std.testing.expectEqual(@as(u8, 0x0C), @intFromEnum(Opcode.op_make_fn));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(Opcode.op_recur));
    try std.testing.expectEqual(@as(u8, 0x0E), @intFromEnum(Opcode.op_invoke_builtin));
    try std.testing.expectEqual(@as(u8, 0x0F), @intFromEnum(Opcode.op_push_handler));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(Opcode.op_pop_handler));
    try std.testing.expectEqual(@as(u8, 0x11), @intFromEnum(Opcode.op_match_class));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(Opcode.op_in_ns));
}

test "Instruction carries opcode and u16 operand" {
    const ins: Instruction = .{ .opcode = .op_const, .operand = 42 };
    try std.testing.expectEqual(Opcode.op_const, ins.opcode);
    try std.testing.expectEqual(@as(u16, 42), ins.operand);

    const ret: Instruction = .{ .opcode = .op_ret };
    try std.testing.expectEqual(@as(u16, 0), ret.operand);
}

test "Instruction operand reaches u16 boundary" {
    const ins: Instruction = .{ .opcode = .op_jump, .operand = std.math.maxInt(u16) };
    try std.testing.expectEqual(@as(u16, 65535), ins.operand);
}

test "BytecodeChunk holds instructions and constants" {
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.nil_val};
    const chunk: BytecodeChunk = .{
        .instructions = &instrs,
        .constants = &constants,
    };
    try std.testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try std.testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try std.testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try std.testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "empty BytecodeChunk is well-formed" {
    const chunk: BytecodeChunk = .{
        .instructions = &.{},
        .constants = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), chunk.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.constants.len);
}
