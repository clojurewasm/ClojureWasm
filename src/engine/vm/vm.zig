// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Bytecode Virtual Machine.
//!
//! Stack-based VM that executes compiled bytecode (Chunk).
//! Instantiated design: no threadlocal, VM is an explicit struct.
//!
//! Pipeline:
//!   Form (Reader) -> Node (Analyzer) -> Bytecode (Compiler) -> Value (VM)

const std = @import("std");
const builtin = @import("builtin");
const chunk_mod = @import("../compiler/chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Instruction = chunk_mod.Instruction;
const FnProto = chunk_mod.FnProto;
const Value = chunk_mod.Value;
const value_mod = @import("../../runtime/value.zig");
const Fn = value_mod.Fn;
const ProtocolFn = value_mod.ProtocolFn;
const Env = @import("../../runtime/env.zig").Env;
const Namespace = @import("../../runtime/namespace.zig").Namespace;
const collections = @import("../../runtime/collections.zig");
const PersistentList = collections.PersistentList;
const PersistentVector = collections.PersistentVector;
const PersistentArrayMap = collections.PersistentArrayMap;
const PersistentHashSet = collections.PersistentHashSet;
const builtin_collections = @import("../../lang/builtins/collections.zig");
const arith = @import("../../lang/builtins/arithmetic.zig");
const bootstrap = @import("../bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const multimethods_mod = @import("../../lang/builtins/multimethods.zig");
const gc_mod = @import("../../runtime/gc.zig");
const build_options = @import("build_options");
const profile_opcodes = build_options.profile_opcodes;

/// VM execution errors.
const err_mod = @import("../../runtime/error.zig");
pub const jit_mod = @import("jit.zig");

pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    ArityError,
    NameError,
    UndefinedVar,
    OutOfMemory,
    InvalidInstruction,
    Overflow,
    UserException,
    ArithmeticError,
    IndexError,
    ValueError,
    IoError,
    AnalyzeError,
    EvalError,
};

const STACK_MAX: usize = 256 * 128;
const FRAMES_MAX: usize = 1024;
const HANDLERS_MAX: usize = 64;

/// Exception handler — saves state for try/catch unwinding.
const ExceptionHandler = struct {
    catch_ip: usize,
    saved_sp: usize,
    saved_frame_count: usize,
    frame_idx: usize, // which frame the handler belongs to
};

/// Call frame — tracks execution state for a function invocation.
const CallFrame = struct {
    ip: usize,
    base: usize,
    code: []const Instruction,
    constants: []const Value,
    /// Source file path for error reporting.
    source_file: ?[]const u8 = null,
    /// Source line per instruction (parallel to code) for error reporting.
    lines: []const u32 = &.{},
    /// Source column per instruction (parallel to code) for error reporting.
    columns: []const u32 = &.{},
    /// Saved current_ns before this call (restored on ret) for D68 namespace isolation.
    saved_ns: ?*anyopaque = null,
};

/// Module-level opcode profiling counters (37.1). Accumulate across VM instances.
/// Gated by -Dprofile-opcodes=true. Violates D3 (no global state) by design —
/// profiling is a development tool, not production code.
var global_opcode_counts: if (profile_opcodes) [256]u64 else void = if (profile_opcodes) .{0} ** 256 else {};

/// Dump accumulated opcode frequency profile to stderr.
pub fn dumpOpcodeProfile() void {
    if (!profile_opcodes) return;
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    const counts = &global_opcode_counts;
    var total: u64 = 0;
    for (counts) |c| total += c;
    if (total == 0) return;

    // Collect non-zero entries
    var entries: [256]struct { count: u64, idx: u8 } = undefined;
    var n: usize = 0;
    for (0..256) |i| {
        if (counts[i] > 0) {
            entries[n] = .{ .count = counts[i], .idx = @intCast(i) };
            n += 1;
        }
    }

    // Sort by count descending (selection sort — max ~45 opcodes)
    for (0..n) |i| {
        var max_j = i;
        for (i + 1..n) |j| {
            if (entries[j].count > entries[max_j].count) max_j = j;
        }
        if (max_j != i) {
            const tmp = entries[i];
            entries[i] = entries[max_j];
            entries[max_j] = tmp;
        }
    }

    var buf: [256]u8 = undefined;
    _ = stderr.write("\n=== Opcode Frequency Profile ===\n") catch return;
    var len = std.fmt.bufPrint(&buf, "Total instructions: {d}\n\n", .{total}) catch return;
    _ = stderr.write(len) catch return;

    _ = stderr.write("Opcode                  Count        %\n") catch return;
    _ = stderr.write("--------------------  ----------  ------\n") catch return;

    for (entries[0..n]) |e| {
        const name = @tagName(@as(OpCode, @enumFromInt(e.idx)));
        const pct: f64 = @as(f64, @floatFromInt(e.count)) / @as(f64, @floatFromInt(total)) * 100.0;
        len = std.fmt.bufPrint(&buf, "{s:<20}  {d:>10}  {d:>5.1}%\n", .{ name, e.count, pct }) catch continue;
        _ = stderr.write(len) catch return;
    }
    _ = stderr.write("\n") catch return;
}

/// Active VM reference for fused reduce (builtins can call back into VM).
/// Set during execute(), cleared on return. Enables efficient function
/// calls from builtins without creating new VM instances.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var active_vm: ?*VM = null;

/// Bridge function for dispatch.active_vm_call vtable (D109 R1).
/// Reads the threadlocal active_vm and calls its callFunction method.
fn activeVmCallBridge(fn_val: Value, args: []const Value) anyerror!Value {
    const vm = active_vm orelse return error.EvalError;
    return vm.callFunction(fn_val, args) catch |e| {
        return @as(anyerror, @errorCast(e));
    };
}

/// Whether JIT compilation is available on this platform.
const enable_jit = builtin.cpu.arch == .aarch64;

/// JIT compilation warmup threshold (iterations before compiling).
const JIT_THRESHOLD: u32 = 64;

/// JIT hot loop cache (one slot per VM for PoC).
const JitState = struct {
    /// Identifies the function containing the cached loop.
    loop_code_ptr: ?[*]const Instruction = null,
    /// Start IP of the cached loop within the function.
    loop_start_ip: usize = 0,
    /// Iteration counter for warmup.
    loop_count: u32 = 0,
    /// Compiled native function (valid while compiler is alive).
    jit_fn: ?jit_mod.JitFn = null,
    /// JIT compiler instance (owns the mmap'd code buffer).
    compiler: ?jit_mod.JitCompiler = null,

    fn deinit(self: *JitState) void {
        if (self.compiler) |*c| c.deinit();
        self.* = .{};
    }
};

/// Stack-based bytecode virtual machine.
pub const VM = struct {
    allocator: std.mem.Allocator,
    stack: [STACK_MAX]Value,
    sp: usize,
    frames: [FRAMES_MAX]CallFrame,
    frame_count: usize,
    /// Allocated closures (for cleanup when GC is not active).
    allocated_fns: std.ArrayList(*const Fn),
    /// Allocated collection backing arrays (for cleanup when GC is not active).
    allocated_slices: std.ArrayList([]const Value),
    /// Allocated collection structs (for cleanup when GC is not active).
    allocated_lists: std.ArrayList(*const PersistentList),
    allocated_vectors: std.ArrayList(*const PersistentVector),
    allocated_maps: std.ArrayList(*const PersistentArrayMap),
    allocated_sets: std.ArrayList(*const PersistentHashSet),
    /// Exception handler stack.
    handlers: [HANDLERS_MAX]ExceptionHandler,
    handler_count: usize,
    /// Runtime environment (Namespace/Var resolution).
    env: ?*Env,
    /// Minimum frame scope for handler dispatch. Set by callFunction to
    /// prevent inner exceptions from being caught by outer scope handlers
    /// when execution crosses VM/TreeWalk boundaries.
    call_target_frame: usize = 0,
    /// GC instance for automatic collection at safe points.
    gc: ?*gc_mod.MarkSweepGc = null,
    /// JIT compilation state (ARM64 only).
    jit_state: if (enable_jit) JitState else void = if (enable_jit) .{} else {},

    pub fn init(allocator: std.mem.Allocator) VM {
        return initWithEnv(allocator, null);
    }

    pub fn initWithEnv(allocator: std.mem.Allocator, env: ?*Env) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .allocated_fns = .empty,
            .allocated_slices = .empty,
            .allocated_lists = .empty,
            .allocated_vectors = .empty,
            .allocated_maps = .empty,
            .allocated_sets = .empty,
            .handlers = undefined,
            .handler_count = 0,
            .env = env,
        };
    }

    /// Detach runtime-allocated Fn objects so they survive VM deinit.
    /// Returns the list of Fn pointers. Caller takes ownership.
    pub fn detachFnAllocations(self: *VM) []const *const Fn {
        const items = self.allocated_fns.items;
        const result = self.allocator.alloc(*const Fn, items.len) catch return &.{};
        @memcpy(result, items);
        self.allocated_fns.clearRetainingCapacity();
        return result;
    }

    pub fn deinit(self: *VM) void {
        if (enable_jit) self.jit_state.deinit();
        if (self.gc != null) return; // GC handles all memory
        for (self.allocated_fns.items) |fn_ptr| {
            if (fn_ptr.closure_bindings) |cb| {
                self.allocator.free(cb);
            }
            const mutable: *Fn = @constCast(fn_ptr);
            self.allocator.destroy(mutable);
        }
        self.allocated_fns.deinit(self.allocator);
        for (self.allocated_slices.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_slices.deinit(self.allocator);
        for (self.allocated_lists.items) |p| self.allocator.destroy(@constCast(p));
        self.allocated_lists.deinit(self.allocator);
        for (self.allocated_vectors.items) |p| self.allocator.destroy(@constCast(p));
        self.allocated_vectors.deinit(self.allocator);
        for (self.allocated_maps.items) |p| self.allocator.destroy(@constCast(p));
        self.allocated_maps.deinit(self.allocator);
        for (self.allocated_sets.items) |p| self.allocator.destroy(@constCast(p));
        self.allocated_sets.deinit(self.allocator);
    }

    /// Execute a compiled Chunk and return the result.
    pub fn run(self: *VM, c: *const Chunk) VMError!Value {
        self.frames[0] = .{
            .ip = 0,
            .base = 0,
            .code = c.code.items,
            .constants = c.constants.items,
            .lines = c.lines.items,
            .columns = c.columns.items,
        };
        self.frame_count = 1;
        return self.execute();
    }

    pub fn execute(self: *VM) VMError!Value {
        const saved_active = active_vm;
        active_vm = self;
        const saved_dispatch = dispatch.active_vm_call;
        dispatch.active_vm_call = &activeVmCallBridge;
        defer {
            active_vm = saved_active;
            dispatch.active_vm_call = saved_dispatch;
        }
        return self.executeUntil(0);
    }

    /// Execute instructions until frame_count drops to target_frame.
    /// Used by execute() (target=0) and callFunction() (target=caller's frame).
    ///
    /// Optimization: The main dispatch loop uses a Zig `switch` on the opcode
    /// (compiled to a jump table by LLVM), which is ~1.5x faster than an if-else
    /// chain. GC safepoints are batched every 256 instructions via a wrapping u8
    /// counter, reducing per-instruction overhead to a single add+compare.
    fn executeUntil(self: *VM, target_frame: usize) VMError!Value {
        var gc_counter: u8 = 0;
        while (true) {
            if (self.stepInstructionTarget(target_frame)) |maybe_result| {
                if (maybe_result) |result| return result;
            } else |e| {
                @branchHint(.unlikely);
                // Annotate error with source location from current frame
                if (self.frame_count > target_frame) {
                    const f = &self.frames[self.frame_count - 1];
                    if (f.lines.len > 0 and f.ip > 0) {
                        const line = f.lines[f.ip - 1];
                        if (line > 0) {
                            const column: u32 = if (f.columns.len > 0 and f.ip > 0)
                                f.columns[f.ip - 1]
                            else
                                0;
                            const file = f.source_file orelse err_mod.getSourceFile();
                            err_mod.annotateLocation(.{
                                .line = line,
                                .column = column,
                                .file = file,
                            });
                            // Update top error stack frame with actual IP location
                            err_mod.updateTopFrame(line, column);
                        }
                    }
                }
                if (self.handler_count > 0 and isUserError(e)) {
                    // Only dispatch to handler if it belongs to this call scope.
                    // Handlers with saved_frame_count > call_target_frame were
                    // established during the current callFunction execution.
                    const handler = self.handlers[self.handler_count - 1];
                    if (handler.saved_frame_count > self.call_target_frame) {
                        self.dispatchErrorToHandler(e) catch |e2| return e2;
                        continue;
                    }
                }
                return e;
            }
            // Batched GC safe point — check every 256 instructions
            gc_counter +%= 1;
            if (gc_counter == 0) {
                @branchHint(.unlikely);
                self.maybeTriggerGc();
            }
        }
    }

    /// Call a function value on the current VM, reusing its stack and frames.
    ///
    /// This is a critical optimization: without it, every callback from
    /// a builtin (e.g. reduce calling the step function) would create a new VM
    /// instance (~500KB heap allocation each). With active_vm reuse, callbacks
    /// run on the existing VM stack at near-zero overhead. This is what makes
    /// fused reduce with 168 nested filter predicates (sieve benchmark) feasible
    /// — saving ~82MB of VM allocations per sieve iteration.
    pub fn callFunction(self: *VM, fn_val: Value, args: []const Value) VMError!Value {
        const saved_sp = self.sp;
        const target_frame = self.frame_count;
        // Scope handler dispatch to this call (prevents exceptions from leaking
        // to handlers established by outer callFunction scopes across bridges).
        const saved_call_target = self.call_target_frame;
        self.call_target_frame = target_frame;
        defer self.call_target_frame = saved_call_target;
        // Restore stack and frame state on error, so the caller VM is in a
        // clean state for subsequent calls (e.g., TW catch clause calling report).
        errdefer {
            self.sp = saved_sp;
            self.frame_count = target_frame;
        }
        // Save namespace — performCall switches it (D68), but if the callee
        // throws and no handler catches it, ret never runs.
        const saved_ns = if (self.env) |env| env.current_ns else null;
        errdefer if (self.env) |env| {
            env.current_ns = saved_ns;
        };
        try self.push(fn_val);
        for (args) |arg| {
            try self.push(arg);
        }
        try self.performCall(@intCast(args.len));

        // Check if a frame was pushed (fn_val) or result is already on stack (builtins)
        if (self.frame_count > target_frame) {
            // A frame was pushed — execute until it returns
            const result = try self.executeUntil(target_frame);
            self.sp = saved_sp;
            return result;
        } else {
            // Result already on stack (builtins, keywords, vectors, maps, etc.)
            const result = self.pop();
            self.sp = saved_sp;
            return result;
        }
    }

    /// GC safe point: trigger collection if allocation threshold exceeded.
    fn maybeTriggerGc(self: *VM) void {
        const gc = self.gc orelse return;
        if (gc.bytes_allocated < gc.threshold) return;

        // Build root set from VM state
        var slices: [FRAMES_MAX + 1][]const Value = undefined;
        slices[0] = self.stack[0..self.sp];
        for (0..self.frame_count) |i| {
            slices[i + 1] = self.frames[i].constants;
            // Mark non-Value arrays that the VM is actively using
            gc.markSlice(self.frames[i].code);
            gc.markSlice(self.frames[i].lines);
            gc.markSlice(self.frames[i].columns);
        }

        gc.collectIfNeeded(.{
            .value_slices = slices[0 .. self.frame_count + 1],
            .env = self.env,
        });
    }

    /// Execute one instruction. Returns a Value when execution is complete
    /// (ret from top-level or end-of-code), null to continue.
    fn stepInstructionTarget(self: *VM, target_frame: usize) VMError!?Value {
        const frame = &self.frames[self.frame_count - 1];
        if (frame.ip >= frame.code.len) {
            return if (self.sp > 0) self.pop() else Value.nil_val;
        }

        const instr = frame.code[frame.ip];
        frame.ip += 1;

        if (profile_opcodes) {
            global_opcode_counts[@intFromEnum(instr.op)] += 1;
        }

        switch (instr.op) {
            // [A] Constants
            .const_load => try self.push(frame.constants[instr.operand]),
            .nil => try self.push(Value.nil_val),
            .true_val => try self.push(Value.true_val),
            .false_val => try self.push(Value.false_val),

            // [B] Stack
            .pop => _ = self.pop(),
            .dup => {
                const val = self.peek(0);
                try self.push(val);
            },
            .pop_under => {
                // Keep top, remove N values below it
                const count = instr.operand;
                const top = self.pop();
                var i: u16 = 0;
                while (i < count) : (i += 1) {
                    _ = self.pop();
                }
                try self.push(top);
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
                    const neg: usize = @intCast(-offset);
                    if (neg > frame.ip) return error.InvalidInstruction;
                    frame.ip -= neg;
                } else {
                    frame.ip += @intCast(offset);
                }
                if (frame.ip > frame.code.len) return error.InvalidInstruction;
            },
            .jump_if_false => {
                const val = self.pop();
                if (!val.isTruthy()) {
                    frame.ip += instr.operand;
                    if (frame.ip > frame.code.len) return error.InvalidInstruction;
                }
            },
            .jump_back => {
                if (instr.operand > frame.ip) return error.InvalidInstruction;
                frame.ip -= instr.operand;
            },

            // [G] Functions
            .call, .tail_call => try self.performCall(instr.operand),
            .ret => {
                const result = self.pop();
                const base = frame.base;
                // Restore caller's namespace (D68)
                if (self.env) |env| {
                    if (frame.saved_ns) |ns_ptr| {
                        env.current_ns = @ptrCast(@alignCast(ns_ptr));
                    }
                }
                self.frame_count -= 1;
                err_mod.popFrame();
                if (self.frame_count == target_frame) return result;
                // Restore caller's stack: base-1 removes the fn_val slot
                self.sp = base - 1;
                try self.push(result);
            },
            .closure => {
                // Operand: constant pool index of fn template
                const const_idx: u16 = instr.operand;

                const template = frame.constants[const_idx];
                if (template.tag() != .fn_val) return error.TypeError;
                const fn_obj = template.asFn();
                const proto: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));

                if (proto.capture_count > 0) {
                    // Capture values using per-slot offsets from capture_slots
                    const bindings = self.allocator.alloc(Value, proto.capture_count) catch
                        return error.OutOfMemory;
                    for (0..proto.capture_count) |i| {
                        const slot = proto.capture_slots[i];
                        bindings[i] = self.stack[frame.base + slot];
                    }
                    const new_fn = self.allocator.create(Fn) catch return error.OutOfMemory;
                    new_fn.* = .{
                        .proto = fn_obj.proto,
                        .closure_bindings = bindings,
                        .extra_arities = fn_obj.extra_arities,
                        .defining_ns = fn_obj.defining_ns,
                    };
                    if (self.gc == null) self.allocated_fns.append(self.allocator, new_fn) catch return error.OutOfMemory;
                    try self.push(Value.initFn(new_fn));
                } else {
                    // No capture needed, push the template directly
                    try self.push(template);
                }
            },

            .letfn_patch => {
                // Patch closure bindings for letfn mutual recursion.
                // operand: (count << 8) | base_slot
                const base: u16 = instr.operand & 0xFF;
                const count: u16 = instr.operand >> 8;

                for (0..count) |i| {
                    const val = self.stack[frame.base + base + i];
                    if (val.tag() == .fn_val) {
                        const fn_obj = val.asFn();
                        const proto: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));
                        if (fn_obj.closure_bindings) |bindings| {
                            const mutable = @constCast(bindings);
                            for (0..proto.capture_count) |ci| {
                                const slot = proto.capture_slots[ci];
                                if (slot >= base and slot < base + count) {
                                    mutable[ci] = self.stack[frame.base + slot];
                                }
                            }
                        }
                        // Note: extra_arities are FnProto pointers (not Fn objects).
                        // All arities share the primary Fn's closure_bindings at call time.
                    }
                }
            },

            // [H] Loop/recur
            .recur => {
                // Operand: (base_offset << 8) | arg_count
                const arg_count: u16 = instr.operand & 0xFF;
                const base_offset: u16 = (instr.operand >> 8) & 0xFF;

                // Pop recur args into temp buffer (reverse order)
                var temp_buf: [16]Value = undefined;
                var i: u16 = arg_count;
                while (i > 0) {
                    i -= 1;
                    temp_buf[i] = self.pop();
                }

                // Write new values to loop binding slots
                for (0..arg_count) |idx| {
                    self.stack[frame.base + base_offset + idx] = temp_buf[idx];
                }

                // Reset sp to just after loop bindings
                self.sp = frame.base + base_offset + arg_count;

                // Next instruction is jump_back which loops
            },

            // [I] Collections
            .list_new => try self.buildCollection(instr.operand, .list),
            .vec_new => try self.buildCollection(instr.operand, .vec),
            .map_new => try self.buildCollection(instr.operand, .map),
            .set_new => try self.buildCollection(instr.operand, .set),

            // [E] Var operations
            .var_load, .var_load_dynamic => {
                const sym = frame.constants[instr.operand];
                if (sym.tag() != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                const sym_val = sym.asSymbol();
                var v = if (sym_val.ns) |ns_name|
                    ns.resolveQualified(ns_name, sym_val.name)
                else
                    ns.resolve(sym_val.name);
                // Fallback: look up namespace by full name in env registry
                if (v == null) {
                    if (sym_val.ns) |ns_name| {
                        if (env.namespaces.get(ns_name)) |target_ns| {
                            v = target_ns.resolve(sym_val.name);
                        }
                    }
                }
                if (v) |resolved| {
                    try self.push(resolved.deref());
                } else {
                    if (sym_val.ns) |ns_name| {
                        err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve symbol: {s}/{s} in this context", .{ ns_name, sym_val.name });
                    } else {
                        err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve symbol: {s} in this context", .{sym_val.name});
                    }
                    return error.UndefinedVar;
                }
            },
            .set_bang => {
                // (set! var-sym expr) — mutate thread-local binding
                const new_val = self.peek(0);
                const sym = frame.constants[instr.operand];
                if (sym.tag() != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                const v = ns.resolve(sym.asSymbol().name) orelse {
                    err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve var: {s}", .{sym.asSymbol().name});
                    return error.UndefinedVar;
                };
                const var_mod = @import("../../runtime/var.zig");
                var_mod.setThreadBinding(v, new_val) catch return error.ValueError;
                // Value remains on stack (net 0)
            },
            .def, .def_macro, .def_dynamic, .def_private => {
                const val = self.pop();
                const sym = frame.constants[instr.operand];
                if (sym.tag() != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                const v = ns.intern(sym.asSymbol().name) catch return error.OutOfMemory;
                v.bindRoot(val);
                if (instr.op == .def_macro) v.setMacro(true);
                if (instr.op == .def_dynamic) v.dynamic = true;
                if (instr.op == .def_private) v.private = true;

                // Read metadata from adjacent constants (set by compiler)
                // Layout: [base]=sym, [+1]=line, [+2]=file, [+3]=doc, [+4]=arglists
                const base = instr.operand;
                if (base + 2 < frame.constants.len) {
                    const line_val = frame.constants[base + 1];
                    const file_val = frame.constants[base + 2];
                    if (line_val.tag() == .integer) {
                        const line_i = line_val.asInteger();
                        if (line_i > 0) {
                            v.line = @intCast(line_i);
                            v.file = if (file_val.tag() == .string) file_val.asString() else "NO_SOURCE_FILE";
                        }
                    }
                }
                if (base + 4 < frame.constants.len) {
                    const doc_val = frame.constants[base + 3];
                    const arglists_val = frame.constants[base + 4];
                    if (doc_val.tag() == .string) v.doc = doc_val.asString();
                    if (arglists_val.tag() == .string) v.arglists = arglists_val.asString();
                }

                try self.push(Value.initVarRef(v));
            },

            .defmulti => {
                const dispatch_fn = self.pop();
                const has_hierarchy = (instr.operand >> 15) != 0;
                const name_idx: u16 = instr.operand & 0x7FFF;

                // Pop optional hierarchy var reference
                var hierarchy_var: ?*value_mod.Var = null;
                if (has_hierarchy) {
                    const h_val = self.pop();
                    if (h_val.tag() == .var_ref) {
                        hierarchy_var = h_val.asVarRef();
                    }
                }

                const sym = frame.constants[name_idx];
                if (sym.tag() != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;

                // Create MultiFn
                const mf = self.allocator.create(value_mod.MultiFn) catch return error.OutOfMemory;
                const empty_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                empty_map.* = .{ .entries = &.{} };
                mf.* = .{
                    .name = sym.asSymbol().name,
                    .dispatch_fn = dispatch_fn,
                    .methods = empty_map,
                    .hierarchy_var = hierarchy_var,
                };

                // Bind to var (dynamic so binding works — upstream allows rebinding multimethods)
                const v = ns.intern(sym.asSymbol().name) catch return error.OutOfMemory;
                v.bindRoot(Value.initMultiFn(mf));
                v.dynamic = true;
                try self.push(Value.initMultiFn(mf));
            },
            .defmethod => {
                const method_fn = self.pop();
                const dispatch_val = self.pop();
                const sym = frame.constants[instr.operand];
                if (sym.tag() != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;

                // Resolve multimethod
                const mf_var = ns.resolve(sym.asSymbol().name) orelse {
                    err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve multimethod: {s}", .{sym.asSymbol().name});
                    return error.UndefinedVar;
                };
                const mf_val = mf_var.deref();
                if (mf_val.tag() != .multi_fn) return error.TypeError;
                const mf = mf_val.asMultiFn();

                // Add method: assoc dispatch_val -> method_fn
                const old = mf.methods;
                const new_entries = self.allocator.alloc(value_mod.Value, old.entries.len + 2) catch return error.OutOfMemory;
                @memcpy(new_entries[0..old.entries.len], old.entries);
                new_entries[old.entries.len] = dispatch_val;
                new_entries[old.entries.len + 1] = method_fn;
                const new_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                new_map.* = .{ .entries = new_entries };
                mf.methods = new_map;
                mf.invalidateCache();

                try self.push(method_fn);
            },

            .lazy_seq => {
                const thunk = self.pop();
                const ls = self.allocator.create(value_mod.LazySeq) catch return error.OutOfMemory;
                ls.* = .{ .thunk = thunk, .realized = null };
                try self.push(Value.initLazySeq(ls));
            },

            .defprotocol => {
                // Constants[operand] = name symbol, Constants[operand+1] = sigs vector
                const name_sym = frame.constants[instr.operand];
                if (name_sym.tag() != .symbol) return error.InvalidInstruction;
                const sigs_val = frame.constants[instr.operand + 1];
                if (sigs_val.tag() != .vector) return error.InvalidInstruction;

                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;

                // Parse sigs vector: [extend_via_meta?, name1, arity1, name2, arity2, ...]
                const sigs_items = sigs_val.asVector().items;
                if (sigs_items.len == 0) return error.InvalidInstruction;
                const extend_via_meta = sigs_items[0].tag() == .boolean and sigs_items[0].asBoolean();
                const sig_data = sigs_items[1..];
                const sig_count = sig_data.len / 2;
                const method_sigs = self.allocator.alloc(value_mod.MethodSig, sig_count) catch return error.OutOfMemory;
                for (0..sig_count) |i| {
                    const m_name = sig_data[i * 2];
                    const m_arity = sig_data[i * 2 + 1];
                    if (m_name.tag() != .string or m_arity.tag() != .integer) return error.InvalidInstruction;
                    method_sigs[i] = .{
                        .name = m_name.asString(),
                        .arity = @intCast(m_arity.asInteger()),
                    };
                }

                // Create protocol with empty impls
                const protocol = self.allocator.create(value_mod.Protocol) catch return error.OutOfMemory;
                const empty_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                empty_map.* = .{ .entries = &.{} };
                if (self.gc == null) self.allocated_maps.append(self.allocator, empty_map) catch return error.OutOfMemory;
                protocol.* = .{
                    .name = name_sym.asSymbol().name,
                    .method_sigs = method_sigs,
                    .impls = empty_map,
                    .extend_via_metadata = extend_via_meta,
                    .defining_ns = ns.name,
                };

                // Bind protocol to var
                const proto_var = ns.intern(name_sym.asSymbol().name) catch return error.OutOfMemory;
                proto_var.bindRoot(Value.initProtocol(protocol));

                // Create ProtocolFn for each method and bind to vars
                for (method_sigs) |sig| {
                    const pf = self.allocator.create(value_mod.ProtocolFn) catch return error.OutOfMemory;
                    pf.* = .{
                        .protocol = protocol,
                        .method_name = sig.name,
                    };
                    const method_var = ns.intern(sig.name) catch return error.OutOfMemory;
                    method_var.bindRoot(Value.initProtocolFn(pf));
                }

                try self.push(Value.initProtocol(protocol));
            },

            .extend_type_method => {
                // Pop method fn from stack
                const method_fn = self.pop();

                // Read meta vector: [type_name, protocol_name, method_name, protocol_ns?]
                const meta_val = frame.constants[instr.operand];
                if (meta_val.tag() != .vector) return error.InvalidInstruction;
                const meta = meta_val.asVector().items;
                if (meta.len < 3) return error.InvalidInstruction;
                const type_name_val = meta[0];
                const proto_name_val = meta[1];
                const method_name_val = meta[2];
                if (type_name_val.tag() != .string or proto_name_val.tag() != .string or method_name_val.tag() != .string)
                    return error.InvalidInstruction;

                const type_key = mapTypeKey(type_name_val.asString());
                const proto_name = proto_name_val.asString();
                const method_name = method_name_val.asString();

                // Resolve protocol (supports namespace-qualified names and aliases)
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                const proto_var = if (meta.len >= 4 and meta[3].tag() == .string) blk: {
                    const pns_name = meta[3].asString();
                    // Try alias resolution first (e.g. p/InlineValue where p is alias)
                    if (ns.resolveQualified(pns_name, proto_name)) |v| break :blk v;
                    // Fall back to full namespace name lookup
                    const proto_ns = env.findNamespace(pns_name) orelse {
                        err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve namespace: {s}", .{pns_name});
                        return error.UndefinedVar;
                    };
                    break :blk proto_ns.resolve(proto_name) orelse {
                        err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve protocol: {s}/{s}", .{ pns_name, proto_name });
                        return error.UndefinedVar;
                    };
                } else ns.resolve(proto_name) orelse {
                    err_mod.setInfoFmt(.eval, .name_error, .{}, "Unable to resolve protocol: {s}", .{proto_name});
                    return error.UndefinedVar;
                };
                const proto_val = proto_var.deref();
                if (proto_val.tag() != .protocol) return error.TypeError;
                const protocol = proto_val.asProtocol();

                // Get or create method map for this type in protocol.impls
                const existing = protocol.impls.getByStringKey(type_key);
                if (existing) |ex_val| {
                    // Existing method map for this type — update or add method
                    if (ex_val.tag() != .map) return error.TypeError;
                    const old_map = ex_val.asMap();

                    // Check if the method already exists in the map (replace in-place)
                    const method_key = Value.initString(self.allocator, method_name);
                    var replaced = false;
                    {
                        var j: usize = 0;
                        while (j + 1 < old_map.entries.len) : (j += 2) {
                            if (old_map.entries[j].eql(method_key)) {
                                @constCast(old_map.entries)[j + 1] = method_fn;
                                replaced = true;
                                break;
                            }
                        }
                    }

                    if (!replaced) {
                        // New method for this type — append
                        const new_entries = self.allocator.alloc(Value, old_map.entries.len + 2) catch return error.OutOfMemory;
                        if (self.gc == null) self.allocated_slices.append(self.allocator, new_entries) catch return error.OutOfMemory;
                        @memcpy(new_entries[0..old_map.entries.len], old_map.entries);
                        new_entries[old_map.entries.len] = method_key;
                        new_entries[old_map.entries.len + 1] = method_fn;
                        const new_method_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                        new_method_map.* = .{ .entries = new_entries };
                        if (self.gc == null) self.allocated_maps.append(self.allocator, new_method_map) catch return error.OutOfMemory;
                        // Update impls: replace the type_key -> method_map entry
                        const impls = protocol.impls;
                        var i: usize = 0;
                        while (i < impls.entries.len) : (i += 2) {
                            if (impls.entries[i].eql(Value.initString(self.allocator, type_key))) {
                                @constCast(impls.entries)[i + 1] = Value.initMap(new_method_map);
                                break;
                            }
                        }
                    }
                } else {
                    // New type — create method map and add to impls
                    const method_entries = self.allocator.alloc(Value, 2) catch return error.OutOfMemory;
                    if (self.gc == null) self.allocated_slices.append(self.allocator, method_entries) catch return error.OutOfMemory;
                    method_entries[0] = Value.initString(self.allocator, method_name);
                    method_entries[1] = method_fn;
                    const method_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                    method_map.* = .{ .entries = method_entries };
                    if (self.gc == null) self.allocated_maps.append(self.allocator, method_map) catch return error.OutOfMemory;

                    // Add type_key -> method_map to impls
                    const old_impls = protocol.impls;
                    const new_impls_entries = self.allocator.alloc(Value, old_impls.entries.len + 2) catch return error.OutOfMemory;
                    if (self.gc == null) self.allocated_slices.append(self.allocator, new_impls_entries) catch return error.OutOfMemory;
                    @memcpy(new_impls_entries[0..old_impls.entries.len], old_impls.entries);
                    new_impls_entries[old_impls.entries.len] = Value.initString(self.allocator, type_key);
                    new_impls_entries[old_impls.entries.len + 1] = Value.initMap(method_map);
                    const new_impls = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                    new_impls.* = .{ .entries = new_impls_entries };
                    if (self.gc == null) self.allocated_maps.append(self.allocator, new_impls) catch return error.OutOfMemory;
                    protocol.impls = new_impls;
                }

                // Invalidate ProtocolFn inline caches by bumping generation
                protocol.generation +%= 1;

                try self.push(Value.nil_val);
            },

            // [K] Exceptions
            .try_begin => {
                // Register exception handler
                if (self.handler_count >= HANDLERS_MAX) return error.StackOverflow;
                const catch_ip = frame.ip + instr.operand;
                if (catch_ip > frame.code.len) return error.InvalidInstruction;
                self.handlers[self.handler_count] = .{
                    .catch_ip = catch_ip,
                    .saved_sp = self.sp,
                    .saved_frame_count = self.frame_count,
                    .frame_idx = self.frame_count - 1,
                };
                self.handler_count += 1;
            },
            .catch_begin => {
                // No-op: marker for catch clause entry.
                // Handler was already popped by throw_ex (exception flow).
            },
            .exception_type_check => {
                // Peek at exception on top of stack, check type against constant class name.
                // If no match, re-throw the exception.
                const predicates = @import("../../lang/builtins/predicates.zig");
                const class_name_val = frame.constants[instr.operand];
                const class_name = class_name_val.asString();
                const ex_val = self.stack[self.sp - 1];
                if (!predicates.exceptionMatchesClass(ex_val, class_name)) {
                    // Re-throw: pop exception and propagate
                    const thrown = self.pop();
                    dispatch.last_thrown_exception = thrown;
                    if (self.handler_count > 0) {
                        const handler = self.handlers[self.handler_count - 1];
                        if (handler.saved_frame_count > self.call_target_frame) {
                            self.handler_count -= 1;
                            if (self.env) |env| {
                                if (self.frame_count > handler.saved_frame_count) {
                                    const ns_ptr = self.frames[handler.saved_frame_count].saved_ns;
                                    env.current_ns = if (ns_ptr) |p| @ptrCast(@alignCast(p)) else null;
                                }
                            }
                            self.sp = handler.saved_sp;
                            self.frame_count = handler.saved_frame_count;
                            try self.push(thrown);
                            self.frames[handler.frame_idx].ip = handler.catch_ip;
                            err_mod.saveCallStack();
                            err_mod.clearCallStack();
                        } else {
                            return error.UserException;
                        }
                    } else {
                        return error.UserException;
                    }
                }
            },
            .pop_handler => {
                // Normal flow: pop handler that was pushed by try_begin
                // (exception flow pops via throw_ex instead)
                if (self.handler_count > 0) {
                    self.handler_count -= 1;
                }
            },
            .try_end => {
                // Marker only — no-op
            },
            .throw_ex => {
                const thrown = self.pop();
                // Only dispatch to handlers within the current call scope.
                // Handlers at or below call_target_frame belong to an outer
                // callFunction scope and must not intercept our exception.
                if (self.handler_count > 0) {
                    const handler = self.handlers[self.handler_count - 1];
                    if (handler.saved_frame_count > self.call_target_frame) {
                        self.handler_count -= 1;
                        // Restore namespace from unwound call frames (D68).
                        if (self.env) |env| {
                            if (self.frame_count > handler.saved_frame_count) {
                                const ns_ptr = self.frames[handler.saved_frame_count].saved_ns;
                                env.current_ns = if (ns_ptr) |p| @ptrCast(@alignCast(p)) else null;
                            }
                        }
                        // Restore state
                        self.sp = handler.saved_sp;
                        self.frame_count = handler.saved_frame_count;
                        // Push exception value (becomes the catch binding)
                        try self.push(thrown);
                        // Jump to catch handler
                        self.frames[handler.frame_idx].ip = handler.catch_ip;
                        err_mod.saveCallStack();
                        err_mod.clearCallStack();
                    } else {
                        // Handler out of scope — propagate to bridge
                        dispatch.last_thrown_exception = thrown;
                        return error.UserException;
                    }
                } else {
                    // No handler — save value for cross-backend propagation
                    dispatch.last_thrown_exception = thrown;
                    return error.UserException;
                }
            },

            // [M] Arithmetic
            .add => try self.vmBinaryArith(.add),
            .sub => try self.vmBinaryArith(.sub),
            .mul => try self.vmBinaryArith(.mul),
            .add_p => try self.vmBinaryArithPromote(.add),
            .sub_p => try self.vmBinaryArithPromote(.sub),
            .mul_p => try self.vmBinaryArithPromote(.mul),
            .div => try self.vmBinaryDivLike(arith.binaryDiv),
            .lt => try self.vmBinaryCompare(.lt),
            .le => try self.vmBinaryCompare(.le),
            .gt => try self.vmBinaryCompare(.gt),
            .ge => try self.vmBinaryCompare(.ge),
            .mod => try self.vmBinaryDivLike(arith.binaryMod),
            .rem_ => try self.vmBinaryDivLike(arith.binaryRem),
            .eq => {
                const b = self.pop();
                const a = self.pop();
                // Use eqlAlloc to realize nested lazy-seqs during comparison
                try self.push(Value.initBoolean(a.eqlAlloc(b, self.allocator)));
            },
            .neq => {
                const b = self.pop();
                const a = self.pop();
                try self.push(Value.initBoolean(!a.eqlAlloc(b, self.allocator)));
            },

            // [S] Superinstructions (37.2) — fused 3-instruction sequences
            .add_locals => try self.vmSuperArithLocals(frame, instr.operand, .add),
            .sub_locals => try self.vmSuperArithLocals(frame, instr.operand, .sub),
            .eq_locals => try self.vmSuperEqLocals(frame, instr.operand),
            .lt_locals => try self.vmSuperCompareLocals(frame, instr.operand, .lt),
            .le_locals => try self.vmSuperCompareLocals(frame, instr.operand, .le),
            .add_local_const => try self.vmSuperArithLocalConst(frame, instr.operand, .add),
            .sub_local_const => try self.vmSuperArithLocalConst(frame, instr.operand, .sub),
            .eq_local_const => try self.vmSuperEqLocalConst(frame, instr.operand),
            .lt_local_const => try self.vmSuperCompareLocalConst(frame, instr.operand, .lt),
            .le_local_const => try self.vmSuperCompareLocalConst(frame, instr.operand, .le),

            // [T] Fused branch + loop superinstructions (37.3)
            .branch_ne_locals => self.vmBranchEqLocals(frame, instr.operand, true),
            .branch_ge_locals => try self.vmBranchCompareLocals(frame, instr.operand, .lt, true),
            .branch_gt_locals => try self.vmBranchCompareLocals(frame, instr.operand, .le, true),
            .branch_ne_local_const => self.vmBranchEqLocalConst(frame, instr.operand, true),
            .branch_ge_local_const => try self.vmBranchCompareLocalConst(frame, instr.operand, .lt, true),
            .branch_gt_local_const => try self.vmBranchCompareLocalConst(frame, instr.operand, .le, true),
            .recur_loop => self.vmRecurLoop(frame, instr.operand),

            // [Z] Debug
            .nop => {},
            .debug_print => _ = self.pop(),

            // Upvalue opcodes unused — CW closures capture via environment, not upvalues.
            .upvalue_load, .upvalue_store => return error.InvalidInstruction,
        }
        return null;
    }

    /// Check if a VMError is a user-catchable runtime error.
    fn isUserError(e: VMError) bool {
        return switch (e) {
            error.TypeError, error.ArityError, error.NameError,
            error.UndefinedVar, error.Overflow, error.UserException,
            error.ArithmeticError, error.IndexError, error.ValueError,
            error.IoError, error.AnalyzeError, error.EvalError => true,
            error.StackOverflow, error.StackUnderflow, error.OutOfMemory,
            error.InvalidInstruction => false,
        };
    }

    /// Create an ex-info style exception Value from a Zig error.
    fn createRuntimeException(self: *VM, e: VMError) VMError!Value {
        // Prefer threadlocal error message (set by builtins via err.setErrorFmt)
        var ex_type: []const u8 = switch (e) {
            error.TypeError => "ClassCastException",
            error.ArityError => "ArityException",
            error.Overflow, error.ArithmeticError => "ArithmeticException",
            error.IndexError => "IndexOutOfBoundsException",
            error.ValueError => "IllegalArgumentException",
            error.UserException => "Exception",
            else => "RuntimeException",
        };
        const msg: []const u8 = if (err_mod.getLastError()) |info| blk: {
            ex_type = switch (info.kind) {
                .type_error => "ClassCastException",
                .arity_error => "ArityException",
                .arithmetic_error => "ArithmeticException",
                .index_error => "IndexOutOfBoundsException",
                .value_error => "IllegalArgumentException",
                .io_error => "IOException",
                else => ex_type,
            };
            break :blk info.message;
        } else switch (e) {
            error.TypeError => "Type error",
            error.ArityError => "Wrong number of arguments",
            error.Overflow => "Arithmetic overflow",
            error.ArithmeticError => "Arithmetic error",
            error.IndexError => "Index out of bounds",
            error.ValueError => "Value error",
            error.UndefinedVar => "Var not found",
            error.UserException => "Exception",
            else => "Runtime error",
        };

        // Build {:__ex_info true :message msg :data {} :cause nil :__ex_type type}
        const entries = self.allocator.alloc(Value, 10) catch return error.OutOfMemory;
        if (self.gc == null) self.allocated_slices.append(self.allocator, entries) catch return error.OutOfMemory;

        const empty_map = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
        empty_map.* = .{ .entries = &.{} };
        if (self.gc == null) self.allocated_maps.append(self.allocator, empty_map) catch return error.OutOfMemory;

        entries[0] = Value.initKeyword(self.allocator, .{ .ns = null, .name = "__ex_info" });
        entries[1] = Value.true_val;
        entries[2] = Value.initKeyword(self.allocator, .{ .ns = null, .name = "message" });
        entries[3] = Value.initString(self.allocator, msg);
        entries[4] = Value.initKeyword(self.allocator, .{ .ns = null, .name = "data" });
        entries[5] = Value.initMap(empty_map);
        entries[6] = Value.initKeyword(self.allocator, .{ .ns = null, .name = "cause" });
        entries[7] = Value.nil_val;
        entries[8] = Value.initKeyword(self.allocator, .{ .ns = null, .name = "__ex_type" });
        entries[9] = Value.initString(self.allocator, ex_type);

        const map = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
        map.* = .{ .entries = entries };
        if (self.gc == null) self.allocated_maps.append(self.allocator, map) catch return error.OutOfMemory;

        return Value.initMap(map);
    }

    /// Dispatch a runtime error to the nearest exception handler.
    fn dispatchErrorToHandler(self: *VM, err: VMError) VMError!void {
        self.handler_count -= 1;
        const handler = self.handlers[self.handler_count];
        // Restore namespace from unwound call frames (D68).
        if (self.env) |env| {
            if (self.frame_count > handler.saved_frame_count) {
                const ns_ptr = self.frames[handler.saved_frame_count].saved_ns;
                env.current_ns = if (ns_ptr) |p| @ptrCast(@alignCast(p)) else null;
            }
        }
        self.sp = handler.saved_sp;
        self.frame_count = handler.saved_frame_count;

        // Check for preserved exception value from TreeWalk boundary crossing
        const ex = if (err == error.UserException) blk: {
            if (dispatch.last_thrown_exception) |thrown| {
                dispatch.last_thrown_exception = null;
                break :blk thrown;
            }
            break :blk try self.createRuntimeException(err);
        } else try self.createRuntimeException(err);

        err_mod.saveCallStack();
        err_mod.clearCallStack();
        try self.push(ex);
        self.frames[handler.frame_idx].ip = handler.catch_ip;
    }

    pub fn push(self: *VM, val: Value) VMError!void {
        if (self.sp >= STACK_MAX) {
            @branchHint(.unlikely);
            return error.StackOverflow;
        }
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) Value {
        std.debug.assert(self.sp > 0); // stack underflow: compiler bug
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM, distance: usize) Value {
        std.debug.assert(self.sp > 0 and distance < self.sp); // stack underflow: compiler bug
        return self.stack[self.sp - 1 - distance];
    }

    // --- Collection helper ---

    const CollectionKind = enum { list, vec, map, set };

    fn buildCollection(self: *VM, operand: u16, kind: CollectionKind) VMError!void {
        // For map_new, operand is pair count; actual values = pairs * 2
        const count: usize = if (kind == .map) @as(usize, operand) * 2 else operand;

        // Pop values into a new slice
        const items = self.allocator.alloc(Value, count) catch return error.OutOfMemory;
        if (self.gc == null) self.allocated_slices.append(self.allocator, items) catch return error.OutOfMemory;

        // Pop in reverse order to maintain original order
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            items[i] = self.pop();
        }

        switch (kind) {
            .list => {
                const lst = self.allocator.create(PersistentList) catch return error.OutOfMemory;
                lst.* = .{ .items = items };
                if (self.gc == null) self.allocated_lists.append(self.allocator, lst) catch return error.OutOfMemory;
                try self.push(Value.initList(lst));
            },
            .vec => {
                const vec = self.allocator.create(PersistentVector) catch return error.OutOfMemory;
                vec.* = .{ .items = items };
                if (self.gc == null) self.allocated_vectors.append(self.allocator, vec) catch return error.OutOfMemory;
                try self.push(Value.initVector(vec));
            },
            .map => {
                const m = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
                m.* = .{ .entries = items };
                if (self.gc == null) self.allocated_maps.append(self.allocator, m) catch return error.OutOfMemory;
                try self.push(Value.initMap(m));
            },
            .set => {
                const s = self.allocator.create(PersistentHashSet) catch return error.OutOfMemory;
                s.* = .{ .items = items };
                if (self.gc == null) self.allocated_sets.append(self.allocator, s) catch return error.OutOfMemory;
                try self.push(Value.initSet(s));
            },
        }
    }

    // --- Call helper ---

    pub fn performCall(self: *VM, arg_count: u16) VMError!void {
        // Stack layout: [..., fn_val, arg0, arg1, ...argN]
        //                      ^fn_idx          ^sp-1
        const fn_idx = self.sp - arg_count - 1;
        const callee = self.stack[fn_idx];

        // Dispatch by callee type. Each callable type has a dedicated handler:
        //  - fn_val: push new call frame for bytecode/treewalk closures
        //  - builtin_fn: direct Zig function pointer call (no frame overhead)
        //  - keyword/map/vector/set: collection-as-function lookups (inline)
        //  - protocol_fn: type-based dispatch with monomorphic inline cache
        //  - multi_fn: value-based dispatch with 2-level cache
        //  - var_ref: deref and re-dispatch
        switch (callee.tag()) {
            .fn_val => return self.callFnVal(fn_idx, callee.asFn(), callee, arg_count),
            .builtin_fn => {
                const bfn = callee.asBuiltinFn();
                const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
                const result = bfn(self.allocator, args) catch |e| {
                    return @as(VMError, @errorCast(e));
                };
                self.sp = fn_idx;
                try self.push(result);
            },
            .keyword => {
                const kw = callee.asKeyword();
                if (arg_count < 1 or arg_count > 2) {
                    if (arg_count > 20) {
                        if (kw.ns) |ns| {
                            err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args (> 20) passed to: :{s}/{s}", .{ ns, kw.name });
                        } else {
                            err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args (> 20) passed to: :{s}", .{kw.name});
                        }
                    } else if (kw.ns) |ns| {
                        err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: :{s}/{s}", .{ arg_count, ns, kw.name });
                    } else {
                        err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: :{s}", .{ arg_count, kw.name });
                    }
                    return error.ArityError;
                }
                const map_arg = self.stack[fn_idx + 1];
                const result = if (map_arg.tag() == .wasm_module and arg_count == 1) blk: {
                    // Keyword lookup on wasm_module: (:add mod) => cached WasmFn
                    const wm = map_arg.asWasmModule();
                    break :blk if (wm.getExportFn(kw.name)) |wf|
                        Value.initWasmFn(wf)
                    else
                        Value.nil_val;
                } else if (map_arg.tag() == .map)
                    map_arg.asMap().get(callee) orelse (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil_val)
                else if (map_arg.tag() == .hash_map)
                    map_arg.asHashMap().get(callee) orelse (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil_val)
                else if (arg_count >= 2)
                    self.stack[fn_idx + 2]
                else
                    Value.nil_val;
                self.sp = fn_idx;
                try self.push(result);
            },
            .set => {
                if (arg_count < 1) return error.ArityError;
                const key = self.stack[fn_idx + 1];
                const result = callee.asSet().get(key) orelse Value.nil_val;
                self.sp = fn_idx;
                try self.push(result);
            },
            .vector => {
                const v = callee.asVector();
                if (arg_count < 1) return error.ArityError;
                const idx_val = self.stack[fn_idx + 1];
                if (idx_val.tag() != .integer) return error.TypeError;
                const idx = idx_val.asInteger();
                if (idx < 0 or idx >= @as(i64, @intCast(v.items.len))) {
                    if (arg_count >= 2) {
                        const result = self.stack[fn_idx + 2];
                        self.sp = fn_idx;
                        try self.push(result);
                        return;
                    }
                    return error.IndexError;
                }
                const result = v.items[@intCast(idx)];
                self.sp = fn_idx;
                try self.push(result);
            },
            .map => {
                if (arg_count < 1) return error.ArityError;
                const key = self.stack[fn_idx + 1];
                const result = callee.asMap().get(key) orelse
                    (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil_val);
                self.sp = fn_idx;
                try self.push(result);
            },
            .hash_map => {
                if (arg_count < 1) return error.ArityError;
                const key = self.stack[fn_idx + 1];
                const result = callee.asHashMap().get(key) orelse
                    (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil_val);
                self.sp = fn_idx;
                try self.push(result);
            },
            .wasm_module => {
                const wm = callee.asWasmModule();
                // Module-as-function: (mod :add) => cached WasmFn
                if (arg_count != 1) return error.ArityError;
                const key = self.stack[fn_idx + 1];
                const name = switch (key.tag()) {
                    .keyword => key.asKeyword().name,
                    .string => key.asString(),
                    else => return error.TypeError,
                };
                const result = if (wm.getExportFn(name)) |wf|
                    Value.initWasmFn(wf)
                else
                    Value.nil_val;
                self.sp = fn_idx;
                try self.push(result);
            },
            .protocol_fn => {
                const pf = callee.asProtocolFn();
                // Protocol dispatch with monomorphic inline cache.
                //
                // Full dispatch requires: type_key lookup -> impls map scan ->
                // method_name lookup -> fn resolution. The inline cache stores
                // the last (type_key -> method) pair. When the same type is seen
                // again (common in loops), the full lookup is skipped entirely.
                //
                // Cache check uses pointer equality first (O(1)) with string
                // equality fallback (handles interned vs non-interned keys).
                if (arg_count < 1) return error.ArityError;
                const first_arg = self.stack[fn_idx + 1];
                const type_key = valueTypeKey(first_arg);
                const mutable_pf: *ProtocolFn = @constCast(pf);

                // extend-via-metadata: check (meta obj) BEFORE cache
                // (metadata is per-object, not per-type — cache would give wrong result)
                if (pf.protocol.extend_via_metadata) {
                    if (pf.protocol.defining_ns) |def_ns| {
                        const meta_mod = @import("../../lang/builtins/metadata.zig");
                        const meta_val = meta_mod.getMeta(first_arg);
                        if (meta_val.tag() == .map or meta_val.tag() == .hash_map) {
                            const fq_key = Value.initSymbol(self.allocator, .{ .ns = def_ns, .name = pf.method_name });
                            const lookup = if (meta_val.tag() == .map) meta_val.asMap().get(fq_key) else meta_val.asHashMap().get(fq_key);
                            if (lookup) |meta_method| {
                                self.stack[fn_idx] = meta_method;
                                return self.performCall(arg_count);
                            }
                        }
                    }
                }

                // Monomorphic inline cache: check if same type as last dispatch
                if (mutable_pf.cached_type_key) |ck| {
                    if (mutable_pf.cached_generation == pf.protocol.generation and
                        (ck.ptr == type_key.ptr or std.mem.eql(u8, ck, type_key)))
                    {
                        self.stack[fn_idx] = mutable_pf.cached_method;
                        return self.performCall(arg_count);
                    }
                }
                // 2. Standard impls lookup (exact type, then "Object" fallback)
                // Use getByStringKey to avoid allocating temporary HeapString Values
                const method_map_val = pf.protocol.impls.getByStringKey(type_key) orelse
                    pf.protocol.impls.getByStringKey("Object") orelse
                    return error.TypeError;
                if (method_map_val.tag() != .map) return error.TypeError;
                const method_fn = method_map_val.asMap().getByStringKey(pf.method_name) orelse
                    return error.TypeError;
                // Update cache for next call
                mutable_pf.cached_type_key = type_key;
                mutable_pf.cached_method = method_fn;
                mutable_pf.cached_generation = pf.protocol.generation;
                self.stack[fn_idx] = method_fn;
                return self.performCall(arg_count);
            },
            .var_ref => {
                self.stack[fn_idx] = callee.asVarRef().deref();
                return self.performCall(arg_count);
            },
            .multi_fn => {
                const mf = callee.asMultiFn();
                // Multimethod dispatch with 2-level monomorphic cache.
                //
                // Without caching, each multimethod call requires:
                //   1. Call the dispatch function (e.g. :type keyword lookup)
                //   2. findBestMethod: scan method table + isa? hierarchy
                // This was 2053ms for 10K calls (multimethod_dispatch benchmark).
                //
                // Level 1 (arg identity): If the dispatch argument is the same
                //   object (pointer equality), the dispatch value hasn't changed,
                //   so skip both the dispatch fn call AND method lookup.
                // Level 2 (dispatch value): If L1 misses but the computed dispatch
                //   value equals the cached one, skip findBestMethod.
                //
                // Result: 2053ms -> 14ms (147x speedup).
                const mf_mut: *value_mod.MultiFn = @constCast(mf);

                const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];

                // Level 1: Combined arg identity cache — skip dispatch fn call entirely
                if (arg_count >= 1 and mf_mut.cached_arg_valid and mf_mut.cached_arg_count == @as(u8, @intCast(arg_count))) {
                    if (value_mod.MultiFn.combinedArgKey(args)) |key| {
                        if (key == mf_mut.cached_arg_key) {
                            self.stack[fn_idx] = mf_mut.cached_method;
                            return self.performCall(arg_count);
                        }
                    }
                }

                // Get dispatch value
                const dispatch_val = blk: {
                    // Fast path: keyword dispatch fn — (defmulti foo :type)
                    if (mf.dispatch_fn.tag() == .keyword) {
                        if (arg_count >= 1) {
                            const first = self.stack[fn_idx + 1];
                            if (first.tag() == .map) {
                                break :blk first.asMap().get(mf.dispatch_fn) orelse Value.nil_val;
                            }
                        }
                        break :blk Value.nil_val;
                    }
                    // General case: call dispatch fn using current VM (not bootstrap)
                    break :blk try self.callFunction(mf.dispatch_fn, args);
                };

                // Level 2: Dispatch-val cache — skip findBestMethod
                const method_fn = blk: {
                    if (mf_mut.cached_dispatch_val) |cdv| {
                        if (cdv.eql(dispatch_val)) break :blk mf_mut.cached_method;
                    }
                    // Cache miss: full lookup
                    const m = multimethods_mod.findBestMethod(self.allocator, mf, dispatch_val, self.env) orelse
                        return error.TypeError;
                    mf_mut.cached_dispatch_val = dispatch_val;
                    mf_mut.cached_method = m;
                    break :blk m;
                };

                // Update combined arg identity cache
                if (arg_count >= 1) {
                    if (value_mod.MultiFn.combinedArgKey(args)) |key| {
                        mf_mut.cached_arg_key = key;
                        mf_mut.cached_arg_count = @intCast(arg_count);
                        mf_mut.cached_arg_valid = true;
                    }
                }

                // Call method via performCall (not bootstrap)
                self.stack[fn_idx] = method_fn;
                return self.performCall(arg_count);
            },
            .wasm_fn => {
                const wf = callee.asWasmFn();
                const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
                const result = wf.call(self.allocator, args) catch |e| {
                    return @as(VMError, @errorCast(e));
                };
                self.sp = fn_idx;
                try self.push(result);
            },
            else => return error.TypeError,
        }
    }

    /// Handle fn_val call — extracted for readability
    fn callFnVal(self: *VM, fn_idx: usize, fn_obj: *const Fn, callee: Value, arg_count: u16) VMError!void {
        // TreeWalk closures: dispatch via unified callFnVal
        if (fn_obj.kind == .treewalk) {
            const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
            const result = dispatch.callFnVal(self.allocator, callee, args) catch |e| {
                return @as(VMError, @errorCast(e));
            };
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        // Arity dispatch: find matching proto
        const proto: *const FnProto = try findProtoByArity(fn_obj, arg_count);

        // Variadic: collect rest args into a list
        // For (fn [x & xs] body), arity=2 (x and xs), fixed=1.
        // If called with 3 args: stack=[1,2,3] → stack=[1,(2 3)]
        var current_arg_count = arg_count;
        if (proto.variadic and proto.arity > 0) {
            const fixed: u16 = proto.arity - 1; // number of fixed params (excluding rest param)
            const args_start = fn_idx + 1;

            if (arg_count >= fixed) {
                const rest_count = arg_count - fixed;
                // Build rest list or nil from stack values
                if (rest_count == 0) {
                    // No rest args: rest param is nil (matches Clojure/TreeWalk behavior)
                    self.stack[args_start + fixed] = Value.nil_val;
                } else if (rest_count == 1 and dispatch.apply_rest_is_seq) {
                    // Already a seq from apply's lazy path (F99) — use directly
                    dispatch.apply_rest_is_seq = false;
                } else {
                    const rest_items = self.allocator.alloc(Value, rest_count) catch return error.OutOfMemory;
                    for (0..rest_count) |i| {
                        rest_items[i] = self.stack[args_start + fixed + i];
                    }
                    const rest_list = self.allocator.create(PersistentList) catch return error.OutOfMemory;
                    rest_list.* = .{ .items = rest_items };
                    if (self.gc == null) self.allocated_lists.append(self.allocator, rest_list) catch return error.OutOfMemory;
                    self.stack[args_start + fixed] = Value.initList(rest_list);
                }

                // Adjust sp: fixed params + 1 rest param (list or nil)
                self.sp = args_start + fixed + 1;
                current_arg_count = fixed + 1; // fixed params + 1 rest param
            } else {
                // Fewer args than fixed params: rest is nil
                // This shouldn't normally happen due to arity check, but handle gracefully
            }
        }

        // Inject closure_bindings before args if present
        const closure_count: u16 = if (fn_obj.closure_bindings) |cb| @intCast(cb.len) else 0;
        if (closure_count > 0) {
            const cb = fn_obj.closure_bindings.?;
            const args_start = fn_idx + 1;
            shiftStackRight(self.stack[0..], args_start, current_arg_count, closure_count);
            for (0..closure_count) |i| {
                self.stack[args_start + i] = cb[i];
            }
            self.sp += closure_count;
        }

        // Named fn self-reference: inject fn_val at slot after captures, before args
        if (proto.has_self_ref) {
            const self_slot = fn_idx + 1 + closure_count;
            shiftStackRight(self.stack[0..], self_slot, current_arg_count, 1);
            self.stack[self_slot] = callee;
            self.sp += 1;
        }

        // Switch current_ns to the function's defining namespace (D68).
        var saved_ns_ptr: ?*anyopaque = null;
        if (self.env) |env| {
            saved_ns_ptr = if (env.current_ns) |ns| @ptrCast(ns) else null;
            if (fn_obj.defining_ns) |def_ns_name| {
                if (env.findNamespace(def_ns_name)) |def_ns| {
                    env.current_ns = def_ns;
                }
            }
        }

        // Push new call frame
        if (self.frame_count >= FRAMES_MAX) {
            @branchHint(.unlikely);
            return error.StackOverflow;
        }
        self.frames[self.frame_count] = .{
            .ip = 0,
            .base = fn_idx + 1,
            .code = proto.code,
            .constants = proto.constants,
            .source_file = proto.source_file,
            .lines = proto.lines,
            .columns = proto.columns,
            .saved_ns = saved_ns_ptr,
        };
        self.frame_count += 1;

        // Track call stack for error reporting
        err_mod.pushFrame(.{
            .fn_name = proto.name,
            .ns = fn_obj.defining_ns,
            .file = proto.source_file orelse err_mod.getSourceFile(),
            .line = if (proto.lines.len > 0) proto.lines[0] else 0,
            .column = if (proto.columns.len > 0) proto.columns[0] else 0,
        });
    }

    // --- Arity dispatch ---

    fn findProtoByArity(fn_obj: *const Fn, arg_count: u16) VMError!*const FnProto {
        const primary: *const FnProto = @ptrCast(@alignCast(fn_obj.proto));

        // Phase 1: Exact match across all arities (prefer over variadic)
        if (!primary.variadic and primary.arity == arg_count) return primary;
        if (fn_obj.extra_arities) |extras| {
            for (extras) |extra| {
                const p: *const FnProto = @ptrCast(@alignCast(extra));
                if (!p.variadic and p.arity == arg_count) return p;
            }
        }

        // Phase 2: Variadic fallback across all arities
        if (primary.variadic and arg_count >= primary.arity -| 1) return primary;
        if (fn_obj.extra_arities) |extras| {
            for (extras) |extra| {
                const p: *const FnProto = @ptrCast(@alignCast(extra));
                if (p.variadic and arg_count >= p.arity -| 1) return p;
            }
        }

        const fn_name = primary.name orelse "fn";
        const ns_name = fn_obj.defining_ns orelse "";
        if (ns_name.len > 0) {
            err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: {s}/{s}", .{ arg_count, ns_name, fn_name });
        } else {
            err_mod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to: {s}", .{ arg_count, fn_name });
        }
        return error.ArityError;
    }

    // --- Arithmetic helpers ---
    //
    // Optimization: The int+int fast path is inlined directly in the
    // VM instead of calling through the shared arithmetic.zig module. This
    // eliminates a cross-file function call per arithmetic op, which compounds
    // dramatically in recursive benchmarks (fib_recursive: 502ms -> 41ms, 12x).
    //
    // Zig's @addWithOverflow/@subWithOverflow/@mulWithOverflow return a tuple
    // (result, overflow_bit). On overflow, we promote to f64 (matching Clojure's
    // auto-promotion semantics). The overflow path is marked @branchHint(.unlikely)
    // so LLVM keeps the fast path contiguous in the instruction cache.

    fn vmBinaryArith(self: *VM, comptime op: arith.ArithOp) VMError!void {
        const b = self.pop();
        const a = self.pop();
        // Fast path: both operands are integers — inline arithmetic with overflow check
        if (a.tag() == .integer and b.tag() == .integer) {
            const ai = a.asInteger();
            const bi = b.asInteger();
            const result = switch (op) {
                .add => @addWithOverflow(ai, bi),
                .sub => @subWithOverflow(ai, bi),
                .mul => @mulWithOverflow(ai, bi),
            };
            if (result[1] != 0) {
                @branchHint(.unlikely);
                // Overflow: promote to float
                self.saveVmArgSources();
                try self.push(Value.initFloat(switch (op) {
                    .add => @as(f64, @floatFromInt(ai)) + @as(f64, @floatFromInt(bi)),
                    .sub => @as(f64, @floatFromInt(ai)) - @as(f64, @floatFromInt(bi)),
                    .mul => @as(f64, @floatFromInt(ai)) * @as(f64, @floatFromInt(bi)),
                }));
                return;
            }
            try self.push(Value.initInteger(result[0]));
            return;
        }
        self.saveVmArgSources();
        try self.push(arith.binaryArith(a, b, op) catch return error.TypeError);
    }

    /// Auto-promoting binary arithmetic: overflow → BigInt instead of float.
    fn vmBinaryArithPromote(self: *VM, comptime op: arith.ArithOp) VMError!void {
        const b = self.pop();
        const a = self.pop();
        // Fast path: both operands are integers
        if (a.tag() == .integer and b.tag() == .integer) {
            const ai = a.asInteger();
            const bi = b.asInteger();
            const result = switch (op) {
                .add => @addWithOverflow(ai, bi),
                .sub => @subWithOverflow(ai, bi),
                .mul => @mulWithOverflow(ai, bi),
            };
            if (result[1] != 0) {
                @branchHint(.unlikely);
                // i64 overflow: promote to BigInt
                self.saveVmArgSources();
                const bi_result = arith.bigIntArith(self.allocator, a, b, op) catch return error.OutOfMemory;
                try self.push(bi_result);
                return;
            }
            const r = result[0];
            if (r < arith.I48_MIN or r > arith.I48_MAX) {
                @branchHint(.unlikely);
                // Exceeds i48 range: promote to BigInt
                self.saveVmArgSources();
                const big = collections.BigInt.initFromI64(self.allocator, r) catch return error.OutOfMemory;
                try self.push(Value.initBigInt(big));
                return;
            }
            try self.push(Value.initInteger(r));
            return;
        }
        self.saveVmArgSources();
        try self.push(arith.binaryArithPromote(a, b, op) catch return error.TypeError);
    }

    /// Binary op that may produce ArithmeticError (div, mod, rem).
    fn vmBinaryDivLike(self: *VM, comptime func: fn (Value, Value) anyerror!Value) VMError!void {
        self.saveVmArgSources();
        const b = self.pop();
        const a = self.pop();
        try self.push(func(a, b) catch |e| switch (e) {
            error.ArithmeticError => return error.ArithmeticError,
            else => return error.TypeError,
        });
    }

    fn vmBinaryCompare(self: *VM, comptime op: arith.CompareOp) VMError!void {
        const b = self.pop();
        const a = self.pop();
        // Inline int+int fast path
        if (a.tag() == .integer and b.tag() == .integer) {
            const ai = a.asInteger();
            const bi = b.asInteger();
            try self.push(Value.initBoolean(switch (op) {
                .lt => ai < bi,
                .le => ai <= bi,
                .gt => ai > bi,
                .ge => ai >= bi,
            }));
            return;
        }
        self.saveVmArgSources();
        try self.push(Value.initBoolean(arith.compareFn(a, b, op) catch return error.TypeError));
    }

    // --- Superinstruction helpers (37.2) ---
    //
    // Fused instructions that combine local_load + local_load + op (or local_load +
    // const_load + op) into a single dispatch. Eliminates intermediate pushes/pops
    // and reduces dispatch count by 3x for fused patterns.

    /// Unpack superinstruction operand: (first << 8) | second → (first, second).
    inline fn unpackSuper(operand: u16) struct { u8, u8 } {
        return .{ @intCast(operand >> 8), @truncate(operand) };
    }

    /// Fused local_load a + local_load b + add/sub.
    fn vmSuperArithLocals(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.ArithOp) VMError!void {
        const slots = unpackSuper(operand);
        const a = self.stack[frame.base + slots[0]];
        const b = self.stack[frame.base + slots[1]];
        if (a.tag() == .integer and b.tag() == .integer) {
            const ai = a.asInteger();
            const bi = b.asInteger();
            const result = switch (op) {
                .add => @addWithOverflow(ai, bi),
                .sub => @subWithOverflow(ai, bi),
                .mul => @mulWithOverflow(ai, bi),
            };
            if (result[1] != 0) {
                @branchHint(.unlikely);
                self.saveVmArgSources();
                try self.push(Value.initFloat(switch (op) {
                    .add => @as(f64, @floatFromInt(ai)) + @as(f64, @floatFromInt(bi)),
                    .sub => @as(f64, @floatFromInt(ai)) - @as(f64, @floatFromInt(bi)),
                    .mul => @as(f64, @floatFromInt(ai)) * @as(f64, @floatFromInt(bi)),
                }));
                return;
            }
            try self.push(Value.initInteger(result[0]));
            return;
        }
        self.saveVmArgSources();
        try self.push(arith.binaryArith(a, b, op) catch return error.TypeError);
    }

    /// Fused local_load a + local_load b + eq.
    fn vmSuperEqLocals(self: *VM, frame: *CallFrame, operand: u16) VMError!void {
        const slots = unpackSuper(operand);
        const a = self.stack[frame.base + slots[0]];
        const b = self.stack[frame.base + slots[1]];
        try self.push(Value.initBoolean(a.eqlAlloc(b, self.allocator)));
    }

    /// Fused local_load a + local_load b + lt/le.
    fn vmSuperCompareLocals(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.CompareOp) VMError!void {
        const slots = unpackSuper(operand);
        const a = self.stack[frame.base + slots[0]];
        const b = self.stack[frame.base + slots[1]];
        if (a.tag() == .integer and b.tag() == .integer) {
            try self.push(Value.initBoolean(switch (op) {
                .lt => a.asInteger() < b.asInteger(),
                .le => a.asInteger() <= b.asInteger(),
                .gt => a.asInteger() > b.asInteger(),
                .ge => a.asInteger() >= b.asInteger(),
            }));
            return;
        }
        self.saveVmArgSources();
        try self.push(Value.initBoolean(arith.compareFn(a, b, op) catch return error.TypeError));
    }

    /// Fused local_load slot + const_load idx + add/sub.
    fn vmSuperArithLocalConst(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.ArithOp) VMError!void {
        const parts = unpackSuper(operand);
        const a = self.stack[frame.base + parts[0]];
        const b = frame.constants[parts[1]];
        if (a.tag() == .integer and b.tag() == .integer) {
            const ai = a.asInteger();
            const bi = b.asInteger();
            const result = switch (op) {
                .add => @addWithOverflow(ai, bi),
                .sub => @subWithOverflow(ai, bi),
                .mul => @mulWithOverflow(ai, bi),
            };
            if (result[1] != 0) {
                @branchHint(.unlikely);
                self.saveVmArgSources();
                try self.push(Value.initFloat(switch (op) {
                    .add => @as(f64, @floatFromInt(ai)) + @as(f64, @floatFromInt(bi)),
                    .sub => @as(f64, @floatFromInt(ai)) - @as(f64, @floatFromInt(bi)),
                    .mul => @as(f64, @floatFromInt(ai)) * @as(f64, @floatFromInt(bi)),
                }));
                return;
            }
            try self.push(Value.initInteger(result[0]));
            return;
        }
        self.saveVmArgSources();
        try self.push(arith.binaryArith(a, b, op) catch return error.TypeError);
    }

    /// Fused local_load slot + const_load idx + eq.
    fn vmSuperEqLocalConst(self: *VM, frame: *CallFrame, operand: u16) VMError!void {
        const parts = unpackSuper(operand);
        const a = self.stack[frame.base + parts[0]];
        const b = frame.constants[parts[1]];
        try self.push(Value.initBoolean(a.eqlAlloc(b, self.allocator)));
    }

    /// Fused local_load slot + const_load idx + lt/le.
    fn vmSuperCompareLocalConst(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.CompareOp) VMError!void {
        const parts = unpackSuper(operand);
        const a = self.stack[frame.base + parts[0]];
        const b = frame.constants[parts[1]];
        if (a.tag() == .integer and b.tag() == .integer) {
            try self.push(Value.initBoolean(switch (op) {
                .lt => a.asInteger() < b.asInteger(),
                .le => a.asInteger() <= b.asInteger(),
                .gt => a.asInteger() > b.asInteger(),
                .ge => a.asInteger() >= b.asInteger(),
            }));
            return;
        }
        self.saveVmArgSources();
        try self.push(Value.initBoolean(arith.compareFn(a, b, op) catch return error.TypeError));
    }

    // --- Fused branch + loop helpers (37.3) ---
    //
    // Compare-and-branch: fuse comparison superinstruction + jump_if_false
    // into a single dispatch. Eliminates intermediate boolean push/pop and
    // the jump_if_false dispatch. Next code word holds the jump offset.
    //
    // recur_loop: fuse recur + jump_back into single dispatch. Next code
    // word holds the loop offset.

    /// Fused eq_locals + jump_if_false. Branches if NOT equal.
    fn vmBranchEqLocals(self: *VM, frame: *CallFrame, operand: u16, comptime negate: bool) void {
        const slots = unpackSuper(operand);
        const a = self.stack[frame.base + slots[0]];
        const b = self.stack[frame.base + slots[1]];
        const eq = a.eqlAlloc(b, self.allocator);
        const branch = if (negate) !eq else eq;
        // Consume next code word (jump offset)
        const offset = frame.code[frame.ip].signedOperand();
        frame.ip += 1;
        if (branch) {
            frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + @as(i32, offset));
        }
    }

    /// Fused lt/le_locals + jump_if_false. Branches if comparison is false.
    fn vmBranchCompareLocals(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.CompareOp, comptime negate: bool) VMError!void {
        const slots = unpackSuper(operand);
        const a = self.stack[frame.base + slots[0]];
        const b = self.stack[frame.base + slots[1]];
        var cmp: bool = undefined;
        if (a.tag() == .integer and b.tag() == .integer) {
            cmp = switch (op) {
                .lt => a.asInteger() < b.asInteger(),
                .le => a.asInteger() <= b.asInteger(),
                .gt => a.asInteger() > b.asInteger(),
                .ge => a.asInteger() >= b.asInteger(),
            };
        } else {
            self.saveVmArgSources();
            cmp = arith.compareFn(a, b, op) catch return error.TypeError;
        }
        const branch = if (negate) !cmp else cmp;
        const offset = frame.code[frame.ip].signedOperand();
        frame.ip += 1;
        if (branch) {
            frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + @as(i32, offset));
        }
    }

    /// Fused eq_local_const + jump_if_false. Branches if NOT equal.
    fn vmBranchEqLocalConst(self: *VM, frame: *CallFrame, operand: u16, comptime negate: bool) void {
        const parts = unpackSuper(operand);
        const a = self.stack[frame.base + parts[0]];
        const b = frame.constants[parts[1]];
        const eq = a.eqlAlloc(b, self.allocator);
        const branch = if (negate) !eq else eq;
        const offset = frame.code[frame.ip].signedOperand();
        frame.ip += 1;
        if (branch) {
            frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + @as(i32, offset));
        }
    }

    /// Fused lt/le_local_const + jump_if_false. Branches if comparison is false.
    fn vmBranchCompareLocalConst(self: *VM, frame: *CallFrame, operand: u16, comptime op: arith.CompareOp, comptime negate: bool) VMError!void {
        const parts = unpackSuper(operand);
        const a = self.stack[frame.base + parts[0]];
        const b = frame.constants[parts[1]];
        var cmp: bool = undefined;
        if (a.tag() == .integer and b.tag() == .integer) {
            cmp = switch (op) {
                .lt => a.asInteger() < b.asInteger(),
                .le => a.asInteger() <= b.asInteger(),
                .gt => a.asInteger() > b.asInteger(),
                .ge => a.asInteger() >= b.asInteger(),
            };
        } else {
            self.saveVmArgSources();
            cmp = arith.compareFn(a, b, op) catch return error.TypeError;
        }
        const branch = if (negate) !cmp else cmp;
        const offset = frame.code[frame.ip].signedOperand();
        frame.ip += 1;
        if (branch) {
            frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + @as(i32, offset));
        }
    }

    /// Fused recur + jump_back: rebind loop vars and jump back in single dispatch.
    fn vmRecurLoop(self: *VM, frame: *CallFrame, operand: u16) void {
        const arg_count: u16 = operand & 0xFF;
        const base_offset: u16 = (operand >> 8) & 0xFF;

        // Copy recur args directly from stack to loop binding slots.
        // Source (top of stack) is always above target (loop binding slots),
        // so there is no overlap — direct copy is safe.
        const src_start = self.sp - arg_count;
        const dst_start = frame.base + base_offset;
        for (0..arg_count) |idx| {
            self.stack[dst_start + idx] = self.stack[src_start + idx];
        }

        // Reset sp to just after loop bindings
        self.sp = dst_start + arg_count;

        // Consume next code word (loop offset) and jump back
        const data_ip = frame.ip;
        const loop_offset = frame.code[data_ip].operand;
        const loop_top = data_ip + 1 - loop_offset;
        frame.ip = loop_top;

        // JIT: detect hot loops and compile to native code (ARM64 only).
        if (enable_jit) {
            const loop_end = data_ip + 1;
            if (self.tryJitExecution(frame, loop_top, loop_end)) return;
        }
    }

    /// Try to execute a JIT-compiled loop or compile one if hot enough.
    /// Returns true if JIT handled the remaining iterations.
    fn tryJitExecution(self: *VM, frame: *CallFrame, loop_top: usize, loop_end: usize) bool {
        if (!enable_jit) return false;
        var js = &self.jit_state;

        // Fast path: execute cached JIT function.
        if (js.jit_fn) |jit_fn| {
            if (js.loop_code_ptr == frame.code.ptr and js.loop_start_ip == loop_top) {
                const result = jit_fn(
                    @ptrCast(&self.stack),
                    frame.base,
                    @ptrCast(frame.constants.ptr),
                );
                if (result.status == 0) {
                    // Success: push result, skip to post-loop (pop_under).
                    self.stack[self.sp] = @enumFromInt(result.value);
                    self.sp += 1;
                    frame.ip = loop_end;
                    return true;
                }
                // Deopt: invalidate and don't retry.
                js.jit_fn = null;
                js.loop_count = std.math.maxInt(u32);
                return false;
            }
        }

        // Warmup counting.
        if (js.loop_code_ptr == frame.code.ptr and js.loop_start_ip == loop_top) {
            if (js.loop_count == std.math.maxInt(u32)) return false; // already tried and failed
            js.loop_count += 1;
            if (js.loop_count < JIT_THRESHOLD) return false;

            // Compile the hot loop.
            if (js.compiler == null) {
                js.compiler = jit_mod.JitCompiler.init() catch return false;
            } else {
                // Re-compilation attempt with existing compiler (buffer may be EXEC).
                // Deinit and create fresh compiler.
                js.compiler.?.deinit();
                js.compiler = jit_mod.JitCompiler.init() catch return false;
            }
            js.jit_fn = js.compiler.?.compileLoop(
                frame.code,
                @ptrCast(frame.constants.ptr),
                loop_top,
                loop_end,
            );
            if (js.jit_fn == null) {
                js.loop_count = std.math.maxInt(u32);
                return false;
            }

            // Execute the newly compiled function immediately.
            const result = js.jit_fn.?(
                @ptrCast(&self.stack),
                frame.base,
                @ptrCast(frame.constants.ptr),
            );
            if (result.status == 0) {
                self.stack[self.sp] = @enumFromInt(result.value);
                self.sp += 1;
                frame.ip = loop_end;
                return true;
            }
            // Deopt on first execution — don't retry.
            js.jit_fn = null;
            js.loop_count = std.math.maxInt(u32);
            return false;
        }

        // New loop — start counting.
        js.loop_code_ptr = frame.code.ptr;
        js.loop_start_ip = loop_top;
        js.loop_count = 1;
        js.jit_fn = null;
        // Discard old compiler (old JIT code is no longer needed).
        if (js.compiler) |*c| {
            c.deinit();
            js.compiler = null;
        }
        return false;
    }

    /// Save arg sources from VM debug info for the current binary op instruction.
    /// ip-1 = binary op. Its column is the second operand's (arg1) compile position.
    /// Scan backward to find a different column for the first operand (arg0).
    fn saveVmArgSources(self: *VM) void {
        const f = &self.frames[self.frame_count - 1];
        if (f.columns.len == 0 or f.ip == 0) return;
        const file = err_mod.getSourceFile();
        // arg1: column of the binary op instruction (= last compiled operand)
        const arg1_col = f.columns[f.ip - 1];
        const arg1_line: u32 = if (f.lines.len > 0) f.lines[f.ip - 1] else 0;
        err_mod.saveArgSource(1, .{ .line = arg1_line, .column = arg1_col, .file = file });
        // arg0: scan backward from ip-2 to find a distinct source column
        var arg0_col = arg1_col;
        var arg0_line = arg1_line;
        if (f.ip >= 2) {
            var i: usize = f.ip - 2;
            while (true) {
                if (f.columns[i] != arg1_col or (f.lines.len > 0 and f.lines[i] != arg1_line)) {
                    arg0_col = f.columns[i];
                    arg0_line = if (f.lines.len > 0) f.lines[i] else 0;
                    break;
                }
                if (i == 0) break;
                i -= 1;
            }
        }
        err_mod.saveArgSource(0, .{ .line = arg0_line, .column = arg0_col, .file = file });
    }
};

/// Map user-facing type name to internal type key.
/// Duplicated from tree_walk.zig to avoid circular imports.
fn mapTypeKey(type_name: []const u8) []const u8 {
    if (std.mem.eql(u8, type_name, "String")) return "string";
    if (std.mem.eql(u8, type_name, "Integer") or std.mem.eql(u8, type_name, "Long")) return "integer";
    if (std.mem.eql(u8, type_name, "Double") or std.mem.eql(u8, type_name, "Float")) return "float";
    if (std.mem.eql(u8, type_name, "Boolean")) return "boolean";
    if (std.mem.eql(u8, type_name, "nil")) return "nil";
    if (std.mem.eql(u8, type_name, "Keyword")) return "keyword";
    if (std.mem.eql(u8, type_name, "Symbol")) return "symbol";
    if (std.mem.eql(u8, type_name, "PersistentList") or std.mem.eql(u8, type_name, "List")) return "list";
    if (std.mem.eql(u8, type_name, "PersistentVector") or std.mem.eql(u8, type_name, "Vector")) return "vector";
    if (std.mem.eql(u8, type_name, "PersistentArrayMap") or std.mem.eql(u8, type_name, "Map")) return "map";
    if (std.mem.eql(u8, type_name, "PersistentHashSet") or std.mem.eql(u8, type_name, "Set")) return "set";
    if (std.mem.eql(u8, type_name, "Atom")) return "atom";
    if (std.mem.eql(u8, type_name, "Volatile")) return "volatile";
    if (std.mem.eql(u8, type_name, "Pattern")) return "regex";
    if (std.mem.eql(u8, type_name, "Character")) return "char";
    // Java class short names → FQCN (for extend-type with imported classes)
    if (std.mem.eql(u8, type_name, "PushbackReader")) return "java.io.PushbackReader";
    if (std.mem.eql(u8, type_name, "StringReader")) return "java.io.StringReader";
    if (std.mem.eql(u8, type_name, "Reader")) return "java.io.Reader";
    if (std.mem.eql(u8, type_name, "Writer")) return "java.io.Writer";
    if (std.mem.eql(u8, type_name, "StringWriter")) return "java.io.StringWriter";
    if (std.mem.eql(u8, type_name, "StringBuilder")) return "java.lang.StringBuilder";
    if (std.mem.eql(u8, type_name, "File")) return "java.io.File";
    if (std.mem.eql(u8, type_name, "URI")) return "java.net.URI";
    if (std.mem.eql(u8, type_name, "UUID")) return "java.util.UUID";
    return type_name;
}

/// Get type key string for a runtime value.
/// Duplicated from tree_walk.zig to avoid circular imports.
fn valueTypeKey(val: Value) []const u8 {
    return switch (val.tag()) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .char => "char",
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => blk: {
            // Check for reified object: small map with :__reify_type key
            const entries = val.asMap().entries;
            var idx: usize = 0;
            while (idx + 1 < entries.len) : (idx += 2) {
                if (entries[idx].tag() == .keyword) {
                    const kw = entries[idx].asKeyword();
                    if (kw.ns == null and std.mem.eql(u8, kw.name, "__reify_type")) {
                        if (entries[idx + 1].tag() == .string) {
                            break :blk entries[idx + 1].asString();
                        }
                    }
                }
            }
            break :blk "map";
        },
        .hash_map => "map",
        .set => "set",
        .fn_val, .builtin_fn => "function",
        .atom => "atom",
        .volatile_ref => "volatile",
        .regex => "regex",
        .protocol => "protocol",
        .protocol_fn => "protocol_fn",
        .multi_fn => "multi_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
        .var_ref => "var",
        .delay => "delay",
        .future => "future",
        .promise => "promise",
        .agent => "agent",
        .ref => "ref",
        .reduced => "reduced",
        .transient_vector => "transient_vector",
        .transient_map => "transient_map",
        .transient_set => "transient_set",
        .chunked_cons => "chunked_cons",
        .chunk_buffer => "chunk_buffer",
        .array_chunk => "array_chunk",
        .wasm_module => "wasm_module",
        .wasm_fn => "wasm_fn",
        .matcher => "matcher",
        .array => "array",
        .big_int => "big_int",
        .ratio => "ratio",
        .big_decimal => "big_decimal",
    };
}

/// Shift `count` stack elements starting at `start` to the right by `shift` positions.
/// Used to make room for injected values (closure bindings, self-reference).
fn shiftStackRight(stack: []Value, start: usize, count: u16, shift: u16) void {
    if (count == 0) return;
    var i: u16 = count;
    while (i > 0) {
        i -= 1;
        stack[start + shift + i] = stack[start + i];
    }
}

// === Tests ===

test "VM run nil constant" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.emitOp(.nil);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.nil_val, result);
}

test "VM run true/false constants" {
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        try chunk.emitOp(.true_val);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.true_val, result);
    }
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        try chunk.emitOp(.false_val);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.false_val, result);
    }
}

test "VM run const_load integer" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(Value.initInteger(42));
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(42), result);
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
    try std.testing.expectEqual(Value.nil_val, result);
}

test "VM dup duplicates top" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(Value.initInteger(7));
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.dup);
    try chunk.emitOp(.pop); // pop the duplicate
    try chunk.emitOp(.ret); // return original

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(7), result);
}

test "VM local_load and local_store" {
    // Simulate: push 10, store slot 0, push 20, store slot 1, load slot 0, ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c10 = try chunk.addConstant(Value.initInteger(10));
    const c20 = try chunk.addConstant(Value.initInteger(20));
    try chunk.emit(.const_load, c10); // stack: [10]
    try chunk.emit(.const_load, c20); // stack: [10, 20]
    try chunk.emit(.local_load, 0); // push slot 0 (=10) -> stack: [10, 20, 10]
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(10), result);
}

test "VM jump_if_false (if true 1 2)" {
    // Bytecode for (if true 1 2):
    // true_val, jump_if_false +2, const_load(1), jump +1, const_load(2), ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(Value.initInteger(1));
    const c2 = try chunk.addConstant(Value.initInteger(2));

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
    try std.testing.expectEqual(Value.initInteger(1), result);
}

test "VM jump_if_false (if false 1 2)" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(Value.initInteger(1));
    const c2 = try chunk.addConstant(Value.initInteger(2));

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
    try std.testing.expectEqual(Value.initInteger(2), result);
}

test "VM integer arithmetic" {
    // (+ 3 4) = 7
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c3 = try chunk.addConstant(Value.initInteger(3));
        const c4 = try chunk.addConstant(Value.initInteger(4));
        try chunk.emit(.const_load, c3);
        try chunk.emit(.const_load, c4);
        try chunk.emitOp(.add);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.initInteger(7), result);
    }
    // (- 10 3) = 7
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c10 = try chunk.addConstant(Value.initInteger(10));
        const c3 = try chunk.addConstant(Value.initInteger(3));
        try chunk.emit(.const_load, c10);
        try chunk.emit(.const_load, c3);
        try chunk.emitOp(.sub);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.initInteger(7), result);
    }
    // (* 6 7) = 42
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c6 = try chunk.addConstant(Value.initInteger(6));
        const c7 = try chunk.addConstant(Value.initInteger(7));
        try chunk.emit(.const_load, c6);
        try chunk.emit(.const_load, c7);
        try chunk.emitOp(.mul);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.initInteger(42), result);
    }
}

test "VM comparison operators" {
    // (< 1 2) = true
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c1 = try chunk.addConstant(Value.initInteger(1));
        const c2 = try chunk.addConstant(Value.initInteger(2));
        try chunk.emit(.const_load, c1);
        try chunk.emit(.const_load, c2);
        try chunk.emitOp(.lt);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.true_val, result);
    }
    // (> 1 2) = false
    {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        const c1 = try chunk.addConstant(Value.initInteger(1));
        const c2 = try chunk.addConstant(Value.initInteger(2));
        try chunk.emit(.const_load, c1);
        try chunk.emit(.const_load, c2);
        try chunk.emitOp(.gt);
        try chunk.emitOp(.ret);
        var vm = VM.init(std.testing.allocator);
        const result = try vm.run(&chunk);
        try std.testing.expectEqual(Value.false_val, result);
    }
}

test "VM float arithmetic" {
    // (+ 1.5 2.5) = 4.0
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const c1 = try chunk.addConstant(Value.initFloat(1.5));
    const c2 = try chunk.addConstant(Value.initFloat(2.5));
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emitOp(.add);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initFloat(4.0), result);
}

test "VM mixed int/float arithmetic" {
    // (+ 1 2.5) = 3.5
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const c1 = try chunk.addConstant(Value.initInteger(1));
    const c2 = try chunk.addConstant(Value.initFloat(2.5));
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emitOp(.add);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initFloat(3.5), result);
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
    const fn_obj = Value.initFn(&.{ .proto = &proto, .closure_bindings = null });
    const idx = try chunk.addConstant(fn_obj);
    try chunk.emit(.closure, idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .fn_val);
}

test "VM call simple function" {
    // (fn [] 42) called with 0 args
    const fn_code = [_]Instruction{
        .{ .op = .const_load, .operand = 0 },
        .{ .op = .ret },
    };
    const fn_constants = [_]Value{Value.initInteger(42)};
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

    const fn_obj = Value.initFn(&.{ .proto = &proto, .closure_bindings = null });
    const idx = try chunk.addConstant(fn_obj);
    try chunk.emit(.closure, idx);
    try chunk.emit(.call, 0);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(42), result);
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

    const fn_obj = Value.initFn(&.{ .proto = &proto, .closure_bindings = null });
    const fn_idx = try chunk.addConstant(fn_obj);
    const c3 = try chunk.addConstant(Value.initInteger(3));
    const c4 = try chunk.addConstant(Value.initInteger(4));

    try chunk.emit(.closure, fn_idx);
    try chunk.emit(.const_load, c3);
    try chunk.emit(.const_load, c4);
    try chunk.emit(.call, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(7), result);
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
    const capture_slot_0 = [_]u16{0};
    const inner_proto = FnProto{
        .name = null,
        .arity = 1,
        .variadic = false,
        .local_count = 2,
        .capture_count = 1, // captures 1 value from parent
        .capture_slots = &capture_slot_0, // capture from parent slot 0
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

    const c10 = try chunk.addConstant(Value.initInteger(10));
    const fn_template = Value.initFn(&.{ .proto = &inner_proto, .closure_bindings = null });
    const fn_idx = try chunk.addConstant(fn_template);
    const c5 = try chunk.addConstant(Value.initInteger(5));

    try chunk.emit(.const_load, c10); // push 10
    try chunk.emit(.closure, fn_idx); // create closure capturing [10]
    try chunk.emit(.const_load, c5); // push 5
    try chunk.emit(.call, 1); // call with 1 arg
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(15), result);
}

test "VM compiler+vm integration: (fn [x] x) called" {
    // Compile (fn [x] x) and call it with 42
    const allocator = std.testing.allocator;
    const node_mod = @import("../analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../compiler/compiler.zig");

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
    var arg = Node{ .constant = .{ .value = Value.initInteger(42) } };
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
    try std.testing.expectEqual(Value.initInteger(42), result);
}

test "VM compiler+vm integration: closure capture via let" {
    // (let [x 10] ((fn [y] (+ x y)) 5)) => 15
    // x is a local in let, fn captures it
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node_mod = @import("../analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../compiler/compiler.zig");

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
    var arg_5 = Node{ .constant = .{ .value = Value.initInteger(5) } };
    var call_args = [_]*Node{&arg_5};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &call_args,
        .source = .{},
    };
    var call_node = Node{ .call_node = &call_data };

    // let: (let [x 10] ...)
    var init_10 = Node{ .constant = .{ .value = Value.initInteger(10) } };
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
    const idx = try chunk.addConstant(Value.initInteger(99));
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.nop);
    try chunk.emitOp(.ret);
    var vm = VM.init(std.testing.allocator);
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(99), result);
}

test "VM var_load resolves pre-defined Var" {
    // Setup: create Env with a Var bound to 42
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;
    const v = try ns.intern("x");
    v.bindRoot(Value.initInteger(42));

    // Bytecode: var_load (symbol "x"), ret
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "x" }));
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(alloc, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(42), result);
}

test "VM def creates and binds a Var" {
    // (def x 42) -> should bind x=42 in current namespace, return symbol
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    // Bytecode: const_load(42), def(symbol "x"), ret
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "x" }));
    const val_idx = try chunk.addConstant(Value.initInteger(42));
    try chunk.emit(.const_load, val_idx);
    try chunk.emit(.def, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(alloc, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);

    // def returns the var
    try std.testing.expect(result.tag() == .var_ref);
    const result_var = result.asVarRef();
    try std.testing.expectEqualStrings("x", result_var.sym.name);
    try std.testing.expectEqualStrings("user", result_var.ns_name);

    // Var should be bound in namespace
    const v = ns.resolve("x").?;
    try std.testing.expect(v.deref().eql(Value.initInteger(42)));
}

test "VM def then var_load round-trip" {
    // (do (def x 10) x) => 10
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    // (def x 10)
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "x" }));
    const val_idx = try chunk.addConstant(Value.initInteger(10));
    try chunk.emit(.const_load, val_idx);
    try chunk.emit(.def, sym_idx);
    try chunk.emitOp(.pop); // discard def result

    // x (var_load)
    const var_sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "x" }));
    try chunk.emit(.var_load, var_sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(alloc, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(10), result);
}

test "VM var_load undefined var returns error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "nonexistent" }));
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(alloc, &env);
    defer vm.deinit();
    try std.testing.expectError(error.UndefinedVar, vm.run(&chunk));
}

test "VM var_load without env returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = null, .name = "x" }));
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(alloc);
    defer vm.deinit();
    try std.testing.expectError(error.UndefinedVar, vm.run(&chunk));
}

test "VM var_load qualified symbol" {
    // user/x resolves via resolveQualified
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;
    const v = try ns.intern("x");
    v.bindRoot(Value.initInteger(99));

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(Value.initSymbol(alloc, .{ .ns = "user", .name = "x" }));
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(alloc, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value.initInteger(99), result);
}

test "VM compiler+vm: loop/recur counts to 5" {
    // (loop [x 0] (if (< x 5) (recur (+ x 1)) x)) => 5
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node_mod = @import("../analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../compiler/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // Build AST
    // loop binding: x = 0
    var init_0 = Node{ .constant = .{ .value = Value.initInteger(0) } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_0 },
    };

    // test: (< x 5)
    var x_ref1 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var five = Node{ .constant = .{ .value = Value.initInteger(5) } };
    var lt_callee = Node{ .var_ref = .{ .ns = null, .name = "<", .source = .{} } };
    var lt_args = [_]*Node{ &x_ref1, &five };
    var lt_call = node_mod.CallNode{ .callee = &lt_callee, .args = &lt_args, .source = .{} };
    var test_node = Node{ .call_node = &lt_call };

    // then: (recur (+ x 1))
    var x_ref2 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var one = Node{ .constant = .{ .value = Value.initInteger(1) } };
    var add_callee = Node{ .var_ref = .{ .ns = null, .name = "+", .source = .{} } };
    var add_args = [_]*Node{ &x_ref2, &one };
    var add_call = node_mod.CallNode{ .callee = &add_callee, .args = &add_args, .source = .{} };
    var add_node = Node{ .call_node = &add_call };
    var recur_args = [_]*Node{&add_node};
    var recur_data = node_mod.RecurNode{ .args = &recur_args, .source = .{} };
    var then_node = Node{ .recur_node = &recur_data };

    // else: x
    var x_ref3 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };

    // if node
    var if_data = node_mod.IfNode{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &x_ref3,
        .source = .{},
    };
    var body = Node{ .if_node = &if_data };

    // loop node
    var loop_data = node_mod.LoopNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const loop_node = Node{ .loop_node = &loop_data };

    try compiler.compile(&loop_node);
    try compiler.chunk.emitOp(.ret);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try vm.run(&compiler.chunk);
    try std.testing.expectEqual(Value.initInteger(5), result);
}

test "VM vec_new creates vector" {
    // Push 3 values, vec_new 3 -> [1 2 3]
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(Value.initInteger(1));
    const c2 = try chunk.addConstant(Value.initInteger(2));
    const c3 = try chunk.addConstant(Value.initInteger(3));
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.const_load, c3);
    try chunk.emit(.vec_new, 3);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try std.testing.expect(result.asVector().items[0].eql(Value.initInteger(1)));
    try std.testing.expect(result.asVector().items[1].eql(Value.initInteger(2)));
    try std.testing.expect(result.asVector().items[2].eql(Value.initInteger(3)));
}

test "VM list_new creates list" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(Value.initInteger(10));
    const c2 = try chunk.addConstant(Value.initInteger(20));
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.list_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 2), result.asList().items.len);
    try std.testing.expect(result.asList().items[0].eql(Value.initInteger(10)));
    try std.testing.expect(result.asList().items[1].eql(Value.initInteger(20)));
}

test "VM map_new creates map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    // {:a 1 :b 2} -> 4 values, map_new 2 (pairs)
    const ka = try chunk.addConstant(Value.initKeyword(alloc, .{ .ns = null, .name = "a" }));
    const v1 = try chunk.addConstant(Value.initInteger(1));
    const kb = try chunk.addConstant(Value.initKeyword(alloc, .{ .ns = null, .name = "b" }));
    const v2 = try chunk.addConstant(Value.initInteger(2));
    try chunk.emit(.const_load, ka);
    try chunk.emit(.const_load, v1);
    try chunk.emit(.const_load, kb);
    try chunk.emit(.const_load, v2);
    try chunk.emit(.map_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(alloc);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .map);
    try std.testing.expectEqual(@as(usize, 2), result.asMap().count());
}

test "VM try/catch handles throw" {
    // (try (throw "err") (catch e e)) => "err"
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node_mod = @import("../analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../compiler/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // AST: (try (throw "err") (catch e e))
    var throw_expr = Node{ .constant = .{ .value = Value.initString(allocator, "err") } };
    var throw_data = node_mod.ThrowNode{ .expr = &throw_expr, .source = .{} };
    var throw_node = Node{ .throw_node = &throw_data };

    var catch_body = Node{ .local_ref = .{ .name = "e", .idx = 0, .source = .{} } };
    const catch_clause = node_mod.CatchClause{
        .class_name = "Exception",
        .binding_name = "e",
        .body = &catch_body,
    };
    var try_data = node_mod.TryNode{
        .body = &throw_node,
        .catch_clause = catch_clause,
        .finally_body = null,
        .source = .{},
    };
    const try_node = Node{ .try_node = &try_data };

    try compiler.compile(&try_node);
    try compiler.chunk.emitOp(.ret);

    var vm = VM.init(allocator);
    defer vm.deinit();
    const result = try vm.run(&compiler.chunk);
    try std.testing.expect(result.tag() == .string);
    try std.testing.expectEqualStrings("err", result.asString());
}

test "VM throw without handler returns UserException" {
    // (throw "err") without try/catch
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chunk = Chunk.init(alloc);
    defer chunk.deinit();
    const idx = try chunk.addConstant(Value.initString(alloc, "oops"));
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.throw_ex);
    try chunk.emitOp(.ret);

    var vm = VM.init(alloc);
    defer vm.deinit();
    try std.testing.expectError(error.UserException, vm.run(&chunk));
}

test "VM set_new creates set" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(Value.initInteger(1));
    const c2 = try chunk.addConstant(Value.initInteger(2));
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.set_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .set);
    try std.testing.expectEqual(@as(usize, 2), result.asSet().count());
}

test "VM empty vec_new" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    try chunk.emit(.vec_new, 0);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result.tag() == .vector);
    try std.testing.expectEqual(@as(usize, 0), result.asVector().items.len);
}

test {
    _ = jit_mod;
}
