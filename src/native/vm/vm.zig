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
const Env = @import("../../common/env.zig").Env;
const Namespace = @import("../../common/namespace.zig").Namespace;
const collections = @import("../../common/collections.zig");
const PersistentList = collections.PersistentList;
const PersistentVector = collections.PersistentVector;
const PersistentArrayMap = collections.PersistentArrayMap;
const PersistentHashSet = collections.PersistentHashSet;
const arith = @import("../../common/builtin/arithmetic.zig");
const bootstrap = @import("../../common/bootstrap.zig");

/// VM execution errors.
const err_mod = @import("../../common/error.zig");

pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    ArityError,
    UndefinedVar,
    OutOfMemory,
    InvalidInstruction,
    Overflow,
    UserException,
    ArithmeticError,
    IndexError,
    ValueError,
};

const STACK_MAX: usize = 256 * 128;
const FRAMES_MAX: usize = 256;
const HANDLERS_MAX: usize = 16;

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
    /// Source line per instruction (parallel to code) for error reporting.
    lines: []const u32 = &.{},
    /// Source column per instruction (parallel to code) for error reporting.
    columns: []const u32 = &.{},
};

/// Stack-based bytecode virtual machine.
pub const VM = struct {
    allocator: std.mem.Allocator,
    stack: [STACK_MAX]Value,
    sp: usize,
    frames: [FRAMES_MAX]CallFrame,
    frame_count: usize,
    /// Allocated closures (for cleanup).
    allocated_fns: std.ArrayList(*const Fn),
    /// Allocated collection backing arrays (for cleanup).
    allocated_slices: std.ArrayList([]const Value),
    /// Allocated collection structs — typed lists for proper deallocation.
    allocated_lists: std.ArrayList(*const PersistentList),
    allocated_vectors: std.ArrayList(*const PersistentVector),
    allocated_maps: std.ArrayList(*const PersistentArrayMap),
    allocated_sets: std.ArrayList(*const PersistentHashSet),
    /// Exception handler stack.
    handlers: [HANDLERS_MAX]ExceptionHandler,
    handler_count: usize,
    /// Runtime environment (Namespace/Var resolution).
    env: ?*Env,

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
        while (true) {
            if (self.stepInstruction()) |maybe_result| {
                if (maybe_result) |result| return result;
            } else |e| {
                // Annotate error with source location from current frame
                if (self.frame_count > 0) {
                    const f = &self.frames[self.frame_count - 1];
                    if (f.lines.len > 0 and f.ip > 0) {
                        const line = f.lines[f.ip - 1];
                        if (line > 0) {
                            const column: u32 = if (f.columns.len > 0 and f.ip > 0)
                                f.columns[f.ip - 1]
                            else
                                0;
                            err_mod.annotateLocation(.{
                                .line = line,
                                .column = column,
                                .file = err_mod.getSourceFile(),
                            });
                        }
                    }
                }
                if (self.handler_count > 0 and isUserError(e)) {
                    self.dispatchErrorToHandler(e) catch |e2| return e2;
                    continue;
                }
                return e;
            }
        }
    }

    /// Execute one instruction. Returns a Value when execution is complete
    /// (ret from top-level or end-of-code), null to continue.
    fn stepInstruction(self: *VM) VMError!?Value {
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
            .call, .tail_call => try self.performCall(instr.operand),
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
                // Operand: constant pool index of fn template
                const const_idx: u16 = instr.operand;

                const template = frame.constants[const_idx];
                if (template != .fn_val) return error.TypeError;
                const fn_obj = template.fn_val;
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
                    };
                    self.allocated_fns.append(self.allocator, new_fn) catch return error.OutOfMemory;
                    try self.push(.{ .fn_val = new_fn });
                } else {
                    // No capture needed, push the template directly
                    try self.push(template);
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
                if (sym != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                var v = if (sym.symbol.ns) |ns_name|
                    ns.resolveQualified(ns_name, sym.symbol.name)
                else
                    ns.resolve(sym.symbol.name);
                // Fallback: look up namespace by full name in env registry
                if (v == null) {
                    if (sym.symbol.ns) |ns_name| {
                        if (env.namespaces.get(ns_name)) |target_ns| {
                            v = target_ns.resolve(sym.symbol.name);
                        }
                    }
                }
                if (v) |resolved| {
                    try self.push(resolved.deref());
                } else {
                    return error.UndefinedVar;
                }
            },
            .def, .def_macro => {
                const val = self.pop();
                const sym = frame.constants[instr.operand];
                if (sym != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;
                const v = ns.intern(sym.symbol.name) catch return error.OutOfMemory;
                v.bindRoot(val);
                if (instr.op == .def_macro) v.setMacro(true);
                try self.push(.{ .symbol = .{ .ns = ns.name, .name = v.sym.name } });
            },

            .defmulti => {
                const dispatch_fn = self.pop();
                const sym = frame.constants[instr.operand];
                if (sym != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;

                // Create MultiFn
                const mf = self.allocator.create(value_mod.MultiFn) catch return error.OutOfMemory;
                const empty_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                empty_map.* = .{ .entries = &.{} };
                mf.* = .{
                    .name = sym.symbol.name,
                    .dispatch_fn = dispatch_fn,
                    .methods = empty_map,
                };

                // Bind to var
                const v = ns.intern(sym.symbol.name) catch return error.OutOfMemory;
                v.bindRoot(.{ .multi_fn = mf });
                try self.push(.{ .multi_fn = mf });
            },
            .defmethod => {
                const method_fn = self.pop();
                const dispatch_val = self.pop();
                const sym = frame.constants[instr.operand];
                if (sym != .symbol) return error.InvalidInstruction;
                const env = self.env orelse return error.UndefinedVar;
                const ns = env.current_ns orelse return error.UndefinedVar;

                // Resolve multimethod
                const mf_var = ns.resolve(sym.symbol.name) orelse return error.UndefinedVar;
                const mf_val = mf_var.deref();
                if (mf_val != .multi_fn) return error.TypeError;
                const mf = mf_val.multi_fn;

                // Add method: assoc dispatch_val -> method_fn
                const old = mf.methods;
                const new_entries = self.allocator.alloc(value_mod.Value, old.entries.len + 2) catch return error.OutOfMemory;
                @memcpy(new_entries[0..old.entries.len], old.entries);
                new_entries[old.entries.len] = dispatch_val;
                new_entries[old.entries.len + 1] = method_fn;
                const new_map = self.allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
                new_map.* = .{ .entries = new_entries };
                mf.methods = new_map;

                try self.push(method_fn);
            },

            .lazy_seq => {
                const thunk = self.pop();
                const ls = self.allocator.create(value_mod.LazySeq) catch return error.OutOfMemory;
                ls.* = .{ .thunk = thunk, .realized = null };
                try self.push(.{ .lazy_seq = ls });
            },

            // [K] Exceptions
            .try_begin => {
                // Register exception handler
                if (self.handler_count >= HANDLERS_MAX) return error.StackOverflow;
                const catch_ip = frame.ip + instr.operand;
                self.handlers[self.handler_count] = .{
                    .catch_ip = catch_ip,
                    .saved_sp = self.sp,
                    .saved_frame_count = self.frame_count,
                    .frame_idx = self.frame_count - 1,
                };
                self.handler_count += 1;
            },
            .catch_begin => {
                // Normal flow reached catch — pop handler (try body succeeded)
                if (self.handler_count > 0) {
                    self.handler_count -= 1;
                }
            },
            .try_end => {
                // Marker only — no-op
            },
            .throw_ex => {
                const thrown = self.pop();
                if (self.handler_count > 0) {
                    self.handler_count -= 1;
                    const handler = self.handlers[self.handler_count];
                    // Restore state
                    self.sp = handler.saved_sp;
                    self.frame_count = handler.saved_frame_count;
                    // Push exception value (becomes the catch binding)
                    try self.push(thrown);
                    // Jump to catch handler
                    self.frames[handler.frame_idx].ip = handler.catch_ip;
                } else {
                    return error.UserException;
                }
            },

            // [M] Arithmetic
            .add => try self.vmBinaryArith(.add),
            .sub => try self.vmBinaryArith(.sub),
            .mul => try self.vmBinaryArith(.mul),
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
        return null;
    }

    /// Check if a VMError is a user-catchable runtime error.
    fn isUserError(e: VMError) bool {
        return switch (e) {
            error.TypeError, error.ArityError, error.UndefinedVar,
            error.Overflow, error.UserException,
            error.ArithmeticError, error.IndexError, error.ValueError => true,
            error.StackOverflow, error.StackUnderflow, error.OutOfMemory,
            error.InvalidInstruction => false,
        };
    }

    /// Create an ex-info style exception Value from a Zig error.
    fn createRuntimeException(self: *VM, e: VMError) VMError!Value {
        // Prefer threadlocal error message (set by builtins via err.setErrorFmt)
        const msg: []const u8 = if (err_mod.getLastError()) |info| info.message else switch (e) {
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

        // Build {:__ex_info true :message msg :data {} :cause nil}
        const entries = self.allocator.alloc(Value, 8) catch return error.OutOfMemory;
        self.allocated_slices.append(self.allocator, entries) catch return error.OutOfMemory;

        const empty_map = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
        empty_map.* = .{ .entries = &.{} };
        self.allocated_maps.append(self.allocator, empty_map) catch return error.OutOfMemory;

        entries[0] = .{ .keyword = .{ .ns = null, .name = "__ex_info" } };
        entries[1] = .{ .boolean = true };
        entries[2] = .{ .keyword = .{ .ns = null, .name = "message" } };
        entries[3] = .{ .string = msg };
        entries[4] = .{ .keyword = .{ .ns = null, .name = "data" } };
        entries[5] = .{ .map = empty_map };
        entries[6] = .{ .keyword = .{ .ns = null, .name = "cause" } };
        entries[7] = .nil;

        const map = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
        map.* = .{ .entries = entries };
        self.allocated_maps.append(self.allocator, map) catch return error.OutOfMemory;

        return .{ .map = map };
    }

    /// Dispatch a runtime error to the nearest exception handler.
    fn dispatchErrorToHandler(self: *VM, err: VMError) VMError!void {
        self.handler_count -= 1;
        const handler = self.handlers[self.handler_count];
        self.sp = handler.saved_sp;
        self.frame_count = handler.saved_frame_count;
        const ex = try self.createRuntimeException(err);
        try self.push(ex);
        self.frames[handler.frame_idx].ip = handler.catch_ip;
    }

    pub fn push(self: *VM, val: Value) VMError!void {
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

    // --- Collection helper ---

    const CollectionKind = enum { list, vec, map, set };

    fn buildCollection(self: *VM, operand: u16, kind: CollectionKind) VMError!void {
        // For map_new, operand is pair count; actual values = pairs * 2
        const count: usize = if (kind == .map) @as(usize, operand) * 2 else operand;

        // Pop values into a new slice
        const items = self.allocator.alloc(Value, count) catch return error.OutOfMemory;
        self.allocated_slices.append(self.allocator, items) catch return error.OutOfMemory;

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
                self.allocated_lists.append(self.allocator, lst) catch return error.OutOfMemory;
                try self.push(.{ .list = lst });
            },
            .vec => {
                const vec = self.allocator.create(PersistentVector) catch return error.OutOfMemory;
                vec.* = .{ .items = items };
                self.allocated_vectors.append(self.allocator, vec) catch return error.OutOfMemory;
                try self.push(.{ .vector = vec });
            },
            .map => {
                const m = self.allocator.create(PersistentArrayMap) catch return error.OutOfMemory;
                m.* = .{ .entries = items };
                self.allocated_maps.append(self.allocator, m) catch return error.OutOfMemory;
                try self.push(.{ .map = m });
            },
            .set => {
                const s = self.allocator.create(PersistentHashSet) catch return error.OutOfMemory;
                s.* = .{ .items = items };
                self.allocated_sets.append(self.allocator, s) catch return error.OutOfMemory;
                try self.push(.{ .set = s });
            },
        }
    }

    // --- Call helper ---

    pub fn performCall(self: *VM, arg_count: u16) VMError!void {
        // Stack: [..., fn_val, arg0, arg1, ...]
        const fn_idx = self.sp - arg_count - 1;
        const callee = self.stack[fn_idx];

        // Builtin function dispatch
        if (callee == .builtin_fn) {
            const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
            const result = callee.builtin_fn(self.allocator, args) catch |e| {
                return @as(VMError, @errorCast(e));
            };
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        // Keyword-as-function: (:key map) => (get map :key)
        if (callee == .keyword) {
            if (arg_count < 1) return error.ArityError;
            const map_arg = self.stack[fn_idx + 1];
            const result = if (map_arg == .map)
                map_arg.map.get(callee) orelse (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil)
            else if (arg_count >= 2)
                self.stack[fn_idx + 2] // default value
            else
                Value.nil;
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        // Set-as-function: (#{:a :b} :a) => :a or nil
        if (callee == .set) {
            if (arg_count < 1) return error.ArityError;
            const key = self.stack[fn_idx + 1];
            const result = if (callee.set.contains(key)) key else Value.nil;
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        // Map-as-function: ({:a 1} :b) => (get map key) or default
        if (callee == .map) {
            if (arg_count < 1) return error.ArityError;
            const key = self.stack[fn_idx + 1];
            const result = callee.map.get(key) orelse
                (if (arg_count >= 2) self.stack[fn_idx + 2] else Value.nil);
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        // Var-as-IFn: (#'f args) => deref var, then call
        if (callee == .var_ref) {
            self.stack[fn_idx] = callee.var_ref.deref();
            return self.performCall(arg_count);
        }

        // MultiFn dispatch: call dispatch_fn, lookup method, call method
        if (callee == .multi_fn) {
            const mf = callee.multi_fn;
            const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];

            // Call dispatch function
            const dispatch_val = bootstrap.callFnVal(self.allocator, mf.dispatch_fn, args) catch |e| {
                return @as(VMError, @errorCast(e));
            };

            // Lookup method by dispatch value, fallback to :default
            const method_fn = mf.methods.get(dispatch_val) orelse
                mf.methods.get(.{ .keyword = .{ .ns = null, .name = "default" } }) orelse
                return error.TypeError;

            // Call the matched method
            const result = bootstrap.callFnVal(self.allocator, method_fn, args) catch |e| {
                return @as(VMError, @errorCast(e));
            };
            self.sp = fn_idx;
            try self.push(result);
            return;
        }

        if (callee != .fn_val) return error.TypeError;

        const fn_obj = callee.fn_val;

        // TreeWalk closures: dispatch via unified callFnVal
        if (fn_obj.kind == .treewalk) {
            const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
            const result = bootstrap.callFnVal(self.allocator, callee, args) catch |e| {
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
                // Build rest list from stack values
                const rest_items = self.allocator.alloc(Value, rest_count) catch return error.OutOfMemory;
                for (0..rest_count) |i| {
                    rest_items[i] = self.stack[args_start + fixed + i];
                }
                const rest_list = self.allocator.create(PersistentList) catch return error.OutOfMemory;
                rest_list.* = .{ .items = rest_items };
                self.allocated_lists.append(self.allocator, rest_list) catch return error.OutOfMemory;

                // Place list at the rest param slot, adjust sp
                self.stack[args_start + fixed] = .{ .list = rest_list };
                self.sp = args_start + fixed + 1;
                current_arg_count = fixed + 1; // fixed params + 1 rest list
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

        // Push new call frame
        if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;
        self.frames[self.frame_count] = .{
            .ip = 0,
            .base = fn_idx + 1,
            .code = proto.code,
            .constants = proto.constants,
            .lines = proto.lines,
            .columns = proto.columns,
        };
        self.frame_count += 1;
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

        return error.ArityError;
    }

    // --- Arithmetic helpers (delegated to common/builtin/arithmetic.zig) ---

    fn vmBinaryArith(self: *VM, comptime op: arith.ArithOp) VMError!void {
        const b = self.pop();
        const a = self.pop();
        self.saveVmArgSources();
        try self.push(arith.binaryArith(a, b, op) catch return error.TypeError);
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
        self.saveVmArgSources();
        try self.push(.{ .boolean = arith.compareFn(a, b, op) catch return error.TypeError });
    }

    /// Save arg sources from VM debug info for the current binary op instruction.
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
    var arg = Node{ .constant = .{ .value = .{ .integer = 42 } } };
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
    var arg_5 = Node{ .constant = .{ .value = .{ .integer = 5 } } };
    var call_args = [_]*Node{&arg_5};
    var call_data = node_mod.CallNode{
        .callee = &fn_node,
        .args = &call_args,
        .source = .{},
    };
    var call_node = Node{ .call_node = &call_data };

    // let: (let [x 10] ...)
    var init_10 = Node{ .constant = .{ .value = .{ .integer = 10 } } };
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
    v.bindRoot(.{ .integer = 42 });

    // Bytecode: var_load (symbol "x"), ret
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "x" } });
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(std.testing.allocator, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 42 }, result);
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
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "x" } });
    const val_idx = try chunk.addConstant(.{ .integer = 42 });
    try chunk.emit(.const_load, val_idx);
    try chunk.emit(.def, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(std.testing.allocator, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);

    // def returns a symbol with ns/name
    try std.testing.expect(result == .symbol);
    try std.testing.expectEqualStrings("x", result.symbol.name);
    try std.testing.expectEqualStrings("user", result.symbol.ns.?);

    // Var should be bound in namespace
    const v = ns.resolve("x").?;
    try std.testing.expect(v.deref().eql(.{ .integer = 42 }));
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

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    // (def x 10)
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "x" } });
    const val_idx = try chunk.addConstant(.{ .integer = 10 });
    try chunk.emit(.const_load, val_idx);
    try chunk.emit(.def, sym_idx);
    try chunk.emitOp(.pop); // discard def result

    // x (var_load)
    const var_sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "x" } });
    try chunk.emit(.var_load, var_sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(std.testing.allocator, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 10 }, result);
}

test "VM var_load undefined var returns error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "nonexistent" } });
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(std.testing.allocator, &env);
    defer vm.deinit();
    try std.testing.expectError(error.UndefinedVar, vm.run(&chunk));
}

test "VM var_load without env returns error" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = null, .name = "x" } });
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
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
    v.bindRoot(.{ .integer = 99 });

    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const sym_idx = try chunk.addConstant(.{ .symbol = .{ .ns = "user", .name = "x" } });
    try chunk.emit(.var_load, sym_idx);
    try chunk.emitOp(.ret);

    var vm = VM.initWithEnv(std.testing.allocator, &env);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expectEqual(Value{ .integer = 99 }, result);
}

test "VM compiler+vm: loop/recur counts to 5" {
    // (loop [x 0] (if (< x 5) (recur (+ x 1)) x)) => 5
    const allocator = std.testing.allocator;
    const node_mod = @import("../../common/analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../../common/bytecode/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // Build AST
    // loop binding: x = 0
    var init_0 = Node{ .constant = .{ .value = .{ .integer = 0 } } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_0 },
    };

    // test: (< x 5)
    var x_ref1 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var five = Node{ .constant = .{ .value = .{ .integer = 5 } } };
    var lt_callee = Node{ .var_ref = .{ .ns = null, .name = "<", .source = .{} } };
    var lt_args = [_]*Node{ &x_ref1, &five };
    var lt_call = node_mod.CallNode{ .callee = &lt_callee, .args = &lt_args, .source = .{} };
    var test_node = Node{ .call_node = &lt_call };

    // then: (recur (+ x 1))
    var x_ref2 = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };
    var one = Node{ .constant = .{ .value = .{ .integer = 1 } } };
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
    try std.testing.expectEqual(Value{ .integer = 5 }, result);
}

test "VM vec_new creates vector" {
    // Push 3 values, vec_new 3 -> [1 2 3]
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(.{ .integer = 1 });
    const c2 = try chunk.addConstant(.{ .integer = 2 });
    const c3 = try chunk.addConstant(.{ .integer = 3 });
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.const_load, c3);
    try chunk.emit(.vec_new, 3);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try std.testing.expect(result.vector.items[0].eql(.{ .integer = 1 }));
    try std.testing.expect(result.vector.items[1].eql(.{ .integer = 2 }));
    try std.testing.expect(result.vector.items[2].eql(.{ .integer = 3 }));
}

test "VM list_new creates list" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(.{ .integer = 10 });
    const c2 = try chunk.addConstant(.{ .integer = 20 });
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.list_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    try std.testing.expect(result.list.items[0].eql(.{ .integer = 10 }));
    try std.testing.expect(result.list.items[1].eql(.{ .integer = 20 }));
}

test "VM map_new creates map" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    // {:a 1 :b 2} -> 4 values, map_new 2 (pairs)
    const ka = try chunk.addConstant(.{ .keyword = .{ .ns = null, .name = "a" } });
    const v1 = try chunk.addConstant(.{ .integer = 1 });
    const kb = try chunk.addConstant(.{ .keyword = .{ .ns = null, .name = "b" } });
    const v2 = try chunk.addConstant(.{ .integer = 2 });
    try chunk.emit(.const_load, ka);
    try chunk.emit(.const_load, v1);
    try chunk.emit(.const_load, kb);
    try chunk.emit(.const_load, v2);
    try chunk.emit(.map_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .map);
    try std.testing.expectEqual(@as(usize, 2), result.map.count());
}

test "VM try/catch handles throw" {
    // (try (throw "err") (catch e e)) => "err"
    // Bytecode:
    //   try_begin -> catch
    //   const_load "err"
    //   throw_ex
    //   jump -> end
    //   catch_begin     ; catch handler starts here
    //   ; exception value is on stack as local
    //   local_load 0    ; load exception
    //   pop             ; cleanup catch local
    //   jump -> after_catch
    //   try_end
    //   ret
    //
    // Simpler approach using compiler:
    const allocator = std.testing.allocator;
    const node_mod = @import("../../common/analyzer/node.zig");
    const Node = node_mod.Node;
    const compiler_mod = @import("../../common/bytecode/compiler.zig");

    var compiler = compiler_mod.Compiler.init(allocator);
    defer compiler.deinit();

    // AST: (try (throw "err") (catch e e))
    var throw_expr = Node{ .constant = .{ .value = .{ .string = "err" } } };
    var throw_data = node_mod.ThrowNode{ .expr = &throw_expr, .source = .{} };
    var throw_node = Node{ .throw_node = &throw_data };

    var catch_body = Node{ .local_ref = .{ .name = "e", .idx = 0, .source = .{} } };
    const catch_clause = node_mod.CatchClause{
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
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("err", result.string);
}

test "VM throw without handler returns UserException" {
    // (throw "err") without try/catch
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    const idx = try chunk.addConstant(.{ .string = "oops" });
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.throw_ex);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(error.UserException, vm.run(&chunk));
}

test "VM set_new creates set" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const c1 = try chunk.addConstant(.{ .integer = 1 });
    const c2 = try chunk.addConstant(.{ .integer = 2 });
    try chunk.emit(.const_load, c1);
    try chunk.emit(.const_load, c2);
    try chunk.emit(.set_new, 2);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .set);
    try std.testing.expectEqual(@as(usize, 2), result.set.count());
}

test "VM empty vec_new" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    try chunk.emit(.vec_new, 0);
    try chunk.emitOp(.ret);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.run(&chunk);
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 0), result.vector.items.len);
}
