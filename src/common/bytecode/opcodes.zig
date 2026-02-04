//! OpCode definitions for the ClojureWasm bytecode VM.
//!
//! Fixed 3-byte instruction format: u8 opcode + u16 operand.
//! Opcodes are grouped by category with reserved ranges for future extension.
//!
//! Processing pipeline:
//!   Form (Reader) -> Node (Analyzer) -> Bytecode (Compiler) -> Value (VM)

const std = @import("std");

/// Bytecode operation codes.
///
/// Categories are assigned reserved ranges:
///   0x00-0x0F: Constants/Literals
///   0x10-0x1F: Stack operations
///   0x20-0x2F: Local variables
///   0x30-0x3F: Upvalues (closures)
///   0x40-0x4F: Var operations
///   0x50-0x5F: Control flow
///   0x60-0x6F: Functions
///   0x70-0x7F: Loop/recur
///   0x80-0x8F: Collection construction
///   0xA0-0xAF: Exception handling
///   0xB0-0xBF: Arithmetic/comparison
///   0xF0-0xFF: Reserved/debug
pub const OpCode = enum(u8) {
    // === [A] Constants/Literals (0x00-0x0F) ===

    /// Push constant from pool (operand: constant index u16)
    const_load = 0x00,
    /// Push nil
    nil = 0x01,
    /// Push true
    true_val = 0x02,
    /// Push false
    false_val = 0x03,

    // === [B] Stack operations (0x10-0x1F) ===

    /// Discard top of stack
    pop = 0x10,
    /// Duplicate top of stack
    dup = 0x11,
    /// Keep top, remove operand values below it (for let/do cleanup)
    pop_under = 0x12,

    // === [C] Local variables (0x20-0x2F) ===

    /// Push local variable (operand: slot index u16)
    local_load = 0x20,
    /// Store into local variable (operand: slot index u16)
    local_store = 0x21,

    // === [D] Upvalues / closures (0x30-0x3F) ===

    /// Push captured variable from enclosing scope (operand: upvalue index u16)
    upvalue_load = 0x30,
    /// Store into captured variable (operand: upvalue index u16)
    upvalue_store = 0x31,

    // === [E] Var operations (0x40-0x4F) ===

    /// Push Var root value (operand: constant index u16 -> Var pointer)
    var_load = 0x40,
    /// Push dynamic Var value (binding macro support)
    var_load_dynamic = 0x41,
    /// def (operand: constant index u16 -> symbol name)
    def = 0x42,
    /// def with macro flag (operand: constant index u16 -> symbol name)
    def_macro = 0x43,
    /// defmulti (operand: constant index u16 -> symbol name)
    /// Stack: [dispatch_fn] -> [multi_fn]
    defmulti = 0x44,
    /// defmethod (operand: constant index u16 -> multimethod name)
    /// Stack: [dispatch_val, method_fn] -> [method_fn]
    defmethod = 0x45,
    /// lazy_seq (operand: unused)
    /// Stack: [thunk_fn] -> [lazy_seq_value]
    lazy_seq = 0x46,

    // === [F] Control flow (0x50-0x5F) ===

    /// Unconditional jump (operand: offset as i16)
    jump = 0x50,
    /// Jump if top is false/nil (operand: offset as i16)
    jump_if_false = 0x51,
    /// Backward jump for loops (operand: negative offset as i16)
    jump_back = 0x54,

    // === [G] Functions (0x60-0x6F) ===

    /// Function call (operand: argument count u16)
    call = 0x60,
    /// Tail call optimization (operand: argument count u16)
    tail_call = 0x65,
    /// Return top of stack
    ret = 0x67,
    /// Create closure (operand: constant index u16 -> FnProto)
    closure = 0x68,

    // === [H] Loop/recur (0x70-0x7F) ===

    /// Recur: rebind loop args and jump back (operand: argument count u16)
    recur = 0x71,

    // === [I] Collection construction (0x80-0x8F) ===

    /// Create list literal (operand: element count u16)
    list_new = 0x80,
    /// Create vector literal (operand: element count u16)
    vec_new = 0x81,
    /// Create map literal (operand: pair count u16)
    map_new = 0x82,
    /// Create set literal (operand: element count u16)
    set_new = 0x83,

    // === [K] Exception handling (0xA0-0xAF) ===

    /// Begin try block (operand: offset to catch/finally)
    try_begin = 0xA0,
    /// Begin catch clause (operand: constant index for exception type)
    catch_begin = 0xA1,
    /// End try block
    try_end = 0xA3,
    /// Throw top of stack as exception
    throw_ex = 0xA4,

    // === [M] Arithmetic/comparison (0xB0-0xBF) ===

    /// (+ a b) — integer/float
    add = 0xB0,
    /// (- a b) — integer/float
    sub = 0xB1,
    /// (* a b) — integer/float
    mul = 0xB2,
    /// (/ a b) — always float result
    div = 0xB3,
    /// (< a b)
    lt = 0xB4,
    /// (<= a b)
    le = 0xB5,
    /// (> a b)
    gt = 0xB6,
    /// (>= a b)
    ge = 0xB7,
    /// (mod a b) — Clojure mod (result sign follows divisor)
    mod = 0xB8,
    /// (rem a b) — Clojure rem (result sign follows dividend)
    rem_ = 0xB9,
    /// (= a b) — equality check
    eq = 0xBA,
    /// (not= a b) — inequality check
    neq = 0xBB,

    // === [Z] Reserved/debug (0xF0-0xFF) ===

    /// No operation
    nop = 0xF0,
    /// Debug: print top of stack
    debug_print = 0xF1,

    /// Returns true if this opcode uses the operand field.
    pub fn hasOperand(self: OpCode) bool {
        return switch (self) {
            // No operand: these ignore the u16 field
            .nil,
            .true_val,
            .false_val,
            .pop,
            .dup,
            .ret,
            .add,
            .sub,
            .mul,
            .div,
            .lt,
            .le,
            .gt,
            .ge,
            .mod,
            .rem_,
            .eq,
            .neq,
            .lazy_seq,
            .throw_ex,
            .try_end,
            .nop,
            .debug_print,
            => false,
            // All others use the operand
            else => true,
        };
    }
};

/// A single VM instruction: opcode + operand.
pub const Instruction = struct {
    op: OpCode,
    operand: u16 = 0,

    /// Interpret operand as signed (for jump offsets).
    pub fn signedOperand(self: Instruction) i16 {
        return @bitCast(self.operand);
    }
};

// === Tests ===

test "OpCode category ranges" {
    // Constants (0x00-0x0F)
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(OpCode.const_load));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(OpCode.nil));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(OpCode.true_val));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(OpCode.false_val));

    // Stack (0x10-0x1F)
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(OpCode.pop));
    try std.testing.expectEqual(@as(u8, 0x11), @intFromEnum(OpCode.dup));

    // Locals (0x20-0x2F)
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(OpCode.local_load));
    try std.testing.expectEqual(@as(u8, 0x21), @intFromEnum(OpCode.local_store));

    // Upvalues (0x30-0x3F)
    try std.testing.expectEqual(@as(u8, 0x30), @intFromEnum(OpCode.upvalue_load));
    try std.testing.expectEqual(@as(u8, 0x31), @intFromEnum(OpCode.upvalue_store));

    // Vars (0x40-0x4F)
    try std.testing.expectEqual(@as(u8, 0x40), @intFromEnum(OpCode.var_load));
    try std.testing.expectEqual(@as(u8, 0x41), @intFromEnum(OpCode.var_load_dynamic));
    try std.testing.expectEqual(@as(u8, 0x42), @intFromEnum(OpCode.def));
    try std.testing.expectEqual(@as(u8, 0x43), @intFromEnum(OpCode.def_macro));
    try std.testing.expectEqual(@as(u8, 0x44), @intFromEnum(OpCode.defmulti));
    try std.testing.expectEqual(@as(u8, 0x45), @intFromEnum(OpCode.defmethod));

    // Control flow (0x50-0x5F)
    try std.testing.expectEqual(@as(u8, 0x50), @intFromEnum(OpCode.jump));
    try std.testing.expectEqual(@as(u8, 0x51), @intFromEnum(OpCode.jump_if_false));
    try std.testing.expectEqual(@as(u8, 0x54), @intFromEnum(OpCode.jump_back));

    // Functions (0x60-0x6F)
    try std.testing.expectEqual(@as(u8, 0x60), @intFromEnum(OpCode.call));
    try std.testing.expectEqual(@as(u8, 0x65), @intFromEnum(OpCode.tail_call));
    try std.testing.expectEqual(@as(u8, 0x67), @intFromEnum(OpCode.ret));
    try std.testing.expectEqual(@as(u8, 0x68), @intFromEnum(OpCode.closure));

    // Loop/recur (0x70-0x7F)
    try std.testing.expectEqual(@as(u8, 0x71), @intFromEnum(OpCode.recur));

    // Collections (0x80-0x8F)
    try std.testing.expectEqual(@as(u8, 0x80), @intFromEnum(OpCode.list_new));
    try std.testing.expectEqual(@as(u8, 0x81), @intFromEnum(OpCode.vec_new));
    try std.testing.expectEqual(@as(u8, 0x82), @intFromEnum(OpCode.map_new));
    try std.testing.expectEqual(@as(u8, 0x83), @intFromEnum(OpCode.set_new));

    // Exception handling (0xA0-0xAF)
    try std.testing.expectEqual(@as(u8, 0xA0), @intFromEnum(OpCode.try_begin));
    try std.testing.expectEqual(@as(u8, 0xA1), @intFromEnum(OpCode.catch_begin));
    try std.testing.expectEqual(@as(u8, 0xA3), @intFromEnum(OpCode.try_end));
    try std.testing.expectEqual(@as(u8, 0xA4), @intFromEnum(OpCode.throw_ex));

    // Arithmetic (0xB0-0xBF)
    try std.testing.expectEqual(@as(u8, 0xB0), @intFromEnum(OpCode.add));
    try std.testing.expectEqual(@as(u8, 0xB1), @intFromEnum(OpCode.sub));
    try std.testing.expectEqual(@as(u8, 0xB2), @intFromEnum(OpCode.mul));
    try std.testing.expectEqual(@as(u8, 0xB3), @intFromEnum(OpCode.div));
    try std.testing.expectEqual(@as(u8, 0xB4), @intFromEnum(OpCode.lt));
    try std.testing.expectEqual(@as(u8, 0xB5), @intFromEnum(OpCode.le));
    try std.testing.expectEqual(@as(u8, 0xB6), @intFromEnum(OpCode.gt));
    try std.testing.expectEqual(@as(u8, 0xB7), @intFromEnum(OpCode.ge));
    try std.testing.expectEqual(@as(u8, 0xB8), @intFromEnum(OpCode.mod));
    try std.testing.expectEqual(@as(u8, 0xB9), @intFromEnum(OpCode.rem_));
    try std.testing.expectEqual(@as(u8, 0xBA), @intFromEnum(OpCode.eq));
    try std.testing.expectEqual(@as(u8, 0xBB), @intFromEnum(OpCode.neq));

    // Debug (0xF0-0xFF)
    try std.testing.expectEqual(@as(u8, 0xF0), @intFromEnum(OpCode.nop));
    try std.testing.expectEqual(@as(u8, 0xF1), @intFromEnum(OpCode.debug_print));
}

test "Instruction creation and signedOperand" {
    // Basic instruction with operand
    const instr = Instruction{ .op = .const_load, .operand = 42 };
    try std.testing.expectEqual(OpCode.const_load, instr.op);
    try std.testing.expectEqual(@as(u16, 42), instr.operand);

    // Default operand is 0
    const nop = Instruction{ .op = .nop };
    try std.testing.expectEqual(@as(u16, 0), nop.operand);

    // signedOperand for positive jump
    const jump_fwd = Instruction{ .op = .jump, .operand = 10 };
    try std.testing.expectEqual(@as(i16, 10), jump_fwd.signedOperand());

    // signedOperand for negative jump (backward)
    const neg: i16 = -5;
    const jump_back = Instruction{ .op = .jump_back, .operand = @bitCast(neg) };
    try std.testing.expectEqual(@as(i16, -5), jump_back.signedOperand());
}

test "OpCode.hasOperand classification" {
    // Opcodes that use operand
    try std.testing.expect(OpCode.const_load.hasOperand());
    try std.testing.expect(OpCode.local_load.hasOperand());
    try std.testing.expect(OpCode.local_store.hasOperand());
    try std.testing.expect(OpCode.call.hasOperand());
    try std.testing.expect(OpCode.jump.hasOperand());
    try std.testing.expect(OpCode.jump_if_false.hasOperand());
    try std.testing.expect(OpCode.closure.hasOperand());
    try std.testing.expect(OpCode.list_new.hasOperand());
    try std.testing.expect(OpCode.def.hasOperand());
    try std.testing.expect(OpCode.recur.hasOperand());

    // Opcodes that ignore operand
    try std.testing.expect(!OpCode.nil.hasOperand());
    try std.testing.expect(!OpCode.true_val.hasOperand());
    try std.testing.expect(!OpCode.false_val.hasOperand());
    try std.testing.expect(!OpCode.pop.hasOperand());
    try std.testing.expect(!OpCode.dup.hasOperand());
    try std.testing.expect(!OpCode.ret.hasOperand());
    try std.testing.expect(!OpCode.nop.hasOperand());
    try std.testing.expect(!OpCode.add.hasOperand());
    try std.testing.expect(!OpCode.throw_ex.hasOperand());
    try std.testing.expect(!OpCode.try_end.hasOperand());
}
