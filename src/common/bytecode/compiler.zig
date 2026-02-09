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
    /// Namespace name at compile time. Used to fully-qualify unqualified var
    /// references so that functions resolve vars in their defining namespace
    /// rather than the caller's namespace at runtime (D68).
    current_ns_name: ?[]const u8,

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
            .current_ns_name = null,
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
            .letfn_node => |node| try self.emitLetfn(node),
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
            .defprotocol_node => |node| try self.emitDefprotocol(node),
            .extend_type_node => |node| try self.emitExtendType(node),
        }
    }

    // --- Emit methods ---

    fn emitConstant(self: *Compiler, val: Value) CompileError!void {
        switch (val.tag()) {
            .nil => try self.chunk.emitOp(.nil),
            .boolean => {
                if (val.asBoolean()) {
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

    fn emitLetfn(self: *Compiler, node: *const node_mod.LetfnNode) CompileError!void {
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;
        const base_stack = self.stack_depth;

        // Phase 1: Push nil for each binding slot and register locals
        for (node.bindings) |binding| {
            try self.chunk.emit(.nil, 0);
            self.stack_depth += 1;
            try self.addLocal(binding.name);
        }

        // Phase 2: Compile each fn expression, store back to its slot
        for (node.bindings, 0..) |binding, i| {
            try self.compile(binding.init); // +1 (closure)
            try self.chunk.emit(.local_store, base_stack + @as(u16, @intCast(i))); // -1
            self.stack_depth -= 1;
        }

        // Phase 3: Patch closure bindings for mutual references
        const count: u16 = @intCast(node.bindings.len);
        try self.chunk.emit(.letfn_patch, (count << 8) | base_stack);

        // Phase 4: Compile body
        try self.compile(node.body); // +1

        // Cleanup: keep body result, remove binding slots below it
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
        fn_obj.* = .{
            .proto = primary_proto,
            .closure_bindings = null,
            .extra_arities = extra_arities,
            .defining_ns = self.current_ns_name,
        };
        self.fn_objects.append(self.allocator, fn_obj) catch return error.OutOfMemory;

        const idx = self.chunk.addConstant(Value.initFn(fn_obj)) catch
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
        fn_compiler.current_ns_name = self.current_ns_name;

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

        // Peephole optimization (37.2): fuse common instruction sequences
        const optimized = peepholeOptimize(self.allocator, code_copy, lines_copy, columns_copy);

        const proto = self.allocator.create(FnProto) catch return error.OutOfMemory;
        proto.* = .{
            .name = node.name,
            .arity = @intCast(arity.params.len),
            .variadic = arity.variadic,
            .local_count = @intCast(fn_compiler.locals.items.len),
            .capture_count = capture_count,
            .has_self_ref = has_self_ref,
            .code = optimized.code,
            .constants = const_copy,
            .lines = optimized.lines,
            .columns = optimized.columns,
        };

        self.fn_protos.append(self.allocator, proto) catch return error.OutOfMemory;
        return proto;
    }

    /// Emit a function call, with intrinsic detection for known builtins.
    ///
    /// When the callee is a var_ref to a recognized core function, the compiler
    /// emits direct opcodes instead of the general var_load + call sequence.
    /// This eliminates namespace lookup and call frame setup at runtime:
    ///
    ///   General call:  var_load → push args → call → frame setup → dispatch
    ///   Intrinsic:     push args → binary_op  (saves ~5 opcode dispatches)
    ///
    /// Three categories of intrinsics are recognized:
    ///   1. Variadic arithmetic (+, -, *, /) — left-folded binary ops (Phase 3)
    ///   2. Binary-only intrinsics (mod, rem, <, <=, >, >=, =, not=) (Phase 3)
    ///   3. Collection constructors (hash-map, vector, hash-set, list) (24C.10)
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

            // Collection constructor intrinsics: hash-map, vector, hash-set, list
            // Emit direct opcodes instead of var_load + call to avoid namespace lookup overhead
            if (collectionConstructorOp(name)) |info| {
                const n_args = node.args.len;
                for (node.args) |arg| {
                    try self.compile(arg); // +1 each
                }
                const operand: u16 = if (info.is_map)
                    @intCast(n_args / 2) // map_new operand = pair count
                else
                    @intCast(n_args);
                try self.chunk.emit(info.op, operand);
                // All collection ops: pop elements, push 1 result
                // map_new(N) pops 2N push 1; vec/list/set_new(N) pop N push 1
                if (n_args > 0) {
                    self.stack_depth -= @as(u16, @intCast(n_args)) - 1;
                } else {
                    self.stack_depth += 1; // empty collection: push 1
                }
                return;
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
    /// Handles Clojure's special cases: (+) => 0, (*) => 1, (- x) => (0-x),
    /// (/ x) => (1.0/x), and 2+ args are left-folded: (+ a b c) => ((a+b)+c).
    fn emitVariadicArith(self: *Compiler, op: chunk_mod.OpCode, name: []const u8, args: []const *Node) CompileError!void {
        const is_add = std.mem.eql(u8, name, "+") or std.mem.eql(u8, name, "+'");
        const is_mul = std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "*'");
        const is_sub = std.mem.eql(u8, name, "-") or std.mem.eql(u8, name, "-'");

        switch (args.len) {
            0 => {
                // (+) => 0, (*) => 1, (-) and (/) are arity errors
                if (is_add) {
                    const idx = self.chunk.addConstant(Value.initInteger(0)) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                } else if (is_mul) {
                    const idx = self.chunk.addConstant(Value.initInteger(1)) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                } else {
                    return error.ArityError;
                }
            },
            1 => {
                if (is_sub) {
                    // (- x) => (0 - x), (-' x) => (0 -' x)
                    const idx = self.chunk.addConstant(Value.initInteger(0)) catch return error.TooManyConstants;
                    try self.chunk.emit(.const_load, idx);
                    self.stack_depth += 1;
                    try self.compile(args[0]); // +1
                    try self.chunk.emitOp(op);
                    self.stack_depth -= 1; // binary: 2 → 1
                } else if (std.mem.eql(u8, name, "/")) {
                    // (/ x) => (1.0 / x)
                    const idx = self.chunk.addConstant(Value.initFloat(1.0)) catch return error.TooManyConstants;
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
            .{ "+'", .add_p },
            .{ "-'", .sub_p },
            .{ "*'", .mul_p },
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

    const CollectionOpInfo = struct {
        op: chunk_mod.OpCode,
        /// Maps take pairs (k1,v1,k2,v2...) so operand = n_args/2.
        is_map: bool,
    };

    /// Detect calls to collection constructor functions and map to direct opcodes.
    /// (24C.10) — gc_stress creates 100K maps via (hash-map :a i :b ...); emitting
    /// map_new directly saves a var_load + call frame per construction.
    fn collectionConstructorOp(name: []const u8) ?CollectionOpInfo {
        const map = .{
            .{ "hash-map", chunk_mod.OpCode.map_new, true },
            .{ "vector", chunk_mod.OpCode.vec_new, false },
            .{ "hash-set", chunk_mod.OpCode.set_new, false },
            .{ "list", chunk_mod.OpCode.list_new, false },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return .{ .op = entry[1], .is_map = entry[2] };
        }
        return null;
    }

    fn emitDef(self: *Compiler, node: *const node_mod.DefNode) CompileError!void {
        // Push symbol name as constant, followed by metadata constants.
        // Layout: constants[idx] = symbol, [idx+1] = line, [idx+2] = file,
        //         [idx+3] = doc, [idx+4] = arglists
        const sym_val = Value.initSymbol(self.allocator, .{ .ns = null, .name = node.sym_name });
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;
        _ = self.chunk.addConstant(Value.initInteger(@intCast(node.source.line))) catch return error.TooManyConstants;
        const file_val = if (node.source.file) |f|
            Value.initString(self.allocator, f)
        else
            Value.nil_val;
        _ = self.chunk.addConstant(file_val) catch return error.TooManyConstants;
        const doc_val = if (node.doc) |d| Value.initString(self.allocator, d) else Value.nil_val;
        _ = self.chunk.addConstant(doc_val) catch return error.TooManyConstants;
        const arglists_val = if (node.arglists) |a| Value.initString(self.allocator, a) else Value.nil_val;
        _ = self.chunk.addConstant(arglists_val) catch return error.TooManyConstants;

        // Compile init expression if present
        if (node.init) |init_node| {
            try self.compile(init_node); // +1
        } else {
            try self.chunk.emitOp(.nil);
            self.stack_depth += 1;
        }

        // Emit def: pops value, pushes symbol (net 0)
        // Use def_macro/def_dynamic/def_private opcode to preserve flags at runtime
        const op: OpCode = if (node.is_macro) .def_macro else if (node.is_dynamic) .def_dynamic else if (node.is_private) .def_private else .def;
        try self.chunk.emit(op, idx);
    }

    fn emitSetBang(self: *Compiler, node: *const node_mod.SetNode) CompileError!void {
        // (set! var-sym expr) — mutate thread-local binding
        const sym_val = Value.initSymbol(self.allocator, .{ .ns = null, .name = node.var_name });
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;
        // Compile expression (pushes value)
        try self.compile(node.expr); // +1
        // set_bang: reads top of stack, sets binding, keeps value on stack (net 0 change: value stays)
        try self.chunk.emit(.set_bang, idx);
    }

    fn emitDefmulti(self: *Compiler, node: *const node_mod.DefMultiNode) CompileError!void {
        // Push name as constant
        const sym_val = Value.initSymbol(self.allocator, .{ .ns = null, .name = node.name });
        const idx = self.chunk.addConstant(sym_val) catch return error.TooManyConstants;

        // Compile optional hierarchy var reference (must be on stack BEFORE dispatch fn)
        if (node.hierarchy_node) |h_node| {
            try self.compile(h_node); // +1 (tracked by compile)
        }

        // Compile dispatch function
        try self.compile(node.dispatch_fn); // +1

        // Operand: name_idx | (has_hierarchy << 15)
        const has_h: u16 = if (node.hierarchy_node != null) 1 else 0;
        const operand = idx | (has_h << 15);

        // defmulti: pops dispatch_fn (and optionally hierarchy), creates MultiFn, pushes result
        try self.chunk.emit(.defmulti, operand);
        if (node.hierarchy_node != null) {
            self.stack_depth -= 1; // hierarchy was consumed
        }
    }

    fn emitDefmethod(self: *Compiler, node: *const node_mod.DefMethodNode) CompileError!void {
        // Push multimethod name as constant
        const sym_val = Value.initSymbol(self.allocator, .{ .ns = null, .name = node.multi_name });
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

    fn emitDefprotocol(self: *Compiler, node: *const node_mod.DefProtocolNode) CompileError!void {
        // Constant[idx] = protocol name symbol
        const name_sym = Value.initSymbol(self.allocator, .{ .ns = null, .name = node.name });
        const idx = self.chunk.addConstant(name_sym) catch return error.TooManyConstants;

        // Constant[idx+1] = sigs vector: [name1, arity1, name2, arity2, ...]
        const sigs_len = node.method_sigs.len * 2;
        const sigs_items = self.allocator.alloc(Value, sigs_len) catch return error.OutOfMemory;
        for (node.method_sigs, 0..) |sig, i| {
            sigs_items[i * 2] = Value.initString(self.allocator, sig.name);
            sigs_items[i * 2 + 1] = Value.initInteger(@intCast(sig.arity));
        }
        const sigs_vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
        sigs_vec.* = .{ .items = sigs_items };
        _ = self.chunk.addConstant(Value.initVector(sigs_vec)) catch return error.TooManyConstants;

        // Emit opcode: [] -> [protocol]
        try self.chunk.emit(.defprotocol, idx);
        self.stack_depth += 1;
    }

    fn emitExtendType(self: *Compiler, node: *const node_mod.ExtendTypeNode) CompileError!void {
        if (node.methods.len == 0) {
            try self.chunk.emitOp(.nil);
            self.stack_depth += 1;
            return;
        }

        for (node.methods, 0..) |method, i| {
            // Compile method fn -> pushes fn_val (+1)
            try self.emitFn(method.fn_node);

            // Create meta vector: [type_name, protocol_name, method_name]
            const meta_items = self.allocator.alloc(Value, 3) catch return error.OutOfMemory;
            meta_items[0] = Value.initString(self.allocator, node.type_name);
            meta_items[1] = Value.initString(self.allocator, node.protocol_name);
            meta_items[2] = Value.initString(self.allocator, method.name);
            const meta_vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
            meta_vec.* = .{ .items = meta_items };
            const meta_idx = self.chunk.addConstant(Value.initVector(meta_vec)) catch return error.TooManyConstants;

            // extend_type_method: pops fn, pushes nil (net 0)
            try self.chunk.emit(.extend_type_method, meta_idx);

            // Pop nil for non-last methods
            if (i < node.methods.len - 1) {
                try self.chunk.emitOp(.pop);
                self.stack_depth -= 1;
            }
        }
    }

    fn emitQuote(self: *Compiler, node: *const node_mod.QuoteNode) CompileError!void {
        const idx = self.chunk.addConstant(node.value) catch return error.TooManyConstants;
        try self.chunk.emit(.const_load, idx);
        self.stack_depth += 1;
    }

    fn emitThrow(self: *Compiler, node: *const node_mod.ThrowNode) CompileError!void {
        try self.compile(node.expr); // +1
        try self.chunk.emitOp(.throw_ex);
        // throw transfers control, so the pop never executes at runtime.
        // Keep stack_depth as +1 so enclosing do/try won't underflow when
        // popping intermediate results.
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
        } else {
            // No catch, no finally: re-throw the exception so it propagates.
            self.stack_depth = depth_before_body;
            self.stack_depth += 1; // exception on stack (pushed by throw handler)
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
        // Store the var reference symbol as a constant.
        // Symbols are NOT fully-qualified here — namespace isolation is handled
        // by setting Fn.defining_ns at closure creation time (D68).
        const sym_val = Value.initSymbol(self.allocator, .{ .ns = ref.ns, .name = ref.name });
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

    const node = Node{ .constant = .{ .value = Value.nil_val } };
    try compiler.compile(&node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.nil, compiler.chunk.code.items[0].op);
}

test "compile constant true/false" {
    const allocator = std.testing.allocator;

    {
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        const node = Node{ .constant = .{ .value = Value.true_val } };
        try compiler.compile(&node);
        try std.testing.expectEqual(OpCode.true_val, compiler.chunk.code.items[0].op);
    }

    {
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        const node = Node{ .constant = .{ .value = Value.false_val } };
        try compiler.compile(&node);
        try std.testing.expectEqual(OpCode.false_val, compiler.chunk.code.items[0].op);
    }
}

test "compile constant integer" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    const node = Node{ .constant = .{ .value = Value.initInteger(42) } };
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

    var test_n = Node{ .constant = .{ .value = Value.true_val } };
    var then_n = Node{ .constant = .{ .value = Value.initInteger(1) } };
    var else_n = Node{ .constant = .{ .value = Value.initInteger(2) } };

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

    var test_n = Node{ .constant = .{ .value = Value.true_val } };
    var then_n = Node{ .constant = .{ .value = Value.initInteger(1) } };

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

    var stmt1 = Node{ .constant = .{ .value = Value.initInteger(1) } };
    var stmt2 = Node{ .constant = .{ .value = Value.initInteger(2) } };
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var callee = Node{ .var_ref = .{ .ns = null, .name = "f", .source = .{} } };
    var arg1 = Node{ .constant = .{ .value = Value.initInteger(1) } };
    var arg2 = Node{ .constant = .{ .value = Value.initInteger(2) } };
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var init_expr = Node{ .constant = .{ .value = Value.initInteger(42) } };
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
        .value = Value.initInteger(99),
        .source = .{},
    };
    const node = Node{ .quote_node = &quote_data };
    try compiler.compile(&node);

    const code = compiler.chunk.code.items;
    try std.testing.expectEqual(OpCode.const_load, code[0].op);
    try std.testing.expectEqual(@as(usize, 1), code.len);
}

test "compile throw_node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var expr = Node{ .constant = .{ .value = Value.initString(allocator, "error!") } };
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

    var init_val = Node{ .constant = .{ .value = Value.initInteger(1) } };
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
    try std.testing.expect(fn_const.tag() == .fn_val);
}

// --- Peephole optimizer (37.2) ---
//
// Post-compile pass that fuses common instruction sequences into single
// superinstructions. Scans for patterns like local_load+local_load+add and
// replaces them with add_locals. Removes dead instructions and fixes jump
// offsets. Applied to each FnProto before it's finalized.

/// Peephole-optimize a bytecode sequence in-place. Returns compacted arrays.
/// The allocator must match the one used for the original slices.
fn peepholeOptimize(
    allocator: std.mem.Allocator,
    code: []Instruction,
    lines: []u32,
    columns: []u32,
) struct { code: []Instruction, lines: []u32, columns: []u32 } {
    const n = code.len;
    if (n < 3) return .{ .code = code, .lines = lines, .columns = columns };

    // Pass 1: Collect jump targets (absolute IPs that are branched to).
    var jump_targets = std.StaticBitSet(65536).initEmpty();
    for (code, 0..) |instr, ip| {
        switch (instr.op) {
            .jump, .jump_if_false => {
                const signed: i32 = @as(i32, @intCast(ip)) + 1 + @as(i32, instr.signedOperand());
                if (signed >= 0 and signed < @as(i32, @intCast(n))) {
                    jump_targets.set(@intCast(signed));
                }
            },
            .jump_back => {
                const target = ip + 1 -| instr.operand;
                if (target < n) jump_targets.set(target);
            },
            else => {},
        }
    }

    // Pass 2: Mark fuseable patterns. A pattern is fuseable only if no jump
    // targets land on the 2nd or 3rd instruction of the sequence.
    // removed[i] = true means instruction i will be dropped.
    var removed: [65536]bool = .{false} ** 65536;
    var i: usize = 0;
    while (i + 2 < n) : (i += 1) {
        // Skip if any of the 3 positions would be a jump target (except first)
        if (jump_targets.isSet(i + 1) or jump_targets.isSet(i + 2)) continue;

        const a = code[i];
        const b = code[i + 1];
        const c = code[i + 2];

        // Pattern: local_load + local_load + arith/cmp
        if (a.op == .local_load and b.op == .local_load and a.operand <= 255 and b.operand <= 255) {
            const fused_operand: u16 = (@as(u16, @intCast(a.operand & 0xFF)) << 8) | @as(u16, @intCast(b.operand & 0xFF));
            const fused_op: ?OpCode = switch (c.op) {
                .add => .add_locals,
                .sub => .sub_locals,
                .eq => .eq_locals,
                .lt => .lt_locals,
                .le => .le_locals,
                else => null,
            };
            if (fused_op) |op| {
                code[i] = .{ .op = op, .operand = fused_operand };
                // Use line/column from the operator (last instruction) for error reporting
                lines[i] = lines[i + 2];
                columns[i] = columns[i + 2];
                removed[i + 1] = true;
                removed[i + 2] = true;
                i += 2; // skip fused instructions
                continue;
            }
        }

        // Pattern: local_load + const_load + arith/cmp
        if (a.op == .local_load and b.op == .const_load and a.operand <= 255 and b.operand <= 255) {
            const fused_operand: u16 = (@as(u16, @intCast(a.operand & 0xFF)) << 8) | @as(u16, @intCast(b.operand & 0xFF));
            const fused_op: ?OpCode = switch (c.op) {
                .add => .add_local_const,
                .sub => .sub_local_const,
                .eq => .eq_local_const,
                .lt => .lt_local_const,
                .le => .le_local_const,
                else => null,
            };
            if (fused_op) |op| {
                code[i] = .{ .op = op, .operand = fused_operand };
                lines[i] = lines[i + 2];
                columns[i] = columns[i + 2];
                removed[i + 1] = true;
                removed[i + 2] = true;
                i += 2;
                continue;
            }
        }
    }

    // Pass 3: Build old→new IP mapping and compact arrays.
    var ip_map: [65536]u16 = undefined;
    var new_ip: u16 = 0;
    for (0..n) |old_ip| {
        ip_map[old_ip] = new_ip;
        if (!removed[old_ip]) {
            code[new_ip] = code[old_ip];
            lines[new_ip] = lines[old_ip];
            columns[new_ip] = columns[old_ip];
            new_ip += 1;
        }
    }
    // Map for IP = n (one past end, for forward jumps that land at end)
    if (n < 65536) ip_map[n] = new_ip;

    const new_len: usize = new_ip;

    // Pass 4: Build reverse mapping (new_ip → old_ip) and fix jump offsets.
    var old_ip_for_new: [65536]u16 = undefined;
    new_ip = 0;
    for (0..n) |old_ip| {
        if (!removed[old_ip]) {
            old_ip_for_new[new_ip] = @intCast(old_ip);
            new_ip += 1;
        }
    }

    // Now fix jumps.
    for (code[0..new_len], 0..) |*instr, nip| {
        switch (instr.op) {
            .jump, .jump_if_false => {
                const old_ip2: usize = old_ip_for_new[nip];
                const old_target_signed: i32 = @as(i32, @intCast(old_ip2)) + 1 + @as(i32, instr.signedOperand());
                const old_target: usize = @intCast(@max(0, @min(old_target_signed, @as(i32, @intCast(n)))));
                const new_target = ip_map[old_target];
                const new_offset: i16 = @intCast(@as(i32, new_target) - @as(i32, @intCast(nip)) - 1);
                instr.operand = @bitCast(new_offset);
            },
            .jump_back => {
                const old_ip2: usize = old_ip_for_new[nip];
                const old_target = old_ip2 + 1 -| instr.operand;
                const new_target = ip_map[old_target];
                instr.operand = @intCast(@as(i32, @intCast(nip)) + 1 - @as(i32, new_target));
            },
            .try_begin => {
                // try_begin operand is a forward offset to catch handler (same as jump)
                const old_ip2: usize = old_ip_for_new[nip];
                const old_target: usize = old_ip2 + 1 + instr.operand;
                const clamped = @min(old_target, n);
                const new_target = ip_map[clamped];
                instr.operand = @intCast(@as(i32, new_target) - @as(i32, @intCast(nip)) - 1);
            },
            else => {},
        }
    }

    // Pass 5: In-place fusion (compare-and-branch, recur-loop).
    // These replace instruction pairs without changing count. The second
    // instruction becomes a data word consumed by the first.
    {
        const final_code = code[0..new_len];
        // Rebuild jump targets on the (possibly compacted) code.
        var jt2 = std.StaticBitSet(65536).initEmpty();
        for (final_code, 0..) |instr2, ip2| {
            switch (instr2.op) {
                .jump, .jump_if_false => {
                    const signed2: i32 = @as(i32, @intCast(ip2)) + 1 + @as(i32, instr2.signedOperand());
                    if (signed2 >= 0 and signed2 < @as(i32, @intCast(new_len))) {
                        jt2.set(@intCast(signed2));
                    }
                },
                .jump_back => {
                    const target2 = ip2 + 1 -| instr2.operand;
                    if (target2 < new_len) jt2.set(target2);
                },
                else => {},
            }
        }

        var j: usize = 0;
        while (j + 1 < new_len) : (j += 1) {
            // Don't fuse if the second instruction is a jump target.
            if (jt2.isSet(j + 1)) continue;

            const first = final_code[j];
            const second = final_code[j + 1];

            // Compare-and-branch: *_locals/local_const + jump_if_false
            // → branch_*. Note: jump_if_false branches when false, so
            // eq → branch_ne (branch when NOT equal), lt → branch_ge, le → branch_gt.
            if (second.op == .jump_if_false) {
                const branch_op: ?OpCode = switch (first.op) {
                    .eq_locals => .branch_ne_locals,
                    .lt_locals => .branch_ge_locals,
                    .le_locals => .branch_gt_locals,
                    .eq_local_const => .branch_ne_local_const,
                    .lt_local_const => .branch_ge_local_const,
                    .le_local_const => .branch_gt_local_const,
                    else => null,
                };
                if (branch_op) |op| {
                    final_code[j] = .{ .op = op, .operand = first.operand };
                    // Keep second instruction as data word (operand = jump offset).
                    j += 1; // skip data word
                    continue;
                }
            }

            // Recur + jump_back → recur_loop (data word holds loop offset).
            if (first.op == .recur and second.op == .jump_back) {
                final_code[j] = .{ .op = .recur_loop, .operand = first.operand };
                // Keep second instruction as data word (operand = loop offset).
                j += 1; // skip data word
                continue;
            }
        }
    }

    // If nothing was removed, return originals unchanged.
    if (new_len == n) return .{ .code = code, .lines = lines, .columns = columns };

    // Allocate correctly-sized copies and free originals.
    const new_code = allocator.dupe(Instruction, code[0..new_len]) catch
        return .{ .code = code, .lines = lines, .columns = columns };
    const new_lines = allocator.dupe(u32, lines[0..new_len]) catch
        return .{ .code = code, .lines = lines, .columns = columns };
    const new_columns = allocator.dupe(u32, columns[0..new_len]) catch
        return .{ .code = code, .lines = lines, .columns = columns };
    allocator.free(code);
    allocator.free(lines);
    allocator.free(columns);
    return .{ .code = new_code, .lines = new_lines, .columns = new_columns };
}

test "compile var_ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
