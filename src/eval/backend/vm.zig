// SPDX-License-Identifier: EPL-2.0
//! Bytecode VM dispatch loop — the second backend (ROADMAP §9.6 / 4.6,
//! ADR-0005). `eval` consumes a `BytecodeChunk` produced by
//! `vm/compiler.zig` and executes its instructions against a per-frame
//! operand stack of `OPERAND_STACK_MAX` Values, mirroring TreeWalk's
//! `MAX_LOCALS` discipline so the recursion bound matches across
//! backends.
//!
//! Per ADR-0022 the VM must produce bit-for-bit identical Values to
//! TreeWalk for the same source. Errors raised here therefore reuse
//! TreeWalk's `error_catalog` Codes; control-flow signals
//! (`error.RecurSignaled`, `error.ThrownValue`) use the same Zig errors
//! so a shared try/loop driver works across backends at task 4.7.
//!
//! Dispatch shape is a single `switch (Opcode)` per ROADMAP §9.6.
//! Computed-goto is deferred; only the hot `op_const` / `op_ret` arms
//! carry `@branchHint(.likely)`.

const std = @import("std");
const node_mod = @import("../node.zig");
const opcode_mod = @import("vm/opcode.zig");
const value_mod = @import("../../runtime/value/value.zig");
const env_mod = @import("../../runtime/env.zig");
const runtime_mod = @import("../../runtime/runtime.zig");
const string_mod = @import("../../runtime/collection/string.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const tree_walk = @import("tree_walk.zig");
const ex_info_mod = @import("../../runtime/collection/ex_info.zig");

const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const Value = value_mod.Value;
const Env = env_mod.Env;
const Var = env_mod.Var;
const Runtime = runtime_mod.Runtime;
const SourceLocation = error_mod.SourceLocation;
const Function = tree_walk.Function;

/// Per-frame operand stack ceiling. Matches `tree_walk.MAX_LOCALS` so
/// the VM's per-call working set equals TreeWalk's. The analyser does
/// not yet compute max stack depth (Phase 4 entry); the runtime check
/// raises `internal_error` if a malformed chunk overflows.
pub const OPERAND_STACK_MAX: u16 = 256;

/// Per-frame exception-handler stack ceiling. Deep `try` nesting is
/// rare; oversize raises `internal_error`. Mirrors v1's `HANDLERS_MAX`
/// but per-call rather than VM-global (cw v2 dispatcher is single-frame
/// per `eval()` call).
pub const HANDLER_STACK_MAX: u16 = 32;

const Handler = struct {
    catch_ip: usize,
    saved_sp: u16,
};

/// Evaluate a compiled chunk. `locals` is the caller-owned slot array
/// (typically a fixed 256-entry stack array, matching `tree_walk.eval`).
/// Returns the value produced by `op_ret`.
pub fn eval(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const BytecodeChunk,
) anyerror!Value {
    var stack: [OPERAND_STACK_MAX]Value = undefined;
    var sp: u16 = 0;
    var ip: usize = 0;
    var handlers: [HANDLER_STACK_MAX]Handler = undefined;
    var handler_count: u16 = 0;

    while (true) {
        const step_result = stepOnce(rt, env, locals, chunk, &stack, &sp, &ip, &handlers, &handler_count);
        if (step_result) |maybe_return| {
            if (maybe_return) |v| return v;
        } else |err| {
            if (err == error.ThrownValue and handler_count > 0) {
                handler_count -= 1;
                const h = handlers[handler_count];
                ip = h.catch_ip;
                sp = h.saved_sp;
                const thrown = dispatch.last_thrown_exception orelse
                    return raiseInternal("vm: ThrownValue without payload");
                dispatch.last_thrown_exception = null;
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: handler unwind overflow");
                stack[sp] = thrown;
                sp += 1;
                continue;
            }
            return err;
        }
    }
}

/// Fetch + execute one instruction. Returns `null` to keep looping,
/// a non-null Value when `op_ret` fires, or propagates the Zig error
/// so the outer loop can route `error.ThrownValue` through the
/// handler stack.
fn stepOnce(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const BytecodeChunk,
    stack: *[OPERAND_STACK_MAX]Value,
    sp_ptr: *u16,
    ip_ptr: *usize,
    handlers: *[HANDLER_STACK_MAX]Handler,
    handler_count_ptr: *u16,
) anyerror!?Value {
    var sp = sp_ptr.*;
    var ip = ip_ptr.*;
    var handler_count = handler_count_ptr.*;
    defer {
        sp_ptr.* = sp;
        ip_ptr.* = ip;
        handler_count_ptr.* = handler_count;
    }

    if (ip >= chunk.instructions.len)
        return raiseInternal("vm: ip past end of chunk");
    const instr = chunk.instructions[ip];
    ip += 1;

    switch (instr.opcode) {
            .op_const => {
                @branchHint(.likely);
                if (instr.operand >= chunk.constants.len)
                    return raiseInternal("vm: op_const constant index out of range");
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = chunk.constants[instr.operand];
                sp += 1;
            },
            .op_load_local => {
                if (instr.operand >= locals.len)
                    return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "Local", .index = instr.operand, .max = locals.len });
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = locals[instr.operand];
                sp += 1;
            },
            .op_store_local => {
                if (instr.operand >= locals.len)
                    return error_catalog.raise(.slot_out_of_range, .{}, .{ .form = "let*", .index = instr.operand, .max = locals.len });
                if (sp == 0) return raiseInternal("vm: op_store_local on empty stack");
                sp -= 1;
                locals[instr.operand] = stack[sp];
            },
            .op_def => {
                if (sp == 0) return raiseInternal("vm: op_def on empty stack");
                sp -= 1;
                const value = stack[sp];
                const name_idx = instr.operand & opcode_mod.DEF_NAME_IDX_MASK;
                if (name_idx >= chunk.constants.len)
                    return raiseInternal("vm: op_def name index out of range");
                const name_val = chunk.constants[name_idx];
                if (!name_val.isString())
                    return raiseInternal("vm: op_def constant is not a String");
                const ns = env.current_ns orelse
                    return error_catalog.raiseInternal(.{}, "def: no current namespace");
                const var_ptr = try env.intern(ns, string_mod.asString(name_val), value, null);
                var_ptr.flags.dynamic = (instr.operand & opcode_mod.DEF_FLAG_DYNAMIC) != 0;
                var_ptr.flags.macro_ = (instr.operand & opcode_mod.DEF_FLAG_MACRO) != 0;
                var_ptr.flags.private = (instr.operand & opcode_mod.DEF_FLAG_PRIVATE) != 0;
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = Value.encodeHeapPtr(.var_ref, var_ptr);
                sp += 1;
            },
            .op_get_var => {
                if (instr.operand >= chunk.constants.len)
                    return raiseInternal("vm: op_get_var constant index out of range");
                const var_value = chunk.constants[instr.operand];
                const var_ptr = var_value.decodePtr(*Var);
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = var_ptr.deref();
                sp += 1;
            },
            .op_jump => {
                const offset: i16 = @bitCast(instr.operand);
                ip = applyJump(ip, offset) orelse
                    return raiseInternal("vm: op_jump target out of range");
            },
            .op_jump_if_false => {
                if (sp == 0) return raiseInternal("vm: op_jump_if_false on empty stack");
                sp -= 1;
                if (!stack[sp].isTruthy()) {
                    const offset: i16 = @bitCast(instr.operand);
                    ip = applyJump(ip, offset) orelse
                        return raiseInternal("vm: op_jump_if_false target out of range");
                }
            },
            .op_call => {
                const arg_count: usize = instr.operand;
                if (sp < arg_count + 1)
                    return raiseInternal("vm: op_call underflow");
                sp -= @intCast(arg_count + 1);
                const callee = stack[sp];
                const args = stack[sp + 1 .. sp + 1 + arg_count];
                const vt = rt.vtable orelse
                    return error_catalog.raiseInternal(.{}, "Runtime vtable not installed; cannot dispatch call");
                const result = try vt.callFn(rt, env, callee, args, .{});
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = result;
                sp += 1;
            },
            .op_ret => {
                @branchHint(.likely);
                if (sp == 0) return raiseInternal("vm: op_ret on empty stack");
                sp -= 1;
                return stack[sp];
            },
            .op_pop => {
                if (sp == 0) return raiseInternal("vm: op_pop on empty stack");
                sp -= 1;
            },
            .op_dup => {
                if (sp == 0) return raiseInternal("vm: op_dup on empty stack");
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = stack[sp - 1];
                sp += 1;
            },
            .op_throw => {
                if (sp == 0) return raiseInternal("vm: op_throw on empty stack");
                sp -= 1;
                dispatch.last_thrown_exception = stack[sp];
                return error.ThrownValue;
            },
            .op_make_fn => {
                // The compiler stashes either a final closure-less
                // Function (slot_base == 0) or a template Function
                // (slot_base > 0, closure_bindings still null) in the
                // constant pool. For the template case the dispatcher
                // allocates a fresh Function with a snapshot of the
                // caller's locals[0..slot_base] so each fn* evaluation
                // captures its enclosing scope.
                if (instr.operand >= chunk.constants.len)
                    return raiseInternal("vm: op_make_fn constant index out of range");
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                const template_val = chunk.constants[instr.operand];
                const template = template_val.decodePtr(*const Function);
                if (template.slot_base == 0) {
                    stack[sp] = template_val;
                } else {
                    const bytecode = template.bytecode orelse
                        return raiseInternal("vm: op_make_fn template missing bytecode");
                    const fn_node = node_mod.FnNode{
                        .arity = template.arity,
                        .has_rest = template.has_rest,
                        .params = template.params,
                        .body = template.body,
                        .slot_base = template.slot_base,
                    };
                    stack[sp] = try tree_walk.allocFunctionWithBytecode(rt, fn_node, locals, bytecode);
                }
                sp += 1;
            },
            .op_recur => {
                // The compiler emits `op_recur <arity>` followed by N
                // op_store_local + op_jump <-back_offset>. The arity
                // check here is defensive — the analyser already
                // validated arity at parse time. The actual rebind
                // and back-jump happen in the following instructions.
                if (sp < instr.operand)
                    return raiseInternal("vm: op_recur underflow");
            },
            .op_invoke_builtin => {
                // Reserved for analyzer-resolved direct builtin calls;
                // the compiler does not emit this at 4.6 (every call
                // routes through `op_call` + vtable). Per
                // `no_op_stub_forbidden.md`, raise rather than fall
                // through silently.
                return error_catalog.raise(.feature_not_supported, .{}, .{ .name = "op_invoke_builtin" });
            },
            .op_push_handler => {
                const offset: i16 = @bitCast(instr.operand);
                const catch_ip = applyJump(ip, offset) orelse
                    return raiseInternal("vm: op_push_handler target out of range");
                if (handler_count >= HANDLER_STACK_MAX)
                    return raiseInternal("vm: handler stack overflow");
                handlers[handler_count] = .{ .catch_ip = catch_ip, .saved_sp = sp };
                handler_count += 1;
            },
            .op_pop_handler => {
                if (handler_count == 0)
                    return raiseInternal("vm: op_pop_handler on empty handler stack");
                handler_count -= 1;
            },
            .op_match_class => {
                if (sp == 0)
                    return raiseInternal("vm: op_match_class on empty stack");
                if (instr.operand >= chunk.constants.len)
                    return raiseInternal("vm: op_match_class constant index out of range");
                const class_val = chunk.constants[instr.operand];
                if (!class_val.isString())
                    return raiseInternal("vm: op_match_class constant is not a String");
                const thrown = stack[sp - 1];
                const matches = matchExceptionClass(string_mod.asString(class_val), thrown);
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = if (matches) Value.true_val else Value.false_val;
                sp += 1;
            },
            .op_in_ns => {
                // ADR-0032 in-ns — mirror of tree_walk::evalInNs (incl. the
                // rt/ auto-refer that lets Pattern A `.clj` defns under any
                // (in-ns 'X) resolve `reduce`/`conj`/etc. unqualified).
                if (instr.operand >= chunk.constants.len)
                    return raiseInternal("vm: op_in_ns constant index out of range");
                const name_val = chunk.constants[instr.operand];
                if (!name_val.isString())
                    return raiseInternal("vm: op_in_ns constant is not a String");
                env.current_ns = try env.findOrCreateNs(string_mod.asString(name_val));
                if (env.findNs("rt")) |rt_ns| {
                    try env.referAll(rt_ns, env.current_ns.?);
                }
                if (sp >= OPERAND_STACK_MAX)
                    return raiseInternal("vm: operand stack overflow");
                stack[sp] = Value.nil_val;
                sp += 1;
            },
            .op_vector_literal => {
                // Closes D-060: pop N values from top of stack, build a
                // PersistentVector via empty + conj, push result.
                const n: u16 = instr.operand;
                if (sp < n) return raiseInternal("vm: op_vector_literal underflows operand stack");
                var v = vector_mod.empty();
                var i: u16 = sp - n;
                while (i < sp) : (i += 1) {
                    v = try vector_mod.conj(rt, v, stack[i]);
                }
                sp -= n;
                stack[sp] = v;
                sp += 1;
            },
    }
    return null;
}

fn matchExceptionClass(class_name: []const u8, thrown: Value) bool {
    if (std.mem.eql(u8, class_name, "ExceptionInfo")) {
        return thrown.tag() == .ex_info;
    }
    // Phase 3.11 only recognises `ExceptionInfo`; other class symbols
    // were accepted at analyse time so user code stays readable. They
    // simply never match a thrown Value until later phases extend the
    // type-name table — mirrors `tree_walk.catchMatches`.
    return false;
}

fn raiseInternal(comptime detail: []const u8) anyerror {
    return error_catalog.raiseInternal(.{}, detail);
}

/// Populate `rt.vtable` for the VM backend (ROADMAP §9.6 / 4.8). The
/// `callFn` reuses `tree_walk.treeWalkCall` because the dispatch shape
/// per `Value.Tag` is identical across backends; the per-fn divergence
/// happens inside `tree_walk.callFunction`, which routes through the
/// new `evalChunk` vtable slot when the callee's `Function.bytecode`
/// is non-null. TreeWalk's `installVTable` leaves `evalChunk = null`,
/// so the two backends differ only in this single function-pointer
/// slot.
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &tree_walk.treeWalkCall,
        .valueTypeKey = &tree_walk.valueTypeKey,
        .evalChunk = &evalChunkErased,
    };
}

/// Trampoline that casts the Layer-0 `*const anyopaque` chunk pointer
/// back to `*const BytecodeChunk` (the concrete VM type) so the vtable
/// stays Layer-0-only (per `zone_deps.md`).
fn evalChunkErased(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    chunk: *const anyopaque,
) anyerror!Value {
    return eval(rt, env, locals, @ptrCast(@alignCast(chunk)));
}

fn applyJump(ip: usize, offset: i16) ?usize {
    if (offset >= 0) {
        return ip + @as(usize, @intCast(offset));
    }
    const back = @as(usize, @intCast(-@as(i32, offset)));
    if (back > ip) return null;
    return ip - back;
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var f: Fixture = undefined;
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.env = try Env.init(&f.rt);
        tree_walk.installVTable(&f.rt);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn run(self: *Fixture, chunk: *const BytecodeChunk) anyerror!Value {
        var locals: [256]Value = [_]Value{.nil_val} ** 256;
        return eval(&self.rt, &self.env, &locals, chunk);
    }
};

test "op_const then op_ret returns the constant" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_pop discards the top of the operand stack" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_pop },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_dup duplicates the top of the operand stack" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_dup },
        .{ .opcode = .op_pop },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_store_local then op_load_local round-trips a slot" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_store_local, .operand = 7 },
        .{ .opcode = .op_load_local, .operand = 7 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_load_local out of range raises index_error" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_load_local, .operand = 1000 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.IndexError, f.run(&chunk));
}

test "op_jump unconditionally skips forward" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // op_jump +1 ; op_const false (skipped) ; op_const true ; op_ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_jump, .operand = @as(u16, @bitCast(@as(i16, 1))) },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_jump_if_false takes the jump when popped value is false" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // op_const false ; op_jump_if_false +1 ; op_const true (skipped) ; op_const false ; op_ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_jump_if_false, .operand = @as(u16, @bitCast(@as(i16, 1))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.false_val, try f.run(&chunk));
}

test "op_jump_if_false falls through when popped value is truthy" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // (if true true false): push true cond ; jump_if_false +2 (no jump) ;
    // push true ; ret ; push false ; ret
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_jump_if_false, .operand = @as(u16, @bitCast(@as(i16, 2))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_def interns the name into env.current_ns and pushes the Var" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const name_val = try string_mod.alloc(&f.rt, "answer");
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_def, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ name_val, Value.true_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    const result = try f.run(&chunk);
    try testing.expectEqual(value_mod.Value.Tag.var_ref, result.tag());
    const var_ptr = result.decodePtr(*Var);
    try testing.expectEqualStrings("answer", var_ptr.name);
    try testing.expectEqual(Value.true_val, var_ptr.deref());
    try testing.expect(!var_ptr.flags.dynamic);
}

test "op_def stamps dynamic / macro / private flags from the operand" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const name_val = try string_mod.alloc(&f.rt, "foo");
    const packed_operand: u16 = 0 | opcode_mod.DEF_FLAG_DYNAMIC | opcode_mod.DEF_FLAG_PRIVATE;
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_def, .operand = packed_operand },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ name_val, Value.nil_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    const result = try f.run(&chunk);
    const var_ptr = result.decodePtr(*Var);
    try testing.expect(var_ptr.flags.dynamic);
    try testing.expect(!var_ptr.flags.macro_);
    try testing.expect(var_ptr.flags.private);
}

test "op_get_var dereferences a Var pointer from the constant pool" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ns = f.env.current_ns.?;
    const var_ptr = try f.env.intern(ns, "x", Value.true_val, null);
    const var_value = Value.encodeHeapPtr(.var_ref, var_ptr);

    const instrs = [_]Instruction{
        .{ .opcode = .op_get_var, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{var_value};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_call routes through rt.vtable.callFn" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ns = f.env.current_ns.?;
    const builtin_val = Value.initBuiltinFn(@as(dispatch.BuiltinFn, &testReturnFirstArg));
    _ = try f.env.intern(ns, "first-arg", builtin_val, null);

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_const, .operand = 1 },
        .{ .opcode = .op_const, .operand = 2 },
        .{ .opcode = .op_call, .operand = 2 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ builtin_val, Value.true_val, Value.false_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_make_fn snapshots locals when template.slot_base > 0" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // Build a template Function with slot_base = 1, body returns
    // local 0 (which the closure snapshot will provide).
    const body: node_mod.Node = .{ .local_ref = .{ .name = "x", .index = 0 } };
    const fn_node = node_mod.FnNode{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
        .slot_base = 1,
    };
    // The template's bytecode body needs to actually produce a value;
    // a one-op chunk that loads local 0 + returns suffices.
    const template_instrs = [_]Instruction{
        .{ .opcode = .op_load_local, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const template_chunk: BytecodeChunk = .{
        .instructions = &template_instrs,
        .constants = &.{},
    };
    const template_val = try tree_walk.allocFunctionTemplate(&f.rt, fn_node, &template_chunk);

    // Outer chunk: load local 5 (which the caller seeds with true),
    // make a closure (snapshot), then read its closure_bindings[0]
    // directly to verify the snapshot captured the right thing.
    const instrs = [_]Instruction{
        .{ .opcode = .op_make_fn, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{template_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    var locals: [256]Value = [_]Value{.nil_val} ** 256;
    locals[0] = Value.true_val;
    const result = try eval(&f.rt, &f.env, &locals, &chunk);

    try testing.expectEqual(value_mod.Value.Tag.fn_val, result.tag());
    const closure_fn = result.decodePtr(*const tree_walk.Function);
    try testing.expect(closure_fn.closure_bindings != null);
    try testing.expectEqual(@as(usize, 1), closure_fn.closure_bindings.?.len);
    try testing.expectEqual(Value.true_val, closure_fn.closure_bindings.?[0]);
    // The template itself must NOT have been mutated.
    const template_fn = template_val.decodePtr(*const tree_walk.Function);
    try testing.expect(template_fn.closure_bindings == null);
}

test "op_recur with insufficient stack raises internal_error" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_recur, .operand = 3 },
        .{ .opcode = .op_ret },
    };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &.{} };

    try testing.expectError(error.InternalError, f.run(&chunk));
}

test "op_make_fn pushes the pre-allocated Function from the constants pool" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const body: node_mod.Node = .{ .constant = .{ .value = Value.true_val } };
    const fn_node = node_mod.FnNode{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
        .slot_base = 0,
    };
    const fn_val = try tree_walk.allocFunction(&f.rt, fn_node, &.{});

    const instrs = [_]Instruction{
        .{ .opcode = .op_make_fn, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{fn_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(fn_val, try f.run(&chunk));
}

test "op_throw sets dispatch.last_thrown_exception and returns ThrownValue" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
    };
    const constants = [_]Value{Value.true_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.ThrownValue, f.run(&chunk));
    try testing.expectEqual(Value.true_val, dispatch.last_thrown_exception.?);
    dispatch.last_thrown_exception = null;
}

test "op_invoke_builtin raises unsupported_feature (4.6 placeholder)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const instrs = [_]Instruction{
        .{ .opcode = .op_invoke_builtin, .operand = 0 },
    };
    const constants = [_]Value{Value.nil_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.NotImplemented, f.run(&chunk));
}

fn testReturnFirstArg(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    if (args.len == 0) return Value.nil_val;
    return args[0];
}

test "op_push_handler routes thrown value into the catch arm" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    // op_push_handler +3 ; op_const ex ; op_throw ; op_pop_handler (unreachable) ; <handler> op_ret
    const ex_val = try ex_info_mod.alloc(&f.rt, "boom", Value.nil_val, Value.nil_val);
    const instrs = [_]Instruction{
        .{ .opcode = .op_push_handler, .operand = @as(u16, @bitCast(@as(i16, 3))) },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
        .{ .opcode = .op_pop_handler },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ex_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(ex_val, try f.run(&chunk));
    try testing.expect(dispatch.last_thrown_exception == null);
}

test "op_pop_handler removes the innermost handler so thrown propagates" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    dispatch.last_thrown_exception = null;

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const instrs = [_]Instruction{
        .{ .opcode = .op_push_handler, .operand = @as(u16, @bitCast(@as(i16, 4))) },
        .{ .opcode = .op_pop_handler },
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_throw },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ex_val};
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectError(error.ThrownValue, f.run(&chunk));
    try testing.expectEqual(ex_val, dispatch.last_thrown_exception.?);
    dispatch.last_thrown_exception = null;
}

test "op_match_class returns true for ExceptionInfo vs ex_info tag" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const class_val = try string_mod.alloc(&f.rt, "ExceptionInfo");

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_match_class, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ ex_val, class_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.true_val, try f.run(&chunk));
}

test "op_match_class returns false for unknown class names" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const ex_val = try ex_info_mod.alloc(&f.rt, "x", Value.nil_val, Value.nil_val);
    const class_val = try string_mod.alloc(&f.rt, "IndexOutOfBoundsException");

    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_match_class, .operand = 1 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{ ex_val, class_val };
    const chunk: BytecodeChunk = .{ .instructions = &instrs, .constants = &constants };

    try testing.expectEqual(Value.false_val, try f.run(&chunk));
}
