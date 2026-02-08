// Wasm stack-based VM — switch-based dispatch for all MVP opcodes.
//
// Design: direct bytecode execution (no IR). LEB128 immediates decoded inline.
// Branch targets pre-computed on function entry via side table.
// Cross-compile friendly: no .always_tail, pure switch dispatch.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const Opcode = opcode.Opcode;
const ValType = opcode.ValType;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const WasmMemory = @import("memory.zig").Memory;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;

pub const WasmError = error{
    Trap,
    StackOverflow,
    StackUnderflow,
    DivisionByZero,
    IntegerOverflow,
    InvalidConversion,
    OutOfBoundsMemoryAccess,
    UndefinedElement,
    MismatchedSignatures,
    Unreachable,
    OutOfMemory,
    FunctionIndexOutOfBounds,
    MemoryIndexOutOfBounds,
    TableIndexOutOfBounds,
    GlobalIndexOutOfBounds,
    BadFunctionIndex,
    BadMemoryIndex,
    BadTableIndex,
    BadGlobalIndex,
    InvalidWasm,
    InvalidInitExpr,
    ImportNotFound,
    ModuleNotDecoded,
    FunctionCodeMismatch,
    InvalidTypeIndex,
    BadElemAddr,
    BadDataAddr,
    EndOfStream,
    Overflow,
    OutOfBounds,
    FileNotFound,
    ElemIndexOutOfBounds,
    DataIndexOutOfBounds,
};

const OPERAND_STACK_SIZE = 4096;
const FRAME_STACK_SIZE = 256;
const LABEL_STACK_SIZE = 256;

const Frame = struct {
    locals_start: usize, // index into operand stack where locals begin
    locals_count: usize, // total locals (params + locals)
    return_arity: usize,
    op_stack_base: usize, // operand stack base for this frame
    label_stack_base: usize,
    return_reader: Reader, // reader position to return to
    instance: *Instance,
};

const Label = struct {
    arity: usize,
    op_stack_base: usize,
    target: LabelTarget,
};

const LabelTarget = union(enum) {
    /// For block/if: jump past end (continue)
    forward: Reader, // reader state at the end opcode
    /// For loop: jump to loop header
    loop_start: Reader, // reader state at loop body start
};

/// Pre-computed branch target info for a function.
/// Maps bytecode offset → branch target offset.
const BranchTable = struct {
    /// offset → target offset for 'end' of each block/if/loop
    end_targets: std.AutoHashMapUnmanaged(usize, usize),
    /// offset → else offset for 'if' blocks
    else_targets: std.AutoHashMapUnmanaged(usize, usize),
    alloc: Allocator,

    fn init(alloc: Allocator) BranchTable {
        return .{
            .end_targets = .empty,
            .else_targets = .empty,
            .alloc = alloc,
        };
    }

    fn deinit(self: *BranchTable) void {
        self.end_targets.deinit(self.alloc);
        self.else_targets.deinit(self.alloc);
    }
};

pub const Vm = struct {
    op_stack: [OPERAND_STACK_SIZE]u64,
    op_ptr: usize,
    frame_stack: [FRAME_STACK_SIZE]Frame,
    frame_ptr: usize,
    label_stack: [LABEL_STACK_SIZE]Label,
    label_ptr: usize,
    alloc: Allocator,
    current_instance: ?*Instance = null,

    pub fn init(alloc: Allocator) Vm {
        return .{
            .op_stack = undefined,
            .op_ptr = 0,
            .frame_stack = undefined,
            .frame_ptr = 0,
            .label_stack = undefined,
            .label_ptr = 0,
            .alloc = alloc,
        };
    }

    /// Invoke an exported function by name.
    pub fn invoke(
        self: *Vm,
        instance: *Instance,
        name: []const u8,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        const func_addr = instance.getExportFunc(name) orelse return error.FunctionIndexOutOfBounds;
        const func = try instance.store.getFunction(func_addr);
        try self.callFunction(instance, func, args, results);
    }

    /// Call a function (wasm or host) with given args, writing results.
    fn callFunction(
        self: *Vm,
        instance: *Instance,
        func: store_mod.Function,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        switch (func.subtype) {
            .wasm_function => |wf| {
                const base = self.op_ptr;

                // Push args as locals
                for (args) |arg| try self.push(arg);

                // Zero-initialize locals
                for (0..wf.locals_count) |_| try self.push(0);

                // Push frame
                try self.pushFrame(.{
                    .locals_start = base,
                    .locals_count = args.len + wf.locals_count,
                    .return_arity = func.results.len,
                    .op_stack_base = base,
                    .label_stack_base = self.label_ptr,
                    .return_reader = Reader.init(&.{}),
                    .instance = @ptrCast(@alignCast(wf.instance)),
                });

                // Push implicit function label
                var body_reader = Reader.init(wf.code);
                try self.pushLabel(.{
                    .arity = func.results.len,
                    .op_stack_base = base + args.len + wf.locals_count,
                    .target = .{ .forward = body_reader },
                });

                // Execute
                const inst: *Instance = @ptrCast(@alignCast(wf.instance));
                try self.execute(&body_reader, inst);

                // Copy results
                const result_start = self.op_ptr - results.len;
                for (results, 0..) |*r, i| r.* = self.op_stack[result_start + i];
                self.op_ptr = base;
            },
            .host_function => |hf| {
                // Push args
                const base = self.op_ptr;
                for (args) |arg| try self.push(arg);

                // Call host function
                self.current_instance = instance;
                hf.func(@ptrCast(self), hf.context) catch return error.Trap;

                // Pop results
                for (results, 0..) |*r, i| {
                    if (base + i < self.op_ptr)
                        r.* = self.op_stack[base + i]
                    else
                        r.* = 0;
                }
                self.op_ptr = base;
            },
        }
    }

    // ================================================================
    // Main execution loop
    // ================================================================

    fn execute(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        while (reader.hasMore()) {
            const byte = try reader.readByte();
            const op: Opcode = @enumFromInt(byte);

            switch (op) {
                // ---- Control flow ----
                .@"unreachable" => return error.Unreachable,
                .nop => {},
                .block => {
                    const bt = try readBlockType(reader);
                    const result_arity = blockTypeArity(bt, instance);
                    // Find matching end
                    var end_reader = reader.*;
                    try skipToEnd(&end_reader);
                    try self.pushLabel(.{
                        .arity = result_arity,
                        .op_stack_base = self.op_ptr,
                        .target = .{ .forward = end_reader },
                    });
                },
                .loop => {
                    _ = try readBlockType(reader);
                    // Loop branches back to the loop header
                    const loop_reader = reader.*;
                    try self.pushLabel(.{
                        .arity = 0, // loop branch takes 0 results
                        .op_stack_base = self.op_ptr,
                        .target = .{ .loop_start = loop_reader },
                    });
                },
                .@"if" => {
                    const bt = try readBlockType(reader);
                    const result_arity = blockTypeArity(bt, instance);
                    const cond = self.popI32();
                    // Find matching else/end
                    var else_reader = reader.*;
                    var end_reader = reader.*;
                    const has_else = try findElseOrEnd(&else_reader, &end_reader);

                    if (cond != 0) {
                        // True branch: execute, push label to end
                        try self.pushLabel(.{
                            .arity = result_arity,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .forward = end_reader },
                        });
                    } else {
                        // False branch: skip to else or end
                        if (has_else) {
                            reader.* = else_reader;
                            try self.pushLabel(.{
                                .arity = result_arity,
                                .op_stack_base = self.op_ptr,
                                .target = .{ .forward = end_reader },
                            });
                        } else {
                            reader.* = end_reader;
                        }
                    }
                },
                .@"else" => {
                    // Reached else from true branch — jump to end
                    const label = self.peekLabel(0);
                    reader.* = switch (label.target) {
                        .forward => |r| r,
                        .loop_start => |r| r,
                    };
                    _ = self.popLabel();
                },
                .end => {
                    if (self.label_ptr > 0 and (self.frame_ptr == 0 or
                        self.label_ptr > self.frame_stack[self.frame_ptr - 1].label_stack_base))
                    {
                        _ = self.popLabel();
                    } else {
                        // Function end — return
                        return;
                    }
                },
                .br => {
                    const depth = try reader.readU32();
                    try self.branchTo(depth, reader);
                },
                .br_if => {
                    const depth = try reader.readU32();
                    const cond = self.popI32();
                    if (cond != 0) {
                        try self.branchTo(depth, reader);
                    }
                },
                .br_table => {
                    const count = try reader.readU32();
                    const idx = @as(u32, @bitCast(self.popI32()));
                    // Read all targets
                    var default_depth: u32 = 0;
                    var target_depth: ?u32 = null;
                    for (0..count) |i| {
                        const d = try reader.readU32();
                        if (i == idx) target_depth = d;
                    }
                    default_depth = try reader.readU32();
                    if (idx >= count) target_depth = default_depth;
                    try self.branchTo(target_depth orelse default_depth, reader);
                },
                .@"return" => return,
                .call => {
                    const func_idx = try reader.readU32();
                    try self.doCall(instance, func_idx, reader);
                },
                .call_indirect => {
                    const type_idx = try reader.readU32();
                    const table_idx = try reader.readU32();
                    const elem_idx = @as(u32, @bitCast(self.popI32()));
                    const t = try instance.getTable(table_idx);
                    const func_addr = try t.lookup(elem_idx);
                    const func = try instance.store.getFunction(func_addr);

                    // Type check
                    if (type_idx < instance.module.types.items.len) {
                        const expected = instance.module.types.items[type_idx];
                        if (expected.params.len != func.params.len or
                            expected.results.len != func.results.len)
                            return error.MismatchedSignatures;
                    }

                    try self.doCallDirect(instance, func, reader);
                },

                // ---- Parametric ----
                .drop => _ = self.pop(),
                .select, .select_t => {
                    if (op == .select_t) _ = try reader.readU32(); // skip type count + types
                    const cond = self.popI32();
                    const val2 = self.pop();
                    const val1 = self.pop();
                    try self.push(if (cond != 0) val1 else val2);
                },

                // ---- Variable access ----
                .local_get => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    try self.push(self.op_stack[frame.locals_start + idx]);
                },
                .local_set => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.pop();
                },
                .local_tee => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.peek();
                },
                .global_get => {
                    const idx = try reader.readU32();
                    const g = try instance.getGlobal(idx);
                    try self.push(g.value);
                },
                .global_set => {
                    const idx = try reader.readU32();
                    const g = try instance.getGlobal(idx);
                    g.value = self.pop();
                },

                // ---- Table access ----
                .table_get => {
                    const table_idx = try reader.readU32();
                    const elem_idx = @as(u32, @bitCast(self.popI32()));
                    const t = try instance.getTable(table_idx);
                    const val = t.get(elem_idx) catch return error.OutOfBoundsMemoryAccess;
                    try self.push(if (val) |v| @as(u64, @intCast(v)) else 0);
                },
                .table_set => {
                    const table_idx = try reader.readU32();
                    const val = self.pop();
                    const elem_idx = @as(u32, @bitCast(self.popI32()));
                    const t = try instance.getTable(table_idx);
                    t.set(elem_idx, @intCast(val)) catch return error.OutOfBoundsMemoryAccess;
                },

                // ---- Memory load ----
                .i32_load => try self.memLoad(i32, u32, reader, instance),
                .i64_load => try self.memLoad(i64, u64, reader, instance),
                .f32_load => try self.memLoadFloat(f32, reader, instance),
                .f64_load => try self.memLoadFloat(f64, reader, instance),
                .i32_load8_s => try self.memLoad(i8, i32, reader, instance),
                .i32_load8_u => try self.memLoad(u8, u32, reader, instance),
                .i32_load16_s => try self.memLoad(i16, i32, reader, instance),
                .i32_load16_u => try self.memLoad(u16, u32, reader, instance),
                .i64_load8_s => try self.memLoad(i8, i64, reader, instance),
                .i64_load8_u => try self.memLoad(u8, u64, reader, instance),
                .i64_load16_s => try self.memLoad(i16, i64, reader, instance),
                .i64_load16_u => try self.memLoad(u16, u64, reader, instance),
                .i64_load32_s => try self.memLoad(i32, i64, reader, instance),
                .i64_load32_u => try self.memLoad(u32, u64, reader, instance),

                // ---- Memory store ----
                .i32_store => try self.memStore(u32, reader, instance),
                .i64_store => try self.memStore(u64, reader, instance),
                .f32_store => try self.memStoreFloat(f32, reader, instance),
                .f64_store => try self.memStoreFloat(f64, reader, instance),
                .i32_store8 => try self.memStore(u8, reader, instance),
                .i32_store16 => try self.memStore(u16, reader, instance),
                .i64_store8 => try self.memStoreTrunc(u8, u64, reader, instance),
                .i64_store16 => try self.memStoreTrunc(u16, u64, reader, instance),
                .i64_store32 => try self.memStoreTrunc(u32, u64, reader, instance),

                // ---- Memory misc ----
                .memory_size => {
                    _ = try reader.readU32(); // memidx
                    const m = try instance.getMemory(0);
                    try self.pushI32(@bitCast(m.size()));
                },
                .memory_grow => {
                    _ = try reader.readU32(); // memidx
                    const pages = @as(u32, @bitCast(self.popI32()));
                    const m = try instance.getMemory(0);
                    const old = m.grow(pages) catch {
                        try self.pushI32(-1);
                        continue;
                    };
                    try self.pushI32(@bitCast(old));
                },

                // ---- Constants ----
                .i32_const => try self.pushI32(try reader.readI32()),
                .i64_const => try self.pushI64(try reader.readI64()),
                .f32_const => try self.pushF32(try reader.readF32()),
                .f64_const => try self.pushF64(try reader.readF64()),

                // ---- i32 comparison ----
                .i32_eqz => { const a = self.popI32(); try self.pushI32(b2i(a == 0)); },
                .i32_eq => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a == b)); },
                .i32_ne => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a != b)); },
                .i32_lt_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a < b)); },
                .i32_lt_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a < b)); },
                .i32_gt_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a > b)); },
                .i32_gt_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a > b)); },
                .i32_le_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a <= b)); },
                .i32_le_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a <= b)); },
                .i32_ge_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a >= b)); },
                .i32_ge_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a >= b)); },

                // ---- i64 comparison ----
                .i64_eqz => { const a = self.popI64(); try self.pushI32(b2i(a == 0)); },
                .i64_eq => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a == b)); },
                .i64_ne => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a != b)); },
                .i64_lt_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a < b)); },
                .i64_lt_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a < b)); },
                .i64_gt_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a > b)); },
                .i64_gt_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a > b)); },
                .i64_le_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a <= b)); },
                .i64_le_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a <= b)); },
                .i64_ge_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a >= b)); },
                .i64_ge_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a >= b)); },

                // ---- f32 comparison ----
                .f32_eq => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a == b)); },
                .f32_ne => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a != b)); },
                .f32_lt => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a < b)); },
                .f32_gt => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a > b)); },
                .f32_le => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a <= b)); },
                .f32_ge => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a >= b)); },

                // ---- f64 comparison ----
                .f64_eq => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a == b)); },
                .f64_ne => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a != b)); },
                .f64_lt => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a < b)); },
                .f64_gt => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a > b)); },
                .f64_le => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a <= b)); },
                .f64_ge => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a >= b)); },

                // ---- i32 arithmetic ----
                .i32_clz => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @clz(a)))); },
                .i32_ctz => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @ctz(a)))); },
                .i32_popcnt => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @popCount(a)))); },
                .i32_add => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a +% b); },
                .i32_sub => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a -% b); },
                .i32_mul => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a *% b); },
                .i32_div_s => {
                    const b = self.popI32(); const a = self.popI32();
                    if (b == 0) return error.DivisionByZero;
                    if (a == math.minInt(i32) and b == -1) return error.IntegerOverflow;
                    try self.pushI32(@divTrunc(a, b));
                },
                .i32_div_u => {
                    const b = self.popU32(); const a = self.popU32();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a / b));
                },
                .i32_rem_s => {
                    const b = self.popI32(); const a = self.popI32();
                    if (b == 0) return error.DivisionByZero;
                    if (b == -1) { try self.pushI32(0); } else { try self.pushI32(@rem(a, b)); }
                },
                .i32_rem_u => {
                    const b = self.popU32(); const a = self.popU32();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a % b));
                },
                .i32_and => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a & b)); },
                .i32_or => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a | b)); },
                .i32_xor => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a ^ b)); },
                .i32_shl => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a << @truncate(b % 32))); },
                .i32_shr_s => { const b = self.popU32(); const a = self.popI32(); try self.pushI32(a >> @truncate(@as(u32, @bitCast(b)) % 32)); },
                .i32_shr_u => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a >> @truncate(b % 32))); },
                .i32_rotl => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotl(u32, a, b % 32))); },
                .i32_rotr => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotr(u32, a, b % 32))); },

                // ---- i64 arithmetic ----
                .i64_clz => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @clz(a)))); },
                .i64_ctz => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @ctz(a)))); },
                .i64_popcnt => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @popCount(a)))); },
                .i64_add => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a +% b); },
                .i64_sub => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a -% b); },
                .i64_mul => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a *% b); },
                .i64_div_s => {
                    const b = self.popI64(); const a = self.popI64();
                    if (b == 0) return error.DivisionByZero;
                    if (a == math.minInt(i64) and b == -1) return error.IntegerOverflow;
                    try self.pushI64(@divTrunc(a, b));
                },
                .i64_div_u => {
                    const b = self.popU64(); const a = self.popU64();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI64(@bitCast(a / b));
                },
                .i64_rem_s => {
                    const b = self.popI64(); const a = self.popI64();
                    if (b == 0) return error.DivisionByZero;
                    if (b == -1) { try self.pushI64(0); } else { try self.pushI64(@rem(a, b)); }
                },
                .i64_rem_u => {
                    const b = self.popU64(); const a = self.popU64();
                    if (b == 0) return error.DivisionByZero;
                    try self.push(a % b);
                },
                .i64_and => { const b = self.pop(); const a = self.pop(); try self.push(a & b); },
                .i64_or => { const b = self.pop(); const a = self.pop(); try self.push(a | b); },
                .i64_xor => { const b = self.pop(); const a = self.pop(); try self.push(a ^ b); },
                .i64_shl => { const b = self.popU64(); const a = self.popU64(); try self.push(a << @truncate(b % 64)); },
                .i64_shr_s => { const b = self.popU64(); const a = self.popI64(); try self.pushI64(a >> @truncate(b % 64)); },
                .i64_shr_u => { const b = self.popU64(); const a = self.popU64(); try self.push(a >> @truncate(b % 64)); },
                .i64_rotl => { const b = self.popU64(); const a = self.popU64(); try self.push(math.rotl(u64, a, b % 64)); },
                .i64_rotr => { const b = self.popU64(); const a = self.popU64(); try self.push(math.rotr(u64, a, b % 64)); },

                // ---- f32 arithmetic ----
                .f32_abs => { const a = self.popF32(); try self.pushF32(@abs(a)); },
                .f32_neg => { const a = self.popF32(); try self.pushF32(-a); },
                .f32_ceil => { const a = self.popF32(); try self.pushF32(@ceil(a)); },
                .f32_floor => { const a = self.popF32(); try self.pushF32(@floor(a)); },
                .f32_trunc => { const a = self.popF32(); try self.pushF32(@trunc(a)); },
                .f32_nearest => { const a = self.popF32(); try self.pushF32(wasmNearest(f32, a)); },
                .f32_sqrt => { const a = self.popF32(); try self.pushF32(@sqrt(a)); },
                .f32_add => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a + b); },
                .f32_sub => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a - b); },
                .f32_mul => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a * b); },
                .f32_div => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a / b); },
                .f32_min => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMin(f32, a, b)); },
                .f32_max => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMax(f32, a, b)); },
                .f32_copysign => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(std.math.copysign(a, b)); },

                // ---- f64 arithmetic ----
                .f64_abs => { const a = self.popF64(); try self.pushF64(@abs(a)); },
                .f64_neg => { const a = self.popF64(); try self.pushF64(-a); },
                .f64_ceil => { const a = self.popF64(); try self.pushF64(@ceil(a)); },
                .f64_floor => { const a = self.popF64(); try self.pushF64(@floor(a)); },
                .f64_trunc => { const a = self.popF64(); try self.pushF64(@trunc(a)); },
                .f64_nearest => { const a = self.popF64(); try self.pushF64(wasmNearest(f64, a)); },
                .f64_sqrt => { const a = self.popF64(); try self.pushF64(@sqrt(a)); },
                .f64_add => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a + b); },
                .f64_sub => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a - b); },
                .f64_mul => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a * b); },
                .f64_div => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a / b); },
                .f64_min => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMin(f64, a, b)); },
                .f64_max => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMax(f64, a, b)); },
                .f64_copysign => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(std.math.copysign(a, b)); },

                // ---- Type conversions ----
                .i32_wrap_i64 => { const a = self.popI64(); try self.pushI32(@truncate(a)); },
                .i32_trunc_f32_s => { const a = self.popF32(); try self.pushI32(truncSat(i32, f32, a) orelse return error.InvalidConversion); },
                .i32_trunc_f32_u => { const a = self.popF32(); try self.pushI32(@bitCast(truncSat(u32, f32, a) orelse return error.InvalidConversion)); },
                .i32_trunc_f64_s => { const a = self.popF64(); try self.pushI32(truncSat(i32, f64, a) orelse return error.InvalidConversion); },
                .i32_trunc_f64_u => { const a = self.popF64(); try self.pushI32(@bitCast(truncSat(u32, f64, a) orelse return error.InvalidConversion)); },
                .i64_extend_i32_s => { const a = self.popI32(); try self.pushI64(@as(i64, a)); },
                .i64_extend_i32_u => { const a = self.popU32(); try self.pushI64(@as(i64, @as(i64, a))); },
                .i64_trunc_f32_s => { const a = self.popF32(); try self.pushI64(truncSat(i64, f32, a) orelse return error.InvalidConversion); },
                .i64_trunc_f32_u => { const a = self.popF32(); try self.pushI64(@bitCast(truncSat(u64, f32, a) orelse return error.InvalidConversion)); },
                .i64_trunc_f64_s => { const a = self.popF64(); try self.pushI64(truncSat(i64, f64, a) orelse return error.InvalidConversion); },
                .i64_trunc_f64_u => { const a = self.popF64(); try self.pushI64(@bitCast(truncSat(u64, f64, a) orelse return error.InvalidConversion)); },
                .f32_convert_i32_s => { const a = self.popI32(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i32_u => { const a = self.popU32(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i64_s => { const a = self.popI64(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i64_u => { const a = self.popU64(); try self.pushF32(@floatFromInt(a)); },
                .f32_demote_f64 => { const a = self.popF64(); try self.pushF32(@floatCast(a)); },
                .f64_convert_i32_s => { const a = self.popI32(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i32_u => { const a = self.popU32(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i64_s => { const a = self.popI64(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i64_u => { const a = self.popU64(); try self.pushF64(@floatFromInt(a)); },
                .f64_promote_f32 => { const a = self.popF32(); try self.pushF64(@as(f64, a)); },
                .i32_reinterpret_f32 => { const a = self.popF32(); try self.push(@as(u64, @as(u32, @bitCast(a)))); },
                .i64_reinterpret_f64 => { const a = self.popF64(); try self.push(@bitCast(a)); },
                .f32_reinterpret_i32 => { const a = self.popU32(); try self.pushF32(@bitCast(a)); },
                .f64_reinterpret_i64 => { const a = self.pop(); try self.pushF64(@bitCast(a)); },

                // ---- Sign extension ----
                .i32_extend8_s => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i8, @truncate(a)))); },
                .i32_extend16_s => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i16, @truncate(a)))); },
                .i64_extend8_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i8, @truncate(a)))); },
                .i64_extend16_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i16, @truncate(a)))); },
                .i64_extend32_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i32, @truncate(a)))); },

                // ---- Reference types ----
                .ref_null => { _ = try reader.readByte(); try self.push(0); },
                .ref_is_null => { const a = self.pop(); try self.pushI32(b2i(a == 0)); },
                .ref_func => { const idx = try reader.readU32(); try self.push(@as(u64, idx)); },

                // ---- 0xFC prefix (misc) ----
                .misc_prefix => try self.executeMisc(reader, instance),

                // ---- SIMD prefix (Phase 36) ----
                .simd_prefix => return error.Trap,

                _ => return error.Trap,
            }
        }
    }

    fn executeMisc(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const sub = try reader.readU32();
        const misc: opcode.MiscOpcode = @enumFromInt(sub);
        switch (misc) {
            .i32_trunc_sat_f32_s => { const a = self.popF32(); try self.pushI32(truncSatClamp(i32, f32, a)); },
            .i32_trunc_sat_f32_u => { const a = self.popF32(); try self.pushI32(@bitCast(truncSatClamp(u32, f32, a))); },
            .i32_trunc_sat_f64_s => { const a = self.popF64(); try self.pushI32(truncSatClamp(i32, f64, a)); },
            .i32_trunc_sat_f64_u => { const a = self.popF64(); try self.pushI32(@bitCast(truncSatClamp(u32, f64, a))); },
            .i64_trunc_sat_f32_s => { const a = self.popF32(); try self.pushI64(truncSatClamp(i64, f32, a)); },
            .i64_trunc_sat_f32_u => { const a = self.popF32(); try self.pushI64(@bitCast(truncSatClamp(u64, f32, a))); },
            .i64_trunc_sat_f64_s => { const a = self.popF64(); try self.pushI64(truncSatClamp(i64, f64, a)); },
            .i64_trunc_sat_f64_u => { const a = self.popF64(); try self.pushI64(@bitCast(truncSatClamp(u64, f64, a))); },
            .memory_copy => {
                _ = try reader.readU32(); // dst memidx
                _ = try reader.readU32(); // src memidx
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                try m.copyWithin(dst, src, n);
            },
            .memory_fill => {
                _ = try reader.readU32(); // memidx
                const n = @as(u32, @bitCast(self.popI32()));
                const val = @as(u8, @truncate(@as(u32, @bitCast(self.popI32()))));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                try m.fill(dst, n, val);
            },
            .memory_init => {
                const data_idx = try reader.readU32();
                _ = try reader.readU32(); // memidx
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const d = try instance.store.getData(data_idx);
                if (d.dropped) return error.Trap;
                if (@as(u64, src) + n > d.data.len or @as(u64, dst) + n > m.memory().len)
                    return error.OutOfBoundsMemoryAccess;
                @memcpy(m.memory()[dst..][0..n], d.data[src..][0..n]);
            },
            .data_drop => {
                const data_idx = try reader.readU32();
                const d = try instance.store.getData(data_idx);
                d.dropped = true;
            },
            .table_grow => {
                const table_idx = try reader.readU32();
                const n = @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                const t = try instance.store.getTable(table_idx);
                const old = t.grow(n, @intCast(val)) catch {
                    try self.pushI32(-1);
                    return;
                };
                try self.pushI32(@bitCast(old));
            },
            .table_size => {
                const table_idx = try reader.readU32();
                const t = try instance.store.getTable(table_idx);
                try self.pushI32(@bitCast(t.size()));
            },
            .table_fill => {
                const table_idx = try reader.readU32();
                const n = @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                const start = @as(u32, @bitCast(self.popI32()));
                const t = try instance.store.getTable(table_idx);
                for (0..n) |i| {
                    t.set(start + @as(u32, @intCast(i)), @intCast(val)) catch return error.OutOfBoundsMemoryAccess;
                }
            },
            .table_copy => {
                _ = try reader.readU32(); // dst table
                _ = try reader.readU32(); // src table
                // Simple implementation (same table)
                const n = @as(u32, @bitCast(self.popI32()));
                _ = self.popI32(); // src
                _ = self.popI32(); // dst
                _ = n; // TODO: implement cross-table copy
            },
            .table_init => {
                _ = try reader.readU32(); // elem idx
                _ = try reader.readU32(); // table idx
                const n = @as(u32, @bitCast(self.popI32()));
                _ = self.popI32(); // src
                _ = self.popI32(); // dst
                _ = n; // TODO: implement table.init
            },
            .elem_drop => {
                const elem_idx = try reader.readU32();
                const e = try instance.store.getElem(elem_idx);
                e.dropped = true;
            },
            _ => return error.Trap,
        }
    }

    // ================================================================
    // Call helpers
    // ================================================================

    fn doCall(self: *Vm, instance: *Instance, func_idx: u32, reader: *Reader) WasmError!void {
        const func = try instance.getFunc(func_idx);
        try self.doCallDirect(instance, func, reader);
    }

    fn doCallDirect(self: *Vm, instance: *Instance, func: store_mod.Function, reader: *Reader) WasmError!void {
        switch (func.subtype) {
            .wasm_function => |wf| {
                const param_count = func.params.len;
                const locals_start = self.op_ptr - param_count;

                // Zero-initialize locals
                for (0..wf.locals_count) |_| try self.push(0);

                try self.pushFrame(.{
                    .locals_start = locals_start,
                    .locals_count = param_count + wf.locals_count,
                    .return_arity = func.results.len,
                    .op_stack_base = locals_start,
                    .label_stack_base = self.label_ptr,
                    .return_reader = reader.*,
                    .instance = instance,
                });

                var body_reader = Reader.init(wf.code);
                try self.pushLabel(.{
                    .arity = func.results.len,
                    .op_stack_base = self.op_ptr,
                    .target = .{ .forward = body_reader },
                });

                const callee_inst: *Instance = @ptrCast(@alignCast(wf.instance));
                try self.execute(&body_reader, callee_inst);

                // Move results to correct position
                const frame = self.popFrame();
                const n = frame.return_arity;
                if (n > 0) {
                    const src_start = self.op_ptr - n;
                    for (0..n) |i| {
                        self.op_stack[frame.op_stack_base + i] = self.op_stack[src_start + i];
                    }
                }
                self.op_ptr = frame.op_stack_base + n;
                reader.* = frame.return_reader;
            },
            .host_function => |hf| {
                self.current_instance = instance;
                hf.func(@ptrCast(self), hf.context) catch return error.Trap;
            },
        }
    }

    // ================================================================
    // Branch helpers
    // ================================================================

    fn branchTo(self: *Vm, depth: u32, reader: *Reader) WasmError!void {
        const label = self.peekLabel(depth);
        const arity = label.arity;

        // Save results from top of stack
        var results: [16]u64 = undefined;
        var i: usize = arity;
        while (i > 0) {
            i -= 1;
            results[i] = self.pop();
        }

        // Unwind operand stack to label base
        self.op_ptr = label.op_stack_base;

        // Push results back
        for (0..arity) |j| try self.push(results[j]);

        // Set reader to target and pop labels
        switch (label.target) {
            .forward => |r| {
                reader.* = r;
                // Pop labels up to and including target
                self.label_ptr -= (depth + 1);
            },
            .loop_start => |r| {
                // For loops: save label, pop intermediates, re-push loop label
                // so the loop can branch again on next iteration
                const loop_label = label;
                self.label_ptr -= (depth + 1);
                try self.pushLabel(.{
                    .arity = loop_label.arity,
                    .op_stack_base = self.op_ptr,
                    .target = .{ .loop_start = r },
                });
                reader.* = r;
            },
        }
    }

    // ================================================================
    // Memory helpers
    // ================================================================

    fn memLoad(self: *Vm, comptime LoadT: type, comptime ResultT: type, reader: *Reader, instance: *Instance) WasmError!void {
        _ = try reader.readU32(); // alignment (ignored for correctness)
        const offset = try reader.readU32();
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        const val = m.read(LoadT, offset, base) catch return error.OutOfBoundsMemoryAccess;
        // Sign/zero extend to ResultT then push
        const result: ResultT = @intCast(val);
        try self.push(asU64(ResultT, result));
    }

    fn memLoadFloat(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        const val = m.read(T, offset, base) catch return error.OutOfBoundsMemoryAccess;
        switch (T) {
            f32 => try self.pushF32(val),
            f64 => try self.pushF64(val),
            else => unreachable,
        }
    }

    fn memStore(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const val: T = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreFloat(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const val = switch (T) {
            f32 => self.popF32(),
            f64 => self.popF64(),
            else => unreachable,
        };
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreTrunc(self: *Vm, comptime StoreT: type, comptime _: type, reader: *Reader, instance: *Instance) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const val: StoreT = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(StoreT, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    // ================================================================
    // Stack operations
    // ================================================================

    fn push(self: *Vm, val: u64) WasmError!void {
        if (self.op_ptr >= OPERAND_STACK_SIZE) return error.StackOverflow;
        self.op_stack[self.op_ptr] = val;
        self.op_ptr += 1;
    }

    fn pop(self: *Vm) u64 {
        self.op_ptr -= 1;
        return self.op_stack[self.op_ptr];
    }

    fn peek(self: *Vm) u64 {
        return self.op_stack[self.op_ptr - 1];
    }

    fn pushI32(self: *Vm, val: i32) WasmError!void { try self.push(@as(u64, @as(u32, @bitCast(val)))); }
    fn pushI64(self: *Vm, val: i64) WasmError!void { try self.push(@bitCast(val)); }
    fn pushF32(self: *Vm, val: f32) WasmError!void { try self.push(@as(u64, @as(u32, @bitCast(val)))); }
    fn pushF64(self: *Vm, val: f64) WasmError!void { try self.push(@bitCast(val)); }

    fn popI32(self: *Vm) i32 { return @bitCast(@as(u32, @truncate(self.pop()))); }
    fn popU32(self: *Vm) u32 { return @truncate(self.pop()); }
    fn popI64(self: *Vm) i64 { return @bitCast(self.pop()); }
    fn popU64(self: *Vm) u64 { return self.pop(); }
    fn popF32(self: *Vm) f32 { return @bitCast(@as(u32, @truncate(self.pop()))); }
    fn popF64(self: *Vm) f64 { return @bitCast(self.pop()); }

    // Host function stack access (for WASI and host callbacks)
    pub fn pushOperand(self: *Vm, val: u64) WasmError!void { try self.push(val); }
    pub fn popOperand(self: *Vm) u64 { return self.pop(); }
    pub fn popOperandI32(self: *Vm) i32 { return self.popI32(); }
    pub fn popOperandU32(self: *Vm) u32 { return self.popU32(); }
    pub fn popOperandI64(self: *Vm) i64 { return self.popI64(); }

    /// Get memory from the current instance (for host/WASI functions).
    pub fn getMemory(self: *Vm, idx: u32) !*WasmMemory {
        const inst = self.current_instance orelse return error.Trap;
        return inst.getMemory(idx);
    }

    fn pushFrame(self: *Vm, frame: Frame) WasmError!void {
        if (self.frame_ptr >= FRAME_STACK_SIZE) return error.StackOverflow;
        self.frame_stack[self.frame_ptr] = frame;
        self.frame_ptr += 1;
    }

    fn popFrame(self: *Vm) Frame {
        self.frame_ptr -= 1;
        return self.frame_stack[self.frame_ptr];
    }

    fn peekFrame(self: *Vm) Frame {
        return self.frame_stack[self.frame_ptr - 1];
    }

    fn pushLabel(self: *Vm, label: Label) WasmError!void {
        if (self.label_ptr >= LABEL_STACK_SIZE) return error.StackOverflow;
        self.label_stack[self.label_ptr] = label;
        self.label_ptr += 1;
    }

    fn popLabel(self: *Vm) Label {
        self.label_ptr -= 1;
        return self.label_stack[self.label_ptr];
    }

    fn peekLabel(self: *Vm, depth: u32) Label {
        return self.label_stack[self.label_ptr - 1 - depth];
    }
};

// ============================================================
// Helper functions
// ============================================================

fn b2i(b: bool) i32 { return if (b) 1 else 0; }

fn asU64(comptime T: type, val: T) u64 {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) @bitCast(@as(i64, val)) else @as(u64, val),
        else => @compileError("unsupported type"),
    };
}

fn readBlockType(reader: *Reader) !opcode.BlockType {
    const byte = reader.bytes[reader.pos];
    if (byte == 0x40) {
        reader.pos += 1;
        return .empty;
    }
    // Check if it's a valtype (0x7F..0x70)
    if (byte >= 0x6F and byte <= 0x7F) {
        reader.pos += 1;
        return .{ .val_type = @enumFromInt(byte) };
    }
    // Otherwise it's a type index (s33)
    const idx = try reader.readI33();
    return .{ .type_index = @intCast(idx) };
}

fn blockTypeArity(bt: opcode.BlockType, instance: *Instance) usize {
    return switch (bt) {
        .empty => 0,
        .val_type => 1,
        .type_index => |idx| blk: {
            if (idx < instance.module.types.items.len)
                break :blk instance.module.types.items[idx].results.len;
            break :blk 0;
        },
    };
}

/// Skip bytecode until matching `end`, handling nesting.
fn skipToEnd(reader: *Reader) !void {
    var depth: u32 = 1;
    while (depth > 0 and reader.hasMore()) {
        const byte = try reader.readByte();
        const op: Opcode = @enumFromInt(byte);
        switch (op) {
            .block, .loop, .@"if" => {
                _ = try readBlockType(reader);
                depth += 1;
            },
            .end => depth -= 1,
            .@"else" => if (depth == 1) {}, // same depth, continue
            .br, .br_if => _ = try reader.readU32(),
            .br_table => {
                const count = try reader.readU32();
                for (0..count + 1) |_| _ = try reader.readU32();
            },
            .call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            => _ = try reader.readU32(),
            .call_indirect => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .select_t => { const n = try reader.readU32(); for (0..n) |_| _ = try reader.readByte(); },
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .memory_size, .memory_grow => _ = try reader.readU32(),
            .ref_null => _ = try reader.readByte(),
            .misc_prefix => {
                const sub = try reader.readU32();
                switch (sub) {
                    0x0A => { _ = try reader.readU32(); _ = try reader.readU32(); }, // memory.copy
                    0x0B => _ = try reader.readU32(), // memory.fill
                    0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // memory.init
                    0x09 => _ = try reader.readU32(), // data.drop
                    0x0C => { _ = try reader.readU32(); _ = try reader.readU32(); }, // table.init
                    0x0D => _ = try reader.readU32(), // elem.drop
                    0x0E => { _ = try reader.readU32(); _ = try reader.readU32(); }, // table.copy
                    0x0F => _ = try reader.readU32(), // table.grow
                    0x10 => _ = try reader.readU32(), // table.size
                    0x11 => _ = try reader.readU32(), // table.fill
                    else => {},
                }
            },
            else => {}, // Simple opcodes with no immediates
        }
    }
}

/// Find the matching `else` (if present) and `end` for an `if` block.
/// Returns true if `else` was found.
fn findElseOrEnd(else_reader: *Reader, end_reader: *Reader) !bool {
    var depth: u32 = 1;
    var found_else = false;
    const reader = end_reader;
    while (depth > 0 and reader.hasMore()) {
        const pos_before = reader.pos;
        const byte = try reader.readByte();
        const op: Opcode = @enumFromInt(byte);
        switch (op) {
            .block, .loop, .@"if" => {
                _ = try readBlockType(reader);
                depth += 1;
            },
            .end => {
                depth -= 1;
                if (depth == 0) return found_else;
            },
            .@"else" => if (depth == 1) {
                else_reader.* = reader.*;
                _ = pos_before; // else_reader is set to AFTER the else opcode
                found_else = true;
            },
            .br, .br_if => _ = try reader.readU32(),
            .br_table => {
                const count = try reader.readU32();
                for (0..count + 1) |_| _ = try reader.readU32();
            },
            .call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            => _ = try reader.readU32(),
            .call_indirect => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .select_t => { const n = try reader.readU32(); for (0..n) |_| _ = try reader.readByte(); },
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .memory_size, .memory_grow => _ = try reader.readU32(),
            .ref_null => _ = try reader.readByte(),
            .misc_prefix => {
                const sub = try reader.readU32();
                switch (sub) {
                    0x0A => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0B => _ = try reader.readU32(),
                    0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x09 => _ = try reader.readU32(),
                    0x0C => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0D => _ = try reader.readU32(),
                    0x0E => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0F => _ = try reader.readU32(),
                    0x10 => _ = try reader.readU32(),
                    0x11 => _ = try reader.readU32(),
                    else => {},
                }
            },
            else => {},
        }
    }
    return found_else;
}

/// Wasm nearest (round-to-even).
fn wasmNearest(comptime T: type, val: T) T {
    if (math.isNan(val)) return val;
    if (math.isInf(val)) return val;
    return @round(val);
}

/// Wasm min (propagate NaN, handle -0).
fn wasmMin(comptime T: type, a: T, b: T) T {
    if (math.isNan(a)) return a;
    if (math.isNan(b)) return b;
    if (a == 0 and b == 0) {
        // -0 < +0 in wasm
        if (math.signbit(a) != math.signbit(b))
            return if (math.signbit(a)) a else b;
    }
    return @min(a, b);
}

/// Wasm max (propagate NaN, handle -0).
fn wasmMax(comptime T: type, a: T, b: T) T {
    if (math.isNan(a)) return a;
    if (math.isNan(b)) return b;
    if (a == 0 and b == 0) {
        if (math.signbit(a) != math.signbit(b))
            return if (math.signbit(a)) b else a;
    }
    return @max(a, b);
}

/// Truncate float to int, returning null for NaN/overflow (trapping version).
fn truncSat(comptime I: type, comptime F: type, val: F) ?I {
    if (math.isNan(val)) return null;
    if (math.isInf(val)) return null;
    const trunc_val = @trunc(val);
    const min_val: F = @floatFromInt(math.minInt(I));
    const max_val: F = @floatFromInt(math.maxInt(I));
    if (trunc_val < min_val or trunc_val > max_val) return null;
    return @intFromFloat(trunc_val);
}

/// Truncate float to int with saturation (non-trapping version).
fn truncSatClamp(comptime I: type, comptime F: type, val: F) I {
    if (math.isNan(val)) return 0;
    const trunc_val = @trunc(val);
    const min_val: F = @floatFromInt(math.minInt(I));
    const max_val: F = @floatFromInt(math.maxInt(I));
    if (trunc_val <= min_val) return math.minInt(I);
    if (trunc_val >= max_val) return math.maxInt(I);
    return @intFromFloat(trunc_val);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn readTestFile(alloc: Allocator, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "src/wasm/testdata/{s}", .{name});
    defer alloc.free(path);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try alloc.alloc(u8, stat.size);
    const read = try file.readAll(data);
    return data[0..read];
}

test "VM — add(3, 4) = 7" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "add", &args, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "VM — add(100, -50) = 50" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{ 100, @bitCast(@as(i64, -50)) };
    var results = [_]u64{0};
    try vm.invoke(&inst, "add", &args, &results);
    // i32 wrapping: 100 + (-50) = 50
    try testing.expectEqual(@as(u32, 50), @as(u32, @truncate(results[0])));
}

test "VM — fib(10) = 55" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{10};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "VM — memory store/load" {
    const wasm = try readTestFile(testing.allocator, "03_memory.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // store(0, 42)
    var store_args = [_]u64{ 0, 42 };
    var store_results = [_]u64{};
    try vm.invoke(&inst, "store", &store_args, &store_results);

    // load(0) should be 42
    var load_args = [_]u64{0};
    var load_results = [_]u64{0};
    try vm.invoke(&inst, "load", &load_args, &load_results);
    try testing.expectEqual(@as(u64, 42), load_results[0]);
}

test "VM — globals" {
    const wasm = try readTestFile(testing.allocator, "06_globals.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // Test get_counter and increment
    var args = [_]u64{};
    var results = [_]u64{0};
    try vm.invoke(&inst, "get_counter", &args, &results);
    const initial = results[0];

    try vm.invoke(&inst, "increment", &args, &results);
    try vm.invoke(&inst, "get_counter", &args, &results);
    try testing.expectEqual(initial + 1, results[0]);
}
