// SPDX-License-Identifier: EPL-2.0
//! Compiles an analyzed Node tree into an immutable `BytecodeChunk`.
//!
//! The compiler mirrors the TreeWalk backend's observable behaviour
//! (ADR-0005 / ADR-0022). It is a state-holding struct that grows
//! mutable instruction and constant ArrayLists while walking the
//! Node tree, then `finalize`s by duping the slices into the caller's
//! arena so the resulting chunk is immutable.
//!
//! Phase-1/2 special forms (`def` / `if` / `do` / `quote` / `let*` /
//! `fn*` / call) land across the early §9.6 / 4.5 cycles. The first
//! cycle handles `constant` Nodes (the leaf case all other forms
//! decompose into); subsequent cycles widen the `compileNode`
//! switch arm-by-arm.

const std = @import("std");
const node_mod = @import("../../node.zig");
const opcode_mod = @import("opcode.zig");
const value_mod = @import("../../../runtime/value.zig");
const env_mod = @import("../../../runtime/env.zig");

const Node = node_mod.Node;
const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const Value = value_mod.Value;

pub const Error = error{
    TooManyConstants,
    JumpTooFar,
    TooManyCallArgs,
    NotImplemented,
} || std.mem.Allocator.Error;

/// One-shot entry: compile `root` into a finalised `BytecodeChunk`.
/// The chunk's slices are owned by `arena` (analyzer-arena lifetime).
pub fn compile(arena: std.mem.Allocator, root: *const Node) Error!BytecodeChunk {
    var c: Compiler = .init(arena);
    defer c.deinit();
    try c.compileNode(root);
    try c.emit(.op_ret, 0);
    return try c.finalize();
}

const Compiler = struct {
    arena: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    constants: std.ArrayList(Value),

    fn init(arena: std.mem.Allocator) Compiler {
        return .{
            .arena = arena,
            .instructions = .empty,
            .constants = .empty,
        };
    }

    fn deinit(self: *Compiler) void {
        self.instructions.deinit(self.arena);
        self.constants.deinit(self.arena);
    }

    fn compileNode(self: *Compiler, node: *const Node) Error!void {
        switch (node.*) {
            .constant => |n| try self.emitConst(n.value),
            .quote_node => |n| try self.emitConst(n.quoted),
            .do_node => |n| try self.compileDo(n.forms),
            .local_ref => |n| try self.emit(.op_load_local, n.index),
            .var_ref => |n| try self.compileVarRef(n),
            .if_node => |n| try self.compileIf(n),
            .let_node => |n| try self.compileLet(n),
            .call_node => |n| try self.compileCall(n),
            else => {
                // The VM backend is dev-only until task 4.8 flips
                // `-Dbackend=vm`; no user-facing path reaches the
                // compiler yet. Per `no_op_stub_forbidden.md`,
                // internal-only paths may return `error.NotImplemented`
                // until the §9.6 / 4.5 cycles widen this switch.
                return error.NotImplemented;
            },
        }
    }

    fn emitConst(self: *Compiler, v: Value) Error!void {
        const idx = try self.addConstant(v);
        try self.emit(.op_const, idx);
    }

    fn compileDo(self: *Compiler, forms: []const Node) Error!void {
        if (forms.len == 0) {
            try self.emitConst(Value.nil_val);
            return;
        }
        for (forms[0 .. forms.len - 1]) |*f| {
            try self.compileNode(f);
            try self.emit(.op_pop, 0);
        }
        try self.compileNode(&forms[forms.len - 1]);
    }

    fn compileIf(self: *Compiler, n: node_mod.IfNode) Error!void {
        try self.compileNode(n.cond);
        const jif = try self.emitJump(.op_jump_if_false);
        try self.compileNode(n.then_branch);
        const jend = try self.emitJump(.op_jump);
        try self.patchJump(jif);
        if (n.else_branch) |eb| {
            try self.compileNode(eb);
        } else {
            try self.emitConst(Value.nil_val);
        }
        try self.patchJump(jend);
    }

    fn compileLet(self: *Compiler, n: node_mod.LetNode) Error!void {
        for (n.bindings) |b| {
            try self.compileNode(b.value_expr);
            try self.emit(.op_store_local, b.index);
        }
        try self.compileNode(n.body);
    }

    fn compileVarRef(self: *Compiler, n: node_mod.VarRef) Error!void {
        // The analyzer has already resolved the Var pointer. Encode it
        // as a heap-tagged Value, stash it in the constant pool, and
        // emit `op_get_var <idx>` — the VM dispatch loop decodes the
        // pointer and calls `Var.deref`.
        const var_value = Value.encodeHeapPtr(.var_ref, n.var_ptr);
        const idx = try self.addConstant(var_value);
        try self.emit(.op_get_var, idx);
    }

    fn compileCall(self: *Compiler, n: node_mod.CallNode) Error!void {
        try self.compileNode(n.callee);
        if (n.args.len > std.math.maxInt(u16)) return error.TooManyCallArgs;
        for (n.args) |*a| try self.compileNode(a);
        try self.emit(.op_call, @intCast(n.args.len));
    }

    /// Emit a jump opcode with a placeholder operand and return the
    /// instruction index so `patchJump` can fill in the offset once
    /// the target is known.
    fn emitJump(self: *Compiler, op: Opcode) Error!usize {
        const idx = self.instructions.items.len;
        try self.emit(op, 0);
        return idx;
    }

    /// Patch a previously emitted jump to land on the next instruction
    /// to be emitted. Offset is relative to the instruction *after*
    /// the jump (so 0 means "fall through").
    fn patchJump(self: *Compiler, jump_index: usize) Error!void {
        const offset = self.instructions.items.len - jump_index - 1;
        if (offset > std.math.maxInt(i16)) return error.JumpTooFar;
        self.instructions.items[jump_index].operand = @as(u16, @bitCast(@as(i16, @intCast(offset))));
    }

    fn emit(self: *Compiler, op: Opcode, operand: u16) Error!void {
        try self.instructions.append(self.arena, .{ .opcode = op, .operand = operand });
    }

    fn addConstant(self: *Compiler, v: Value) Error!u16 {
        if (self.constants.items.len > std.math.maxInt(u16)) return error.TooManyConstants;
        const idx: u16 = @intCast(self.constants.items.len);
        try self.constants.append(self.arena, v);
        return idx;
    }

    fn finalize(self: *Compiler) Error!BytecodeChunk {
        const instrs = try self.arena.dupe(Instruction, self.instructions.items);
        const consts = try self.arena.dupe(Value, self.constants.items);
        return .{ .instructions = instrs, .constants = consts };
    }
};

const testing = std.testing;

test "compile constant emits op_const + op_ret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node: Node = .{ .constant = .{ .value = Value.nil_val } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "compile records each constant exactly once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node: Node = .{ .constant = .{ .value = Value.true_val } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.true_val, chunk.constants[0]);
}

test "compile quote pushes the quoted value as a constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node: Node = .{ .quote_node = .{ .quoted = Value.false_val } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.false_val, chunk.constants[0]);
}

test "compile empty do yields nil constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node: Node = .{ .do_node = .{ .forms = &.{} } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "compile local_ref emits op_load_local with slot index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const node: Node = .{ .local_ref = .{ .name = "x", .index = 3 } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_load_local, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 3), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
}

test "compile if emits jump_if_false + jump with patched offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cond: Node = .{ .constant = .{ .value = Value.true_val } };
    const then_b: Node = .{ .constant = .{ .value = Value.false_val } };
    const else_b: Node = .{ .constant = .{ .value = Value.nil_val } };
    const node: Node = .{ .if_node = .{ .cond = &cond, .then_branch = &then_b, .else_branch = &else_b } };
    const chunk = try compile(arena.allocator(), &node);

    // op_const cond ; op_jump_if_false +2 ; op_const then ; op_jump +1 ; op_const else ; op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_jump_if_false, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(i16, 2), @as(i16, @bitCast(chunk.instructions[1].operand)));
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_jump, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(i16, 1), @as(i16, @bitCast(chunk.instructions[3].operand)));
    try testing.expectEqual(Opcode.op_const, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
}

test "compile if without else branch emits nil for the alternative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cond: Node = .{ .constant = .{ .value = Value.true_val } };
    const then_b: Node = .{ .constant = .{ .value = Value.false_val } };
    const node: Node = .{ .if_node = .{ .cond = &cond, .then_branch = &then_b, .else_branch = null } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[4].opcode);
    // The synthesized nil constant lives at index 2 in the pool.
    try testing.expectEqual(Value.nil_val, chunk.constants[chunk.instructions[4].operand]);
}

test "compile let* stores each binding then evaluates the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v0: Node = .{ .constant = .{ .value = Value.true_val } };
    const v1: Node = .{ .constant = .{ .value = Value.false_val } };
    const body: Node = .{ .local_ref = .{ .name = "y", .index = 1 } };
    const bindings = [_]node_mod.LetNode.Binding{
        .{ .name = "x", .index = 0, .value_expr = &v0 },
        .{ .name = "y", .index = 1, .value_expr = &v1 },
    };
    const node: Node = .{ .let_node = .{ .bindings = &bindings, .body = &body } };
    const chunk = try compile(arena.allocator(), &node);

    // op_const true ; op_store_local 0 ; op_const false ; op_store_local 1 ; op_load_local 1 ; op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[1].operand);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(u16, 1), chunk.instructions[3].operand);
    try testing.expectEqual(Opcode.op_load_local, chunk.instructions[4].opcode);
    try testing.expectEqual(@as(u16, 1), chunk.instructions[4].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
}

test "compile var_ref stores the Var pointer Value and emits op_get_var" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The test does not deref the Var; it only checks that the
    // compiler encodes the pointer into the constant pool and emits
    // op_get_var with the correct index.
    var dummy_ns: env_mod.Namespace = undefined;
    var dummy_var: env_mod.Var = .{ .ns = &dummy_ns, .name = "x" };
    const node: Node = .{ .var_ref = .{ .var_ptr = &dummy_var } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_get_var, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.encodeHeapPtr(.var_ref, &dummy_var), chunk.constants[0]);
}

test "compile call emits callee, args, op_call <arity>" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const callee: Node = .{ .constant = .{ .value = Value.true_val } };
    const args = [_]Node{
        .{ .constant = .{ .value = Value.false_val } },
        .{ .constant = .{ .value = Value.nil_val } },
    };
    const node: Node = .{ .call_node = .{ .callee = &callee, .args = &args } };
    const chunk = try compile(arena.allocator(), &node);

    // op_const callee ; op_const arg0 ; op_const arg1 ; op_call 2 ; op_ret
    try testing.expectEqual(@as(usize, 5), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_call, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(u16, 2), chunk.instructions[3].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[4].opcode);
}

test "compile call with zero args emits op_call 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const callee: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .call_node = .{ .callee = &callee, .args = &.{} } };
    const chunk = try compile(arena.allocator(), &node);

    try testing.expectEqual(@as(usize, 3), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_call, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[1].operand);
}

test "compile do pops intermediate forms and keeps the last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const forms = [_]Node{
        .{ .constant = .{ .value = Value.true_val } },
        .{ .constant = .{ .value = Value.false_val } },
        .{ .constant = .{ .value = Value.nil_val } },
    };
    const node: Node = .{ .do_node = .{ .forms = &forms } };
    const chunk = try compile(arena.allocator(), &node);

    // Expected: op_const 0; op_pop; op_const 1; op_pop; op_const 2; op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_pop, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_pop, chunk.instructions[3].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
    try testing.expectEqual(@as(usize, 3), chunk.constants.len);
}
