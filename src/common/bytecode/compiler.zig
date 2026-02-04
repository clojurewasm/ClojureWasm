//! Compiler: Node AST -> Bytecode.
//!
//! Transforms the Analyzer's AST (Node) into a sequence of bytecode instructions.
//! Each Node variant has a corresponding emit method.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Instruction = chunk_mod.Instruction;
const FnProto = chunk_mod.FnProto;
const Value = chunk_mod.Value;
const value_mod = @import("../value.zig");
const Fn = value_mod.Fn;
const node_mod = @import("../analyzer/node.zig");
const Node = node_mod.Node;

/// Compilation errors.
pub const CompileError = error{
    OutOfMemory,
    TooManyConstants,
    TooManyLocals,
    InvalidNode,
    Overflow,
    ArityError,
};

/// Local variable tracking.
const Local = struct {
    name: []const u8,
    depth: u32,
    slot: u16,
};

/// Bytecode compiler: transforms Node AST into instructions.
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    chunk: Chunk,
    locals: std.ArrayList(Local),
    scope_depth: u32,
    /// Tracks actual VM stack depth relative to frame base.
    /// Used by addLocal to assign correct stack slots.
    stack_depth: u16,
    loop_start: ?usize,
    loop_binding_count: u16,
    loop_locals_base: u16,
    /// Heap-allocated FnProtos and Fns (for cleanup).
    fn_protos: std.ArrayList(*const FnProto),
    fn_objects: std.ArrayList(*const Fn),

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .chunk = Chunk.init(allocator),
            .locals = .empty,
            .scope_depth = 0,
            .stack_depth = 0,
            .loop_start = null,
            .loop_binding_count = 0,
            .loop_locals_base = 0,
            .fn_protos = .empty,
            .fn_objects = .empty,
        };
    }

    pub fn deinit(self: *Compiler) void {
        for (self.fn_protos.items) |proto| {
            if (proto.capture_slots.len > 0) {
                self.allocator.free(proto.capture_slots);
            }
            self.allocator.free(proto.code);
            self.allocator.free(proto.constants);
            if (proto.lines.len > 0) {
                self.allocator.free(proto.lines);
            }
            if (proto.columns.len > 0) {
                self.allocator.free(proto.columns);
            }
            self.allocator.destroy(@constCast(proto));
        }
        self.fn_protos.deinit(self.allocator);
        for (self.fn_objects.items) |fn_obj| {
            self.allocator.destroy(@constCast(fn_obj));
        }
        self.fn_objects.deinit(self.allocator);
        self.chunk.deinit();
        self.locals.deinit(self.allocator);
    }

    /// Detach fn allocations from this compiler so deinit() won't free them.
    /// Caller takes ownership and is responsible for freeing the returned items.
    pub fn detachFnAllocations(self: *Compiler) struct {
        fn_protos: []const *const FnProto,
        fn_objects: []const *const Fn,
    } {
        const protos = self.fn_protos.toOwnedSlice(self.allocator) catch &.{};
        const objects = self.fn_objects.toOwnedSlice(self.allocator) catch &.{};
        return .{ .fn_protos = protos, .fn_objects = objects };
    }

    /// Compile a single Node to bytecode.
    pub fn compile(self: *Compiler, n: *const Node) CompileError!void {
        // Track source location for debug info
        const src = n.source();
        if (src.line > 0) {
            self.chunk.current_line = src.line;
            self.chunk.current_column = src.column;
        }

        switch (n.*) {
            .constant => |c| try self.emitConstant(c.value),
            .local_ref => |ref| try self.emitLocalRef(ref),
            .if_node => |node| try self.emitIf(node),
            .do_node => |node| try self.emitDo(node),
            .let_node => |node| try self.emitLet(node),
            .loop_node => |node| try self.emitLoop(node),
            .recur_node => |node| try self.emitRecur(node),
            .fn_node => |node| try self.emitFn(node),
            .call_node => |node| try self.emitCall(node),
            .def_node => |node| try self.emitDef(node),
            .set_node => |node| try self.emitSetBang(node),
            .quote_node => |node| try self.emitQuote(node),
            .throw_node => |node| try self.emitThrow(node),
            .try_node => |node| try self.emitTry(node),
            .var_ref => |ref| try self.emitVarRef(ref),
            .defmulti_node => |node| try self.emitDefmulti(node),
            .defmethod_node => |node| try self.emitDefmethod(node),
            .lazy_seq_node => |node| try self.emitLazySeq(node),
            // Protocol nodes not yet supported in VM compiler
            .defprotocol_node, .extend_type_node => return error.InvalidNode,
        }
    }

    // --- Emit methods ---

    fn emitConstant(self: *Compiler, val: Value) CompileError!void {
        switch (val) {
            .nil => try self.chunk.emitOp(.nil),
            .boolean => |b| {
                if (b) {
                    try self.chunk.emitOp(.true_val);
                } else {
                    try self.chunk.emitOp(.false_val);
                }
            },
            else => {
                const idx = self.chunk.addConstant(val) catch return error.TooManyConstants;
                try self.chunk.emit(.const_load, idx);
            },
        }
        self.stack_depth += 1;
    }

    fn emitLocalRef(self: *Compiler, ref: node_mod.LocalRefNode) CompileError!void {
        // Find the local by index to get the actual stack slot
        if (ref.idx < self.locals.items.len) {
            try self.chunk.emit(.local_load, self.locals.items[ref.idx].slot);
        } else {
            try self.chunk.emit(.local_load, @intCast(ref.idx));
        }
        self.stack_depth += 1;
    }

    fn emitIf(self: *Compiler, node: *const node_mod.IfNode) CompileError!void {
        // Compile test expression (+1)
        try self.compile(node.test_node);

        // Jump over then-branch if false (pops test: -1)
        const jump_if_false = self.chunk.emitJump(.jump_if_false) catch return error.OutOfMemory;
        self.stack_depth -= 1;

        // Save depth before branches (both must produce same net effect)
        const branch_base = self.stack_depth;

        // Compile then-branch (+1)
        try self.compile(node.then_node);

        // Jump over else-branch
        const jump_over_else = self.chunk.emitJump(.jump) catch return error.OutOfMemory;

        // Reset depth for else branch (then result not on stack in else path)
        self.stack_depth = branch_base;

        // Patch false jump to else-branch
        self.chunk.patchJump(jump_if_false);

        // Compile else-branch (or nil if absent) (+1)
        if (node.else_node) |else_n| {
            try self.compile(else_n);
        } else {
            try self.chunk.emitOp(.nil);
            self.stack_depth += 1;
        }

        // Patch jump over else
        self.chunk.patchJump(jump_over_else);
        // Normalize depth: if one branch has recur/throw (non-local exit),
        // its depth may be lower. The join point always has branch_base + 1.
        self.stack_depth = branch_base + 1;
    }

    fn emitDo(self: *Compiler, node: *const node_mod.DoNode) CompileError!void {
        if (node.statements.len == 0) {
            try self.chunk.emitOp(.nil);
            self.stack_depth += 1;
            return;
        }

        for (node.statements, 0..) |stmt, i| {
            try self.compile(stmt); // +1
            // Pop intermediate results, keep the last
            if (i < node.statements.len - 1) {
                try self.chunk.emitOp(.pop);
                self.stack_depth -= 1;
            }
        }
    }

    fn emitLet(self: *Compiler, node: *const node_mod.LetNode) CompileError!void {
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;

        // Compile bindings: each compile pushes a value, addLocal names it
        for (node.bindings) |binding| {
            try self.compile(binding.init); // +1
            try self.addLocal(binding.name); // slot = stack_depth - 1
        }

        // Compile body (+1)
        try self.compile(node.body);

        // Clean up: keep body result, remove binding slots below it
        const locals_to_pop = self.locals.items.len - base_locals;
        if (locals_to_pop > 0) {
            try self.chunk.emit(.pop_under, @intCast(locals_to_pop));
            self.stack_depth -= @intCast(locals_to_pop);
        }

        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    fn emitLoop(self: *Compiler, node: *const node_mod.LoopNode) CompileError!void {
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;

        // Record actual stack depth before bindings (for recur base_offset)
        const loop_locals_base: u16 = self.stack_depth;

        // Compile initial bindings
        for (node.bindings) |binding| {
            try self.compile(binding.init); // +1
            try self.addLocal(binding.name); // slot = stack_depth - 1
        }

        // Save loop context
        const prev_loop_start = self.loop_start;
        const prev_binding_count = self.loop_binding_count;
        const prev_loop_locals_base = self.loop_locals_base;
        self.loop_start = self.chunk.currentOffset();
        self.loop_binding_count = @intCast(node.bindings.len);
        self.loop_locals_base = loop_locals_base;

        // Compile body (+1)
        try self.compile(node.body);

        // Restore loop context
        self.loop_start = prev_loop_start;
        self.loop_binding_count = prev_binding_count;
        self.loop_locals_base = prev_loop_locals_base;

        // Clean up locals: keep body result on top, remove bindings beneath
        const locals_to_pop = self.locals.items.len - base_locals;
        if (locals_to_pop > 0) {
            try self.chunk.emit(.pop_under, @intCast(locals_to_pop));
            self.stack_depth -= @intCast(locals_to_pop);
        }

        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    fn emitRecur(self: *Compiler, node: *const node_mod.RecurNode) CompileError!void {
        // Compile new values for loop bindings
        for (node.args) |arg| {
            try self.compile(arg); // +1 each
        }

        // Emit recur: operand = (base_offset << 8) | arg_count
        const arg_count: u16 = @intCast(node.args.len);
        const operand = (self.loop_locals_base << 8) | arg_count;
        try self.chunk.emit(.recur, operand);

        // recur consumes args and resets stack to loop bindings
        self.stack_depth -= arg_count;

        // Jump back to loop start
        if (self.loop_start) |ls| {
            try self.chunk.emitLoop(ls);
        }
    }

    fn emitFn(self: *Compiler, node: *const node_mod.FnNode) CompileError!void {
        if (node.arities.len == 0) return error.InvalidNode;

        const has_self_ref = node.name != null;
        const capture_count: u16 = @intCast(self.locals.items.len);

        // Build capture_slots: parent stack slot for each captured variable.
        // Locals may be at non-contiguous stack positions (e.g., when a closure
        // is defined inside a call argument where the callee is already on stack).
        const capture_slots: []u16 = if (capture_count > 0) blk: {
            const slots = self.allocator.alloc(u16, capture_count) catch return error.OutOfMemory;
            for (self.locals.items, 0..) |local, i| {
                slots[i] = local.slot;
            }
            break :blk slots;
        } else &.{};

        // Compile the primary arity (first one)
        const primary_proto = try self.compileArity(node, node.arities[0], capture_count, has_self_ref);
        primary_proto.capture_slots = capture_slots;

        // Compile additional arities (if multi-arity)
        var extra_arities: ?[]const *const anyopaque = null;
        if (node.arities.len > 1) {
            const extras = self.allocator.alloc(*const anyopaque, node.arities.len - 1) catch
                return error.OutOfMemory;
            for (node.arities[1..], 0..) |arity, i| {
                const extra_proto = try self.compileArity(node, arity, capture_count, has_self_ref);
                extra_proto.capture_slots = capture_slots;
                extras[i] = @ptrCast(extra_proto);
            }
            extra_arities = extras;
        }

        // Create Fn template and store as constant
        const fn_obj = self.allocator.create(Fn) catch return error.OutOfMemory;
        fn_obj.* = .{ .proto = primary_proto, .closure_bindings = null, .extra_arities = extra_arities };
        self.fn_objects.append(self.allocator, fn_obj) catch return error.OutOfMemory;

        const idx = self.chunk.addConstant(.{ .fn_val = fn_obj }) catch
            return error.TooManyConstants;

        // Closure operand: just the constant index (capture info is in FnProto).
        try self.chunk.emit(.closure, idx);
        self.stack_depth += 1; // closure pushes fn_val
    }

    fn compileArity(
        self: *Compiler,
        node: *const node_mod.FnNode,
        arity: node_mod.FnArity,
        capture_count: u16,
        has_self_ref: bool,
    ) CompileError!*FnProto {
        var fn_compiler = Compiler.init(self.allocator);
        defer fn_compiler.deinit();

        // Reserve slots for captured variables (they appear before params).
        // The VM places these on the stack before fn body runs,
        // so increment stack_depth for each.
        for (self.locals.items) |local| {
            fn_compiler.stack_depth += 1;
            try fn_compiler.addLocal(local.name);
        }

        // Named fn: reserve self-reference slot (matches Analyzer's local layout)
        if (has_self_ref) {
            fn_compiler.stack_depth += 1;
            try fn_compiler.addLocal(node.name.?);
        }

        // Add parameters as locals
        const params_base = fn_compiler.stack_depth;
        for (arity.params) |param| {
            fn_compiler.stack_depth += 1;
            try fn_compiler.addLocal(param);
        }

        // Enable fn-level recur: set loop context so recur in fn body
        // jumps back to body start and rebinds params.
        fn_compiler.loop_start = fn_compiler.chunk.currentOffset();
        fn_compiler.loop_locals_base = params_base;
        fn_compiler.loop_binding_count = @intCast(arity.params.len);

        // Compile body
        try fn_compiler.compile(arity.body);
        try fn_compiler.chunk.emitOp(.ret);

        // Transfer nested fn allocations to parent compiler before deinit frees them.
        // The constants table may contain .fn_val pointers to these objects.
        const nested = fn_compiler.detachFnAllocations();
        for (nested.fn_protos) |p| {
            self.fn_protos.append(self.allocator, p) catch return error.OutOfMemory;
        }
        if (nested.fn_protos.len > 0) self.allocator.free(nested.fn_protos);
        for (nested.fn_objects) |o| {
            self.fn_objects.append(self.allocator, o) catch return error.OutOfMemory;
        }
        if (nested.fn_objects.len > 0) self.allocator.free(nested.fn_objects);

        // Allocate owned copies of code, constants, and lines
        const code_copy = self.allocator.dupe(Instruction, fn_compiler.chunk.code.items) catch
            return error.OutOfMemory;
        const const_copy = self.allocator.dupe(Value, fn_compiler.chunk.constants.items) catch
            return error.OutOfMemory;
        const lines_copy = self.allocator.dupe(u32, fn_compiler.chunk.lines.items) catch
            return error.OutOfMemory;
        const columns_copy = self.allocator.dupe(u32, fn_compiler.chunk.columns.items) catch
            return error.OutOfMemory;

        const proto = self.allocator.create(FnProto) catch return error.OutOfMemory;
        proto.* = .{
            .name = node.name,
            .arity = @intCast(arity.params.len),
            .variadic = arity.variadic,
            .local_count = @intCast(fn_compiler.locals.items.len),
            .capture_count = capture_count,
            .has_self_ref = has_self_ref,
            .code = code_copy,
            .constants = const_copy,
            .lines = lines_copy,
            .columns = columns_copy,
        };

        self.fn_protos.append(self.allocator, proto) catch return error.OutOfMemory;
        return proto;
    }

    fn emitCall(self: *Compiler, node: *const node_mod.CallNode) CompileError!void {
        if (node.callee.* == .var_ref) {
            const name = node.callee.var_ref.name;

            // Variadic arithmetic: +, -, *, /
            if (variadicArithOp(name)) |op| {
                try self.emitVariadicArith(op, name, node.args);
                return;
            }

            // 2-arg intrinsics: mod, rem, comparison ops
            if (node.args.len == 2) {
                if (binaryOnlyIntrinsic(name)) |op| {
                    try self.compile(node.args[0]); // +1
                    try self.compile(node.args[1]); // +1
                    try self.chunk.emitOp(op);
                    self.stack_depth -= 1; // binary op: 2 → 1
                    return;
                }
            }
        }

        // General call: compile callee + args
        try self.compile(node.callee); // +1
        for (node.args) |arg| {
            try self.compile(arg); // +1 each
        }
        try self.chunk.emit(.call, @intCast(node.args.len));
        // call pops callee + N args, pushes 1 result: net -(N+1)+1 = -N
        self.stack_depth -= @intCast(node.args.len);
    }

    /// Emit variadic arithmetic (+, -, *, /) as sequences of binary opcodes.
    fn emitVariadicArith(self: *Compiler, op: chunk_mod.OpCode, name: []const u8, args: []const *Node) CompileError!void {
        const is_add = std.mem.eql(u8, name, "+");
        const is_mul = std.mem.eql(u8, name, "*");
        const is_sub = std.mem.eql(u8, name, "-");

        switch (args.len) {
            0 => {
                // (+) => 0, (*) => 1, (-) and (/) are arity errors
                if (is_add) {
                    const idx = self.chunk.addConstant(.{ .integer = 0 }) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                } else if (is_mul) {
                    const idx = self.chunk.addConstant(.{ .integer = 1 }) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                } else {
                    return error.ArityError;
                }
            },
            1 => {
                if (is_sub) {
                    // (- x) => (0 - x)
                    const idx = self.chunk.addConstant(.{ .integer = 0 }) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                    try self.compile(args[0]); // +1
                    try self.chunk.emitOp(.sub);
                    self.stack_depth -= 1; // binary: 2 → 1
                } else if (std.mem.eql(u8, name, "/")) {
                    // (/ x) => (1.0 / x)
                    const idx = self.chunk.addConstant(.{ .float = 1.0 }) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                    try self.compile(args[0]); // +1
                    try self.chunk.emitOp(.div);
                    self.stack_depth -= 1; // binary: 2 → 1
                } else {
                    // (+ x) => x, (* x) => x
                    try self.compile(args[0]); // +1
                }
            },
            else => {
                // 2+ args: compile first two, emit op, then fold remaining
                try self.compile(args[0]); // +1
                try self.compile(args[1]); // +1
                try self.chunk.emitOp(op);
                self.stack_depth -= 1; // binary: 2 → 1
                for (args[2..]) |arg| {
                    try self.compile(arg); // +1
                    try self.chunk.emitOp(op);
                    self.stack_depth -= 1; // binary: 2 → 1
                }
            },
        }
    }

    /// Map variadic arithmetic names to their binary opcodes.
    fn variadicArithOp(name: []const u8) ?chunk_mod.OpCode {
        const map = .{
            .{ "+", .add },
            .{ "-", .sub },
            .{ "*", .mul },
            .{ "/", .div },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    /// Map binary-only intrinsic names (mod, rem, comparisons) to opcodes.
    fn binaryOnlyIntrinsic(name: []const u8) ?chunk_mod.OpCode {
        const map = .{
            .{ "mod", .mod },
            .{ "rem", .rem_ },
            .{ "<", .lt },
            .{ "<=", .le },
            .{ ">", .gt },
            .{ ">=", .ge },
            .{ "=", .eq },
            .{ "not=", .neq },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    fn emitDef(self: *Compiler, node: *const node_mod.DefNode) CompileError!void {
        // Push symbol name as constant
        const sym_val = Value{ .symbol = .{ .ns = null, .name = node.sym_name } };
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;

        // Compile init expression if present
        if (node.init) |init_node| {
            try self.compile(init_node); // +1
        } else {
            try self.chunk.emitOp(.nil);
            self.stack_depth += 1;
        }

        // Emit def: pops value, pushes symbol (net 0)
        // Use def_macro/def_dynamic opcode to preserve flags at runtime
        const op: OpCode = if (node.is_macro) .def_macro else if (node.is_dynamic) .def_dynamic else .def;
        try self.chunk.emit(op, idx);
    }

    fn emitSetBang(self: *Compiler, node: *const node_mod.SetNode) CompileError!void {
        // (set! var-sym expr) — mutate thread-local binding
        const sym_val = Value{ .symbol = .{ .ns = null, .name = node.var_name } };
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;
        // Compile expression (pushes value)
        try self.compile(node.expr); // +1
        // set_bang: reads top of stack, sets binding, keeps value on stack (net 0 change: value stays)
        try self.chunk.emit(.set_bang, idx);
    }

    fn emitDefmulti(self: *Compiler, node: *const node_mod.DefMultiNode) CompileError!void {
        // Push name as constant
        const sym_val = Value{ .symbol = .{ .ns = null, .name = node.name } };
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;

        // Compile dispatch function
        try self.compile(node.dispatch_fn); // +1

        // defmulti: pops dispatch_fn, creates MultiFn, binds to var, pushes result (net 0)
        try self.chunk.emit(.defmulti, idx);
    }

    fn emitDefmethod(self: *Compiler, node: *const node_mod.DefMethodNode) CompileError!void {
        // Push multimethod name as constant
        const sym_val = Value{ .symbol = .{ .ns = null, .name = node.multi_name } };
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;

        // Compile dispatch value
        try self.compile(node.dispatch_val); // +1

        // Compile method fn (FnNode, not a full Node)
        try self.emitFn(node.fn_node); // +1

        // defmethod: pops method_fn and dispatch_val, adds to multimethod, pushes result (net -1)
        try self.chunk.emit(.defmethod, idx);
        self.stack_depth -= 1;
    }

    fn emitLazySeq(self: *Compiler, node: *const node_mod.LazySeqNode) CompileError!void {
        // Compile body as a zero-arg closure (thunk)
        try self.emitFn(node.body_fn); // +1 (pushes fn_val)

        // lazy_seq: replaces fn_val with LazySeq (net 0)
        try self.chunk.emitOp(.lazy_seq);
    }

    fn emitQuote(self: *Compiler, node: *const node_mod.QuoteNode) CompileError!void {
        const idx = self.chunk.addConstant(node.value) catch return error.TooManyConstants;
        try self.chunk.emit(.const_load, idx);
        self.stack_depth += 1;
    }

    fn emitThrow(self: *Compiler, node: *const node_mod.ThrowNode) CompileError!void {
        try self.compile(node.expr); // +1
        try self.chunk.emitOp(.throw_ex);
        self.stack_depth -= 1; // throw pops (control transfers)
    }

    fn emitTry(self: *Compiler, node: *const node_mod.TryNode) CompileError!void {
        // Emit try_begin with placeholder offset to catch
        const try_begin_offset = self.chunk.emitJump(.try_begin) catch return error.OutOfMemory;

        const depth_before_body = self.stack_depth;

        // Compile body (may contain throw which disrupts depth tracking)
        try self.compile(node.body);

        // Normalize: body produces exactly 1 value on normal path
        const body_depth = depth_before_body + 1;
        self.stack_depth = body_depth;

        // Normal flow: pop exception handler before skipping catch
        try self.chunk.emitOp(.pop_handler);

        // Jump over catch to try_end
        const jump_to_end = self.chunk.emitJump(.jump) catch return error.OutOfMemory;

        // Patch try_begin to point to catch
        self.chunk.patchJump(try_begin_offset);

        // Compile catch clause if present
        if (node.catch_clause) |catch_clause| {
            // In catch path, body result is not on stack. VM's throw handler
            // restores sp to saved_sp and pushes exception value.
            self.stack_depth = depth_before_body;
            try self.chunk.emitOp(.catch_begin);

            // Exception value is pushed by VM throw handler
            self.stack_depth += 1;

            // Add catch binding as local
            self.scope_depth += 1;
            const base = self.locals.items.len;
            try self.addLocal(catch_clause.binding_name); // slot = stack_depth - 1

            try self.compile(catch_clause.body); // +1

            // Clean up catch local: keep body result, remove binding below it
            const locals_to_pop = self.locals.items.len - base;
            if (locals_to_pop > 0) {
                try self.chunk.emit(.pop_under, @intCast(locals_to_pop));
                self.stack_depth -= @intCast(locals_to_pop);
            }
            self.locals.shrinkRetainingCapacity(base);
            self.scope_depth -= 1;
        } else if (node.finally_body != null) {
            // No catch but has finally: synthetic handler that runs finally then re-throws.
            // throw already consumed the handler, so NO catch_begin here.
            // throw handler pushes exception value; run finally, then throw_ex to re-propagate.
            self.stack_depth = depth_before_body;
            self.stack_depth += 1; // exception on stack (pushed by throw handler)

            // Run finally on exception path
            try self.compile(node.finally_body.?); // +1
            try self.chunk.emitOp(.pop); // discard finally result
            self.stack_depth -= 1;

            // Re-throw: exception value is still on stack
            try self.chunk.emitOp(.throw_ex);
            self.stack_depth -= 1;
        }

        // Both paths converge at body_depth
        self.stack_depth = body_depth;

        // Patch jump to end
        self.chunk.patchJump(jump_to_end);

        // Compile finally for normal path
        if (node.finally_body) |finally_body| {
            try self.compile(finally_body); // +1
            try self.chunk.emitOp(.pop); // finally result is discarded
            self.stack_depth -= 1;
        }

        try self.chunk.emitOp(.try_end);
    }

    fn emitVarRef(self: *Compiler, ref: node_mod.VarRefNode) CompileError!void {
        // Store the var reference symbol as a constant
        const sym_val = Value{ .symbol = .{ .ns = ref.ns, .name = ref.name } };
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;
        try self.chunk.emit(.var_load, idx);
        self.stack_depth += 1;
    }

    // --- Helpers ---

    /// Register a named local at the current stack position.
    /// The value must already be on the stack (stack_depth already incremented
    /// by the preceding compile/emit that pushed the value).
    fn addLocal(self: *Compiler, name: []const u8) CompileError!void {
        // slot = stack_depth - 1 because the value is already pushed
        const slot: u16 = self.stack_depth - 1;
        self.locals.append(self.allocator, .{
            .name = name,
            .depth = self.scope_depth,
            .slot = slot,
        }) catch return error.OutOfMemory;
    }
};

// === Tests ===

test "compile constant nil" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const node = Node{ .constant = .{ .value = .nil } };
    try compiler.compile(&node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.nil, compiler.chunk.code.items[0].op);
}

test "compile constant true/false" {
    const allocator = std.testing.allocator;

    {
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        const node = Node{ .constant = .{ .value = .{ .boolean = true } } };
        try compiler.compile(&node);
        try std.testing.expectEqual(OpCode.true_val, compiler.chunk.code.items[0].op);
    }

    {
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        const node = Node{ .constant = .{ .value = .{ .boolean = false } } };
        try compiler.compile(&node);
        try std.testing.expectEqual(OpCode.false_val, compiler.chunk.code.items[0].op);
    }
}

test "compile constant integer" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const node = Node{ .constant = .{ .value = .{ .integer = 42 } } };
    try compiler.compile(&node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, compiler.chunk.code.items[0].op);
    try std.testing.expectEqual(@as(u16, 0), compiler.chunk.code.items[0].operand);
    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.constants.items.len);
}

test "compile if_node" {
    // (if true 1 2) -> true_val, jump_if_false, const_load(1), jump, const_load(2)
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var test_n = Node{ .constant = .{ .value = .{ .boolean = true } } };
    var then_n = Node{ .constant = .{ .value = .{ .integer = 1 } } };
    var else_n = Node{ .constant = .{ .value = .{ .integer = 2 } } };

    var if_data = node_mod.IfNode{
        .test_node = &test_n,
        .then_node = &then_n,
        .else_node = &else_n,
        .source = .{},
    };
    const node = Node{ .if_node = &if_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.true_val, code[0].op);
    try std.testing.expectEqual(OpCode.jump_if_false, code[1].op);
    try std.testing.expectEqual(OpCode.const_load, code[2].op);
    try std.testing.expectEqual(OpCode.jump, code[3].op);
    try std.testing.expectEqual(OpCode.const_load, code[4].op);
    try std.testing.expectEqual(@as(usize, 5), code.len);
}

test "compile if_node without else" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var test_n = Node{ .constant = .{ .value = .{ .boolean = true } } };
    var then_n = Node{ .constant = .{ .value = .{ .integer = 1 } } };

    var if_data = node_mod.IfNode{
        .test_node = &test_n,
        .then_node = &then_n,
        .else_node = null,
        .source = .{},
    };
    const node = Node{ .if_node = &if_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.true_val, code[0].op);
    try std.testing.expectEqual(OpCode.jump_if_false, code[1].op);
    try std.testing.expectEqual(OpCode.const_load, code[2].op);
    try std.testing.expectEqual(OpCode.jump, code[3].op);
    try std.testing.expectEqual(OpCode.nil, code[4].op);
}

test "compile do_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var stmt1 = Node{ .constant = .{ .value = .{ .integer = 1 } } };
    var stmt2 = Node{ .constant = .{ .value = .{ .integer = 2 } } };
    var stmts = [_]*Node{ &stmt1, &stmt2 };

    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const node = Node{ .do_node = &do_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.const_load, code[0].op);
    try std.testing.expectEqual(OpCode.pop, code[1].op);
    try std.testing.expectEqual(OpCode.const_load, code[2].op);
    try std.testing.expectEqual(@as(usize, 3), code.len);
}

test "compile empty do_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var stmts = [_]*Node{};
    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .source = .{},
    };
    const node = Node{ .do_node = &do_data };
    try compiler.compile(&node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.nil, compiler.chunk.code.items[0].op);
}

test "compile call_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var callee = Node{ .var_ref = .{ .ns = null, .name = "f", .source = .{} } };
    var arg1 = Node{ .constant = .{ .value = .{ .integer = 1 } } };
    var arg2 = Node{ .constant = .{ .value = .{ .integer = 2 } } };
    var args = [_]*Node{ &arg1, &arg2 };

    var call_data = node_mod.CallNode{
        .callee = &callee,
        .args = &args,
        .source = .{},
    };
    const node = Node{ .call_node = &call_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.var_load, code[0].op);
    try std.testing.expectEqual(OpCode.const_load, code[1].op);
    try std.testing.expectEqual(OpCode.const_load, code[2].op);
    try std.testing.expectEqual(OpCode.call, code[3].op);
    try std.testing.expectEqual(@as(u16, 2), code[3].operand);
}

test "compile def_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var init_expr = Node{ .constant = .{ .value = .{ .integer = 42 } } };
    var def_data = node_mod.DefNode{
        .sym_name = "x",
        .init = &init_expr,
        .is_macro = false,
        .is_dynamic = false,
        .is_private = false,
        .is_const = false,
        .doc = null,
        .source = .{},
    };
    const node = Node{ .def_node = &def_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.const_load, code[0].op);
    try std.testing.expectEqual(OpCode.def, code[1].op);
}

test "compile quote_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var quote_data = node_mod.QuoteNode{
        .value = .{ .integer = 99 },
        .source = .{},
    };
    const node = Node{ .quote_node = &quote_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.const_load, code[0].op);
    try std.testing.expectEqual(@as(usize, 1), code.len);
}

test "compile throw_node" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var expr = Node{ .constant = .{ .value = .{ .string = "error!" } } };
    var throw_data = node_mod.ThrowNode{
        .expr = &expr,
        .source = .{},
    };
    const node = Node{ .throw_node = &throw_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.const_load, code[0].op);
    try std.testing.expectEqual(OpCode.throw_ex, code[1].op);
}

test "compile let_node" {
    // (let [x 1] x) -> const_load(1), local_load(0), pop_under(1)
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var init_val = Node{ .constant = .{ .value = .{ .integer = 1 } } };
    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_val },
    };
    var body = Node{ .local_ref = .{ .name = "x", .idx = 0, .source = .{} } };

    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &body,
        .source = .{},
    };
    const node = Node{ .let_node = &let_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    // const_load(1) -> local_load(0) -> pop_under(1) (keep result, remove binding)
    try std.testing.expectEqual(OpCode.const_load, code[0].op); // init x=1
    try std.testing.expectEqual(OpCode.local_load, code[1].op); // body: ref x
    try std.testing.expectEqual(@as(u16, 0), code[1].operand); // slot 0
    try std.testing.expectEqual(OpCode.pop_under, code[2].op); // cleanup
    try std.testing.expectEqual(@as(u16, 1), code[2].operand); // 1 binding
}

test "compile fn_node emits closure" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    // (fn [x] x)
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
    const node = Node{ .fn_node = &fn_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    // Should emit: closure <idx>
    try std.testing.expectEqual(OpCode.closure, code[0].op);
    try std.testing.expectEqual(@as(usize, 1), code.len);

    // The constant should be a fn_val
    const fn_const = compiler.chunk.constants.items[code[0].operand];
    try std.testing.expect(fn_const == .fn_val);
}

test "compile var_ref" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const node = Node{ .var_ref = .{ .ns = "clojure.core", .name = "+", .source = .{} } };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.var_load, code[0].op);
    try std.testing.expectEqual(@as(usize, 1), code.len);
    // Constant pool should have the symbol
    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.constants.items.len);
}
