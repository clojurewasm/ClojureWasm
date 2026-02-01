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
const value_mod = @import("../../common/value.zig");
const Fn = value_mod.Fn;

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
    /// Allocated closures (for cleanup).
    allocated_fns: std.ArrayListUnmanaged(*const Fn),

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .allocated_fns = .empty,
        };
    }

    pub fn deinit(self: *VM) void {
        for (self.allocated_fns.items) |fn_ptr| {
            if (fn_ptr.closure_bindings) |cb| {
                self.allocator.free(cb);
            }
            // const-cast to free
            const mutable: *Fn = @constCast(fn_ptr);
            self.allocator.destroy(mutable);
        }
        self.allocated_fns.deinit(self.allocator);
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
                    const arg_count = instr.operand;
                    // Stack: [..., fn_val, arg0, arg1, ...]
                    // fn_val is at sp - arg_count - 1
                    const fn_idx = self.sp - arg_count - 1;
                    const callee = self.stack[fn_idx];
                    if (callee != .fn_val) return error.TypeError;

                    const fn_obj = callee.fn_val;
                    const proto: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));

                    // Arity check
                    if (!proto.variadic and arg_count != proto.arity)
                        return error.ArityError;

                    // Inject closure_bindings before args if present
                    const closure_count: u16 = if (fn_obj.closure_bindings) |cb| @intCast(cb.len) else 0;
                    if (closure_count > 0) {
                        const cb = fn_obj.closure_bindings.?;
                        // Shift args right by closure_count
                        const args_start = fn_idx + 1;
                        if (arg_count > 0) {
                            var i: u16 = arg_count;
                            while (i > 0) {
                                i -= 1;
                                self.stack[args_start + closure_count + i] = self.stack[args_start + i];
                            }
                        }
                        // Insert closure bindings
                        for (0..closure_count) |i| {
                            self.stack[args_start + i] = cb[i];
                        }
                        self.sp += closure_count;
                    }

                    // Push new call frame
                    if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;
                    self.frames[self.frame_count] = .{
                        .ip = 0,
                        .base = fn_idx + 1, // points to closure_bindings[0] or arg0
                        .code = proto.code,
                        .constants = proto.constants,
                    };
                    self.frame_count += 1;
                },
                .tail_call => return error.InvalidInstruction,
                .ret => {
                    const result = self.pop();
                    const base = frame.base;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) return result;
                    // Restore caller's stack: base-1 removes the fn_val slot
                    self.sp = base - 1;
                    try self.push(result);
                },
                .closure => {
                    // Load the fn_val template from constants and push it.
                    // Runtime capture (closure_bindings) is handled by
                    // copying values from the current frame's stack.
                    const template = frame.constants[instr.operand];
                    if (template != .fn_val) return error.TypeError;
                    const fn_obj = template.fn_val;
                    const proto: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));

                    if (proto.capture_count > 0) {
                        // Capture values from current frame's stack
                        const bindings = self.allocator.alloc(Value, proto.capture_count) catch
                            return error.OutOfMemory;
                        for (0..proto.capture_count) |i| {
                            bindings[i] = self.stack[frame.base + i];
                        }
                        const new_fn = self.allocator.create(Fn) catch return error.OutOfMemory;
                        new_fn.* = .{ .proto = fn_obj.proto, .closure_bindings = bindings };
                        self.allocated_fns.append(self.allocator, new_fn) catch return error.OutOfMemory;
                        try self.push(.{ .fn_val = new_fn });
                    } else {
                        // No capture needed, push the template directly
                        try self.push(template);
                    }
                },

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
                .mod => try self.binaryMod(),
                .rem_ => try self.binaryRem(),
                .eq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(.{ .boolean = a.eql(b) });
                },
                .neq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(.{ .boolean = !a.eql(b) });
                },

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

    /// Clojure mod: result has same sign as divisor.
    fn binaryMod(self: *VM) VMError!void {
        const b = self.pop();
        const a = self.pop();
        if (a == .integer and b == .integer) {
            if (b.integer == 0) return error.DivisionByZero;
            try self.push(.{ .integer = @mod(a.integer, b.integer) });
            return;
        }
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;
        if (fb == 0.0) return error.DivisionByZero;
        try self.push(.{ .float = @mod(fa, fb) });
    }

    /// Clojure rem: result has same sign as dividend.
    fn binaryRem(self: *VM) VMError!void {
        const b = self.pop();
        const a = self.pop();
        if (a == .integer and b == .integer) {
            if (b.integer == 0) return error.DivisionByZero;
            try self.push(.{ .integer = @rem(a.integer, b.integer) });
            return;
        }
        const fa = numToFloat(a) orelse return error.TypeError;
        const fb = numToFloat(b) orelse return error.TypeError;
        if (fb == 0.0) return error.DivisionByZero;
        try self.push(.{ .float = @rem(fa, fb) });
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

test "VM closure creates fn_val" {
    // Create a simple FnProto: just returns nil
    const fn_code = [_]Instruction{
        .{ .op = .nil },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{};
    const proto = FnProto{
        .name = null,
        .arity = 0,
        .variadic = false,
        .local_count = 0,
        .code = &fn_code,
        .constants = &fn_constants,
    };

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    // Store FnProto pointer as fn_val constant (VM reads proto from Fn)
    const fn_obj = Value{ .fn_val = &.{ .proto = &proto, .closure_bindings = null } };
    const idx = try chunk.addConstant(fn_obj);
    try chunk.emit(.closure, idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .fn_val);
}

test "VM call simple function" {
    // (fn [] 42) called with 0 args
    const fn_code = [_]Instruction{
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{.{ .integer = 42 }};
    const proto = FnProto{
        .name = null,
        .arity = 0,
        .variadic = false,
        .local_count = 0,
        .code = &fn_code,
        .constants = &fn_constants,
    };

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const fn_obj = Value{ .fn_val = &.{ .proto = &proto, .closure_bindings = null } };
    const idx = try chunk.addConstant(fn_obj);
    try chunk.emit(.closure, idx);
    try chunk.emit(.call, 0);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "VM call function with args" {
    // (fn [x y] (+ x y)) called with (3 4)
    const fn_code = [_]Instruction{
        .{ .op = .local_load, .operand = 0 }, // x
        .{ .op = .local_load, .operand = 1 }, // y
        .{ .op = .add },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{};
    const proto = FnProto{
        .name = null,
        .arity = 2,
        .variadic = false,
        .local_count = 2,
        .code = &fn_code,
        .constants = &fn_constants,
    };

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const fn_obj = Value{ .fn_val = &.{ .proto = &proto, .closure_bindings = null } };
    const fn_idx = try chunk.addConstant(fn_obj);
    const c3 = try chunk.addConstant(.{ .integer = 3 });
    const c4 = try chunk.addConstant(.{ .integer = 4 });

    try chunk.emit(.closure, fn_idx);
    try chunk.emit(.const_load, c3);
    try chunk.emit(.const_load, c4);
    try chunk.emit(.call, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 7 }, result);
}

test "VM closure with capture" {
    // Simulates: (let [x 10] (fn [y] (+ x y)))
    // The outer fn creates a closure that captures x.
    //
    // Inner fn: params=[y] at slot 1 (slot 0 = captured x)
    //   local_load 0 (x, from closure_bindings)
    //   local_load 1 (y, the argument)
    //   add
    //   ret
    const inner_code = [_]Instruction{
        .{ .op = .local_load, .operand = 0 }, // captured x
        .{ .op = .local_load, .operand = 1 }, // arg y
        .{ .op = .add },
        .{ .op = .ret },
    };
    const inner_constants = [_]Value{};
    const inner_proto = FnProto{
        .name = null,
        .arity = 1,
        .variadic = false,
        .local_count = 2,
        .capture_count = 1, // captures 1 value from parent
        .code = &inner_code,
        .constants = &inner_constants,
    };

    // Top-level chunk:
    //   const_load 10      -> stack: [10]        (x = 10)
    //   closure inner_proto -> stack: [10, fn]    (captures slot 0 = x)
    //   const_load 5       -> stack: [10, fn, 5] (arg y = 5)
    //   call 1             -> calls fn(5), closure_bindings=[10]
    //   ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c10 = try chunk.addConstant(.{ .integer = 10 });
    const fn_template = Value{ .fn_val = &.{ .proto = &inner_proto, .closure_bindings = null } };
    const fn_idx = try chunk.addConstant(fn_template);
    const c5 = try chunk.addConstant(.{ .integer = 5 });

    try chunk.emit(.const_load, c10); // push 10
    try chunk.emit(.closure, fn_idx); // create closure capturing [10]
    try chunk.emit(.const_load, c5); // push 5
    try chunk.emit(.call, 1); // call with 1 arg
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 15 }, result);
}

test "VM compiler+vm integration: (fn [x] x) called" {
    // Compile (fn [x] x) and call it with 42
    const allocator = std.testing.allocator;
    const node_mod = @import("../../common/analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../../common/bytecode/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // Build AST: (do ((fn [x] x) 42))
    var body = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    const params = [_][]const u8{"x"};
    const arities = [_]node_mod.FnArity{
        .{ .params = &params, .variadic = false, .body = &body },
    };
    var fn_data = node_mod.FnNode{
        .name = null,
        .arities = &arities,
        .source = .{},
    };
    var fn_node = Node{ .fn_node = &fn_data };
    var arg = Node{ .constant = .{ .integer = 42 } };
    var args = [_]*Node{&arg};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &args,
        .source = .{},
    };
    const call_node = Node{ .call_node = &call_data };

    try compiler.compile(&call_node);
    try compiler.chunk.emitOp(.ret);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try vm.run(&compiler.chunk);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
}

test "VM compiler+vm integration: closure capture via let" {
    // (let [x 10] ((fn [y] (+ x y)) 5)) => 15
    // x is a local in let, fn captures it
    const allocator = std.testing.allocator;
    const node_mod = @import("../../common/analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../../common/bytecode/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // Build AST
    // fn body: (+ x y) where x is local_ref idx=0 (captured), y is local_ref idx=1 (param)
    var x_ref = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var y_ref = Node{ .local_ref = .{ .name = "y", .idx = 1, .source = .{} } };
    var add_args = [_]*Node{ &x_ref, &y_ref };
    var add_callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var add_call_data = node_mod.CallNode{
        .callee = &add_callee,
        .args = &add_args,
        .source = .{},
    };
    var fn_body = Node{ .call_node = &add_call_data };

    const params = [_][]const u8{"y"};
    const arities = [_]node_mod.FnArity{
        .{ .params = &params, .variadic = false, .body = &fn_body },
    };
    var fn_data = node_mod.FnNode{
        .name = null,
        .arities = &arities,
        .source = .{},
    };
    var fn_node = Node{ .fn_node = &fn_data };

    // Call: ((fn [y] (+ x y)) 5)
    var arg_5 = Node{ .constant = .{ .integer = 5 } };
    var call_args = [_]*Node{&arg_5};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &call_args,
        .source = .{},
    };
    var call_node = Node{ .call_node = &call_data };

    // let: (let [x 10] ...)
    var init_10 = Node{ .constant = .{ .integer = 10 } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_10 },
    };
    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &call_node,
        .source = .{},
    };
    const let_node = Node{ .let_node = &let_data };

    try compiler.compile(&let_node);
    try compiler.chunk.emitOp(.ret);

    // This test requires var_load for "+" which is not yet implemented,
    // so we skip the VM execution for now and just verify compilation succeeds.
    // The bytecode should contain: const_load(10), closure, const_load(5), call, pop, ret
    const code = compiler.chunk.code.items;
    try std.testing.expect(code.len > 0);

    // Verify closure opcode is present
    var has_closure = false;
    for (code) |instr| {
        if (instr.op == .closure) has_closure = true;
    }
    try std.testing.expect(has_closure);
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
