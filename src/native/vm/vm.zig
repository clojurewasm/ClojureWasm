//! Bytecode Virtual Machine.
//!
//! Stack-based VM that executes compiled bytecode (Chunk).
//! Instantiated design: no threadlocal, VM is an explicit struct.
//!
//! Pipeline:
//!   Form (Reader) -> Node (Analyzer) -> Bytecode (Compiler) -> Value (VM)

const std = @import("std");
const chunk_mod = @import("../../common/bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Instruction = chunk_mod.Instruction;
const FnProto = chunk_mod.FnProto;
const Value = chunk_mod.Value;

/// VM execution errors.
pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    ArityError,
    UndefinedVar,
    OutOfMemory,
    InvalidInstruction,
    DivisionByZero,
    Overflow,
};

const STACK_MAX: usize = 256 * 64;
const FRAMES_MAX: usize = 64;

/// Call frame — tracks execution state for a function invocation.
const CallFrame = struct {
    ip: usize,
    base: usize,
    code: []const Instruction,
    constants: []const Value,
};

/// Stack-based bytecode virtual machine.
pub const VM = struct {
    allocator: std.mem.Allocator,
    stack: [STACK_MAX]Value,
    sp: usize,
    frames: [FRAMES_MAX]CallFrame,
    frame_count: usize,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
        };
    }

    /// Execute a compiled Chunk and return the result.
    pub fn run(self: *VM, c: *const Chunk) VMError!Value {
        self.frames[0] = .{
            .ip = 0,
            .base = 0,
            .code = c.code.items,
            .constants = c.constants.items,
        };
        self.frame_count = 1;
        return self.execute();
    }

    fn execute(self: *VM) VMError!Value {
        while (true) {
            const frame = &self.frames[self.frame_count - 1];
            if (frame.ip >= frame.code.len) {
                return if (self.sp > 0) self.pop() else .nil;
            }

            const instr = frame.code[frame.ip];
            frame.ip += 1;

            switch (instr.op) {
                // [A] Constants
                .const_load => try self.push(frame.constants[instr.operand]),
                .nil => try self.push(.nil),
                .true_val => try self.push(.{ .boolean = true }),
                .false_val => try self.push(.{ .boolean = false }),

                // [B] Stack
                .pop => _ = self.pop(),
                .dup => {
                    const val = self.peek(0);
                    try self.push(val);
                },

                // [C] Locals
                .local_load => {
                    const idx = frame.base + instr.operand;
                    if (idx >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[idx]);
                },
                .local_store => {
                    const idx = frame.base + instr.operand;
                    self.stack[idx] = self.pop();
                },

                // [F] Control flow
                .jump => {
                    const offset = instr.signedOperand();
                    if (offset < 0) {
                        frame.ip -= @intCast(-offset);
                    } else {
                        frame.ip += @intCast(offset);
                    }
                },
                .jump_if_false => {
                    const val = self.pop();
                    if (!val.isTruthy()) {
                        frame.ip += instr.operand;
                    }
                },
                .jump_back => {
                    frame.ip -= instr.operand;
                },

                // [G] Functions
                .call => {
                    // Placeholder: not yet implemented
                    return error.InvalidInstruction;
                },
                .tail_call => return error.InvalidInstruction,
                .ret => {
                    const result = self.pop();
                    self.frame_count -= 1;
                    if (self.frame_count == 0) return result;
                    // Restore caller's stack
                    self.sp = frame.base;
                    try self.push(result);
                },
                .closure => return error.InvalidInstruction,

                // [H] Loop/recur
                .recur => return error.InvalidInstruction,

                // [I] Collections
                .list_new, .vec_new, .map_new, .set_new => {
                    // Placeholder: collect N values from stack
                    return error.InvalidInstruction;
                },

                // [E] Var operations
                .var_load, .var_load_dynamic => return error.InvalidInstruction,
                .def => return error.InvalidInstruction,

                // [K] Exceptions
                .try_begin, .catch_begin, .try_end, .throw_ex => {
                    return error.InvalidInstruction;
                },

                // [M] Arithmetic
                .add => try self.binaryArith(.add),
                .sub => try self.binaryArith(.sub),
                .mul => try self.binaryArith(.mul),
                .div => try self.binaryArith(.div),
                .lt => try self.binaryCompare(.lt),
                .le => try self.binaryCompare(.le),
                .gt => try self.binaryCompare(.gt),
                .ge => try self.binaryCompare(.ge),

                // [Z] Debug
                .nop => {},
                .debug_print => _ = self.pop(),

                // Upvalues (deferred to Task 2.8)
                .upvalue_load, .upvalue_store => return error.InvalidInstruction,
            }
        }
    }

    fn push(self: *VM, val: Value) VMError!void {
        if (self.sp >= STACK_MAX) return error.StackOverflow;
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) Value {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack[self.sp - 1 - distance];
    }

    // --- Arithmetic helpers ---

    const ArithOp = enum { add, sub, mul, div };

    fn binaryArith(self: *VM, op: ArithOp) VMError!void {
        const b = self.pop();
        const a = self.pop();

        // Division always promotes to float (Clojure semantics: / returns Ratio,
        // but we use float as approximation until Ratio type is implemented).
        // See decisions.md D12.
        if (op == .div) {
            const fa = numToFloat(a) orelse return error.TypeError;
            const fb = numToFloat(b) orelse return error.TypeError;
            if (fb == 0.0) return error.DivisionByZero;
            try self.push(.{ .float = fa / fb });
            return;
        }

        // Both integers: stay in integer domain (add, sub, mul)
        if (a == .integer and b == .integer) {
            const result: Value = switch (op) {
                .add => .{ .integer = a.integer + b.integer },
                .sub => .{ .integer = a.integer - b.integer },
                .mul => .{ .integer = a.integer * b.integer },
                .div => unreachable, // handled above
            };
            try self.push(result);
            return;
        }

        // Mixed int/float: promote to float
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;

        const result: f64 = switch (op) {
            .add => fa + fb,
            .sub => fa - fb,
            .mul => fa * fb,
            .div => unreachable, // handled above
        };
        try self.push(.{ .float = result });
    }

    const CmpOp = enum { lt, le, gt, ge };

    fn binaryCompare(self: *VM, op: CmpOp) VMError!void {
        const b = self.pop();
        const a = self.pop();

        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;

        const result: bool = switch (op) {
            .lt => fa < fb,
            .le => fa <= fb,
            .gt => fa > fb,
            .ge => fa >= fb,
        };
        try self.push(.{ .boolean = result });
    }

    fn numToFloat(val: Value) ?f64 {
        return switch (val) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }
};

// === Tests ===

test "VM run nil constant" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.emitOp(.nil);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.nil, result);
}

test "VM run true/false constants" {
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        try chunk.emitOp(.true_val);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .boolean = true }, result);
    }
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        try chunk.emitOp(.false_val);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .boolean = false }, result);
    }
}

test "VM run const_load integer" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(.{ .integer = 42 });
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "VM pop discards value" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.emitOp(.true_val); // push true
    try chunk.emitOp(.pop); // discard
    try chunk.emitOp(.nil); // push nil
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.nil, result);
}

test "VM dup duplicates top" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(.{ .integer = 7 });
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.dup);
    try chunk.emitOp(.pop); // pop the duplicate
    try chunk.emitOp(.ret); // return original

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 7 }, result);
}

test "VM local_load and local_store" {
    // Simulate: push 10, store slot 0, push 20, store slot 1, load slot 0, ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c10 = try chunk.addConstant(.{ .integer = 10 });
    const c20 = try chunk.addConstant(.{ .integer = 20 });
    try chunk.emit(.const_load, c10); // stack: [10]
    try chunk.emit(.const_load, c20); // stack: [10, 20]
    try chunk.emit(.local_load, 0); // push slot 0 (=10) -> stack: [10, 20, 10]
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 10 }, result);
}

test "VM jump_if_false (if true 1 2)" {
    // Bytecode for (if true 1 2):
    // true_val, jump_if_false +2, const_load(1), jump +1, const_load(2), ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(.{ .integer = 1 });
    const c2 = try chunk.addConstant(.{ .integer = 2 });

    try chunk.emitOp(.true_val); // 0
    const jif = try chunk.emitJump(.jump_if_false); // 1
    try chunk.emit(.const_load, c1); // 2: then
    const jmp = try chunk.emitJump(.jump); // 3
    chunk.patchJump(jif); // jump_if_false -> skip to 4
    try chunk.emit(.const_load, c2); // 4: else
    chunk.patchJump(jmp); // jump -> skip to 5
    try chunk.emitOp(.ret); // 5

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 1 }, result);
}

test "VM jump_if_false (if false 1 2)" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(.{ .integer = 1 });
    const c2 = try chunk.addConstant(.{ .integer = 2 });

    try chunk.emitOp(.false_val); // 0
    const jif = try chunk.emitJump(.jump_if_false); // 1
    try chunk.emit(.const_load, c1); // 2: then
    const jmp = try chunk.emitJump(.jump); // 3
    chunk.patchJump(jif);
    try chunk.emit(.const_load, c2); // 4: else
    chunk.patchJump(jmp);
    try chunk.emitOp(.ret); // 5

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 2 }, result);
}

test "VM integer arithmetic" {
    // (+ 3 4) = 7
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c3 = try chunk.addConstant(.{ .integer = 3 });
        const c4 = try chunk.addConstant(.{ .integer = 4 });
        try chunk.emit(.const_load, c3);
        try chunk.emit(.const_load, c4);
        try chunk.emitOp(.add);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .integer = 7 }, result);
    }
    // (- 10 3) = 7
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c10 = try chunk.addConstant(.{ .integer = 10 });
        const c3 = try chunk.addConstant(.{ .integer = 3 });
        try chunk.emit(.const_load, c10);
        try chunk.emit(.const_load, c3);
        try chunk.emitOp(.sub);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .integer = 7 }, result);
    }
    // (* 6 7) = 42
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c6 = try chunk.addConstant(.{ .integer = 6 });
        const c7 = try chunk.addConstant(.{ .integer = 7 });
        try chunk.emit(.const_load, c6);
        try chunk.emit(.const_load, c7);
        try chunk.emitOp(.mul);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .integer = 42 }, result);
    }
}

test "VM comparison operators" {
    // (< 1 2) = true
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c1 = try chunk.addConstant(.{ .integer = 1 });
        const c2 = try chunk.addConstant(.{ .integer = 2 });
        try chunk.emit(.const_load, c1);
        try chunk.emit(.const_load, c2);
        try chunk.emitOp(.lt);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .boolean = true }, result);
    }
    // (> 1 2) = false
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c1 = try chunk.addConstant(.{ .integer = 1 });
        const c2 = try chunk.addConstant(.{ .integer = 2 });
        try chunk.emit(.const_load, c1);
        try chunk.emit(.const_load, c2);
        try chunk.emitOp(.gt);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value{ .boolean = false }, result);
    }
}

test "VM float arithmetic" {
    // (+ 1.5 2.5) = 4.0
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const c1 = try chunk.addConstant(.{ .float = 1.5 });
    const c2 = try chunk.addConstant(.{ .float = 2.5 });
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emitOp(.add);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .float = 4.0 }, result);
}

test "VM mixed int/float arithmetic" {
    // (+ 1 2.5) = 3.5
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const c1 = try chunk.addConstant(.{ .integer = 1 });
    const c2 = try chunk.addConstant(.{ .float = 2.5 });
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emitOp(.add);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .float = 3.5 }, result);
}

test "VM nop does nothing" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const idx = try chunk.addConstant(.{ .integer = 99 });
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.nop);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 99 }, result);
}
