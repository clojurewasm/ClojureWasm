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
pub const BranchTable = struct {
    /// block/if/loop start offset → end offset (position after the 'end' opcode)
    end_targets: std.AutoHashMapUnmanaged(usize, usize),
    /// if start offset → else body offset (position after the 'else' opcode)
    else_targets: std.AutoHashMapUnmanaged(usize, usize),
    alloc: Allocator,

    pub fn init(alloc: Allocator) BranchTable {
        return .{
            .end_targets = .empty,
            .else_targets = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BranchTable) void {
        self.end_targets.deinit(self.alloc);
        self.else_targets.deinit(self.alloc);
    }
};

/// Compute branch target table for a function's bytecode.
/// Scans the code once and records block/if/loop → end/else offsets.
pub fn computeBranchTable(alloc: Allocator, code: []const u8) !*BranchTable {
    const bt = try alloc.create(BranchTable);
    bt.* = BranchTable.init(alloc);
    errdefer {
        bt.deinit();
        alloc.destroy(bt);
    }

    // Stack of (opcode_type, body_start_offset) for nesting
    const StructEntry = struct { kind: enum { block, loop, @"if" }, offset: usize };
    var stack: std.ArrayList(StructEntry) = .empty;
    defer stack.deinit(alloc);

    var reader = Reader.init(code);
    while (reader.hasMore()) {
        const pos_before = reader.pos;
        const byte = reader.readByte() catch break;
        const op: Opcode = @enumFromInt(byte);

        switch (op) {
            .block => {
                _ = readBlockType(&reader) catch break;
                // Record body start (after block type) — this is where block body begins
                try stack.append(alloc,.{ .kind = .block, .offset = reader.pos });
            },
            .loop => {
                _ = readBlockType(&reader) catch break;
                try stack.append(alloc,.{ .kind = .loop, .offset = reader.pos });
            },
            .@"if" => {
                _ = readBlockType(&reader) catch break;
                try stack.append(alloc,.{ .kind = .@"if", .offset = reader.pos });
            },
            .@"else" => {
                // Map the if's body_start → else body position
                if (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    if (top.kind == .@"if") {
                        try bt.else_targets.put(alloc, top.offset, reader.pos);
                    }
                }
            },
            .end => {
                if (stack.pop()) |entry| {
                    // Map body_start → position after end opcode
                    try bt.end_targets.put(alloc, entry.offset, reader.pos);
                }
                // else: function-level end, ignore
            },
            // Skip immediates for all other opcodes
            .br, .br_if => _ = reader.readU32() catch break,
            .br_table => {
                const count = reader.readU32() catch break;
                for (0..count + 1) |_| _ = reader.readU32() catch break;
            },
            .call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            => _ = reader.readU32() catch break,
            .call_indirect => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
            .select_t => { const n = reader.readU32() catch break; for (0..n) |_| _ = reader.readByte() catch break; },
            .i32_const => _ = reader.readI32() catch break,
            .i64_const => _ = reader.readI64() catch break,
            .f32_const => _ = reader.readBytes(4) catch break,
            .f64_const => _ = reader.readBytes(8) catch break,
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
            .memory_size, .memory_grow => _ = reader.readU32() catch break,
            .ref_null => _ = reader.readByte() catch break,
            .misc_prefix => {
                const sub = reader.readU32() catch break;
                switch (sub) {
                    0x0A => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x0B => _ = reader.readU32() catch break,
                    0x08 => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x09 => _ = reader.readU32() catch break,
                    0x0C => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x0D => _ = reader.readU32() catch break,
                    0x0E => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x0F => _ = reader.readU32() catch break,
                    0x10 => _ = reader.readU32() catch break,
                    0x11 => _ = reader.readU32() catch break,
                    else => {},
                }
            },
            .simd_prefix => skipSimdImmediates(&reader) catch break,
            else => {},
        }
        _ = pos_before;
    }

    return bt;
}


pub const Vm = struct {
    op_stack: [OPERAND_STACK_SIZE]u128,
    op_ptr: usize,
    frame_stack: [FRAME_STACK_SIZE]Frame,
    frame_ptr: usize,
    label_stack: [LABEL_STACK_SIZE]Label,
    label_ptr: usize,
    alloc: Allocator,
    current_instance: ?*Instance = null,
    current_branch_table: ?*BranchTable = null,

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

    /// Reset VM state for reuse — avoids reallocating the large stack arrays.
    pub fn reset(self: *Vm) void {
        self.op_ptr = 0;
        self.frame_ptr = 0;
        self.label_ptr = 0;
        self.current_instance = null;
        self.current_branch_table = null;
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
        const func_ptr = try instance.store.getFunctionPtr(func_addr);
        try self.callFunction(instance, func_ptr, args, results);
    }

    /// Call a function (wasm or host) with given args, writing results.
    fn callFunction(
        self: *Vm,
        instance: *Instance,
        func_ptr: *store_mod.Function,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        switch (func_ptr.subtype) {
            .wasm_function => |*wf| {
                const base = self.op_ptr;

                // Push args as locals
                for (args) |arg| try self.push(arg);

                // Zero-initialize locals
                for (0..wf.locals_count) |_| try self.push(0);

                // Lazy branch table computation
                if (wf.branch_table == null) {
                    wf.branch_table = computeBranchTable(self.alloc, wf.code) catch null;
                }
                self.current_branch_table = wf.branch_table;

                // Push frame
                try self.pushFrame(.{
                    .locals_start = base,
                    .locals_count = args.len + wf.locals_count,
                    .return_arity = func_ptr.results.len,
                    .op_stack_base = base,
                    .label_stack_base = self.label_ptr,
                    .return_reader = Reader.init(&.{}),
                    .instance = @ptrCast(@alignCast(wf.instance)),
                });

                // Push implicit function label
                var body_reader = Reader.init(wf.code);
                try self.pushLabel(.{
                    .arity = func_ptr.results.len,
                    .op_stack_base = base + args.len + wf.locals_count,
                    .target = .{ .forward = body_reader },
                });

                // Execute
                const inst: *Instance = @ptrCast(@alignCast(wf.instance));
                try self.execute(&body_reader, inst);

                // Copy results
                const result_start = self.op_ptr - results.len;
                for (results, 0..) |*r, i| r.* = @truncate(self.op_stack[result_start + i]);
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
                        r.* = @truncate(self.op_stack[base + i])
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
                    const body_start = reader.pos;
                    var end_reader: Reader = undefined;
                    if (self.current_branch_table) |cbt| {
                        if (cbt.end_targets.get(body_start)) |end_pos| {
                            end_reader = .{ .bytes = reader.bytes, .pos = end_pos };
                        } else {
                            end_reader = reader.*;
                            try skipToEnd(&end_reader);
                        }
                    } else {
                        end_reader = reader.*;
                        try skipToEnd(&end_reader);
                    }
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
                    const body_start = reader.pos;
                    var end_reader: Reader = undefined;
                    var else_reader: Reader = undefined;
                    var has_else = false;
                    if (self.current_branch_table) |cbt| {
                        if (cbt.end_targets.get(body_start)) |end_pos| {
                            end_reader = .{ .bytes = reader.bytes, .pos = end_pos };
                            if (cbt.else_targets.get(body_start)) |else_pos| {
                                else_reader = .{ .bytes = reader.bytes, .pos = else_pos };
                                has_else = true;
                            }
                        } else {
                            else_reader = reader.*;
                            end_reader = reader.*;
                            has_else = try findElseOrEnd(&else_reader, &end_reader);
                        }
                    } else {
                        else_reader = reader.*;
                        end_reader = reader.*;
                        has_else = try findElseOrEnd(&else_reader, &end_reader);
                    }

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
                    const func_ptr = try instance.store.getFunctionPtr(func_addr);

                    // Type check
                    if (type_idx < instance.module.types.items.len) {
                        const expected = instance.module.types.items[type_idx];
                        if (expected.params.len != func_ptr.params.len or
                            expected.results.len != func_ptr.results.len)
                            return error.MismatchedSignatures;
                    }

                    try self.doCallDirect(instance, func_ptr, reader);
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
                    try self.pushV128(self.op_stack[frame.locals_start + idx]);
                },
                .local_set => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.popV128();
                },
                .local_tee => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.op_stack[self.op_ptr - 1];
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

                // ---- SIMD prefix ----
                .simd_prefix => try self.executeSimd(reader, instance),

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

    fn executeSimd(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const sub = try reader.readU32();
        const simd: opcode.SimdOpcode = @enumFromInt(sub);
        switch (simd) {
            // ---- Memory operations (36.2) ----
            .v128_load => {
                _ = try reader.readU32(); // alignment
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u128, offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(val);
            },
            .v128_store => {
                _ = try reader.readU32(); // alignment
                const offset = try reader.readU32();
                const val = self.popV128();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                m.write(u128, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
            },
            .v128_const => {
                // 16 raw bytes (little-endian u128)
                var bytes: [16]u8 = undefined;
                for (&bytes) |*b| b.* = try reader.readByte();
                try self.pushV128(std.mem.readInt(u128, &bytes, .little));
            },

            // Splat loads
            .v128_load8_splat => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u8, offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(16, u8) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load16_splat => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u16, offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(8, u16) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load32_splat => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u32, offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(4, u32) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load64_splat => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u64, offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(2, u64) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },

            // Extending loads
            .v128_load8x8_s => try self.simdExtendLoad(i8, i16, reader, instance),
            .v128_load8x8_u => try self.simdExtendLoad(u8, u16, reader, instance),
            .v128_load16x4_s => try self.simdExtendLoad(i16, i32, reader, instance),
            .v128_load16x4_u => try self.simdExtendLoad(u16, u32, reader, instance),
            .v128_load32x2_s => try self.simdExtendLoad(i32, i64, reader, instance),
            .v128_load32x2_u => try self.simdExtendLoad(u32, u64, reader, instance),

            // Zero-extending loads
            .v128_load32_zero => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u32, offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(@as(u128, val));
            },
            .v128_load64_zero => {
                _ = try reader.readU32();
                const offset = try reader.readU32();
                const base = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(0);
                const val = m.read(u64, offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(@as(u128, val));
            },

            // Lane loads — load N bytes from memory into a specific lane
            .v128_load8_lane => try self.simdLoadLane(u8, 16, reader, instance),
            .v128_load16_lane => try self.simdLoadLane(u16, 8, reader, instance),
            .v128_load32_lane => try self.simdLoadLane(u32, 4, reader, instance),
            .v128_load64_lane => try self.simdLoadLane(u64, 2, reader, instance),

            // Lane stores — store N bytes from a specific lane to memory
            .v128_store8_lane => try self.simdStoreLane(u8, 16, reader, instance),
            .v128_store16_lane => try self.simdStoreLane(u16, 8, reader, instance),
            .v128_store32_lane => try self.simdStoreLane(u32, 4, reader, instance),
            .v128_store64_lane => try self.simdStoreLane(u64, 2, reader, instance),

            // ---- Splat ----
            .i8x16_splat => {
                const val: u8 = @truncate(self.pop());
                const vec: @Vector(16, u8) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i16x8_splat => {
                const val: u16 = @truncate(self.pop());
                const vec: @Vector(8, u16) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i32x4_splat => {
                const val: u32 = @truncate(self.pop());
                const vec: @Vector(4, u32) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i64x2_splat => {
                const val = self.pop();
                const vec: @Vector(2, u64) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .f32x4_splat => {
                const val = self.popF32();
                const bits: u32 = @bitCast(val);
                const vec: @Vector(4, u32) = @splat(bits);
                try self.pushV128(@bitCast(vec));
            },
            .f64x2_splat => {
                const val = self.popF64();
                const bits: u64 = @bitCast(val);
                const vec: @Vector(2, u64) = @splat(bits);
                try self.pushV128(@bitCast(vec));
            },

            // ---- Extract / replace lane ----
            .i8x16_extract_lane_s => {
                const lane = try reader.readByte();
                const vec: @Vector(16, i8) = @bitCast(self.popV128());
                try self.pushI32(@as(i32, vec[lane]));
            },
            .i8x16_extract_lane_u => {
                const lane = try reader.readByte();
                const vec: @Vector(16, u8) = @bitCast(self.popV128());
                try self.push(@as(u64, vec[lane]));
            },
            .i8x16_replace_lane => {
                const lane = try reader.readByte();
                const val: u8 = @truncate(self.pop());
                var vec: @Vector(16, u8) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i16x8_extract_lane_s => {
                const lane = try reader.readByte();
                const vec: @Vector(8, i16) = @bitCast(self.popV128());
                try self.pushI32(@as(i32, vec[lane]));
            },
            .i16x8_extract_lane_u => {
                const lane = try reader.readByte();
                const vec: @Vector(8, u16) = @bitCast(self.popV128());
                try self.push(@as(u64, vec[lane]));
            },
            .i16x8_replace_lane => {
                const lane = try reader.readByte();
                const val: u16 = @truncate(self.pop());
                var vec: @Vector(8, u16) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i32x4_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(4, i32) = @bitCast(self.popV128());
                try self.pushI32(vec[lane]);
            },
            .i32x4_replace_lane => {
                const lane = try reader.readByte();
                const val = self.popI32();
                var vec: @Vector(4, i32) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i64x2_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(2, i64) = @bitCast(self.popV128());
                try self.pushI64(vec[lane]);
            },
            .i64x2_replace_lane => {
                const lane = try reader.readByte();
                const val = self.popI64();
                var vec: @Vector(2, i64) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .f32x4_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(4, u32) = @bitCast(self.popV128());
                try self.pushF32(@bitCast(vec[lane]));
            },
            .f32x4_replace_lane => {
                const lane = try reader.readByte();
                const val: u32 = @bitCast(self.popF32());
                var vec: @Vector(4, u32) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .f64x2_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(2, u64) = @bitCast(self.popV128());
                try self.pushF64(@bitCast(vec[lane]));
            },
            .f64x2_replace_lane => {
                const lane = try reader.readByte();
                const val: u64 = @bitCast(self.popF64());
                var vec: @Vector(2, u64) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },

            // ---- Shuffle / swizzle ----
            .i8x16_shuffle => {
                var lanes: [16]u8 = undefined;
                for (&lanes) |*l| l.* = try reader.readByte();
                const b: @Vector(16, u8) = @bitCast(self.popV128());
                const a: @Vector(16, u8) = @bitCast(self.popV128());
                // Concatenate a ++ b (32 bytes), select by lane indices
                var result: [16]u8 = undefined;
                const a_bytes: [16]u8 = @bitCast(a);
                const b_bytes: [16]u8 = @bitCast(b);
                for (lanes, 0..) |idx, i| {
                    result[i] = if (idx < 16) a_bytes[idx] else b_bytes[idx - 16];
                }
                try self.pushV128(@bitCast(@as(@Vector(16, u8), result)));
            },
            .i8x16_swizzle => {
                const indices: @Vector(16, u8) = @bitCast(self.popV128());
                const vec: [16]u8 = @bitCast(self.popV128());
                var result: [16]u8 = undefined;
                for (0..16) |i| {
                    const idx = indices[i];
                    result[i] = if (idx < 16) vec[idx] else 0;
                }
                try self.pushV128(@bitCast(@as(@Vector(16, u8), result)));
            },

            // ---- Bitwise (36.3) ----
            .v128_not => { const a = self.popV128(); try self.pushV128(~a); },
            .v128_and => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a & b); },
            .v128_andnot => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a & ~b); },
            .v128_or => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a | b); },
            .v128_xor => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a ^ b); },
            .v128_bitselect => {
                const c = self.popV128();
                const b = self.popV128();
                const a = self.popV128();
                try self.pushV128((a & c) | (b & ~c));
            },
            .v128_any_true => {
                const a = self.popV128();
                try self.pushI32(b2i(a != 0));
            },

            // ---- Integer comparison (36.3) ----
            .i8x16_eq => try self.simdCmpOp(i8, 16, .eq),
            .i8x16_ne => try self.simdCmpOp(i8, 16, .ne),
            .i8x16_lt_s => try self.simdCmpOp(i8, 16, .lt),
            .i8x16_lt_u => try self.simdCmpOp(u8, 16, .lt),
            .i8x16_gt_s => try self.simdCmpOp(i8, 16, .gt),
            .i8x16_gt_u => try self.simdCmpOp(u8, 16, .gt),
            .i8x16_le_s => try self.simdCmpOp(i8, 16, .le),
            .i8x16_le_u => try self.simdCmpOp(u8, 16, .le),
            .i8x16_ge_s => try self.simdCmpOp(i8, 16, .ge),
            .i8x16_ge_u => try self.simdCmpOp(u8, 16, .ge),
            .i16x8_eq => try self.simdCmpOp(i16, 8, .eq),
            .i16x8_ne => try self.simdCmpOp(i16, 8, .ne),
            .i16x8_lt_s => try self.simdCmpOp(i16, 8, .lt),
            .i16x8_lt_u => try self.simdCmpOp(u16, 8, .lt),
            .i16x8_gt_s => try self.simdCmpOp(i16, 8, .gt),
            .i16x8_gt_u => try self.simdCmpOp(u16, 8, .gt),
            .i16x8_le_s => try self.simdCmpOp(i16, 8, .le),
            .i16x8_le_u => try self.simdCmpOp(u16, 8, .le),
            .i16x8_ge_s => try self.simdCmpOp(i16, 8, .ge),
            .i16x8_ge_u => try self.simdCmpOp(u16, 8, .ge),
            .i32x4_eq => try self.simdCmpOp(i32, 4, .eq),
            .i32x4_ne => try self.simdCmpOp(i32, 4, .ne),
            .i32x4_lt_s => try self.simdCmpOp(i32, 4, .lt),
            .i32x4_lt_u => try self.simdCmpOp(u32, 4, .lt),
            .i32x4_gt_s => try self.simdCmpOp(i32, 4, .gt),
            .i32x4_gt_u => try self.simdCmpOp(u32, 4, .gt),
            .i32x4_le_s => try self.simdCmpOp(i32, 4, .le),
            .i32x4_le_u => try self.simdCmpOp(u32, 4, .le),
            .i32x4_ge_s => try self.simdCmpOp(i32, 4, .ge),
            .i32x4_ge_u => try self.simdCmpOp(u32, 4, .ge),
            .i64x2_eq => try self.simdCmpOp(i64, 2, .eq),
            .i64x2_ne => try self.simdCmpOp(i64, 2, .ne),
            .i64x2_lt_s => try self.simdCmpOp(i64, 2, .lt),
            .i64x2_gt_s => try self.simdCmpOp(i64, 2, .gt),
            .i64x2_le_s => try self.simdCmpOp(i64, 2, .le),
            .i64x2_ge_s => try self.simdCmpOp(i64, 2, .ge),

            // ---- Integer unary (36.3) ----
            .i8x16_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(16, i8), @bitCast(self.popV128()))))); },
            .i16x8_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(8, i16), @bitCast(self.popV128()))))); },
            .i32x4_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(4, i32), @bitCast(self.popV128()))))); },
            .i64x2_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(2, i64), @bitCast(self.popV128()))))); },
            .i8x16_neg => { const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(16, i8), @splat(@as(i8, 0))) -% a)); },
            .i16x8_neg => { const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(8, i16), @splat(@as(i16, 0))) -% a)); },
            .i32x4_neg => { const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(4, i32), @splat(@as(i32, 0))) -% a)); },
            .i64x2_neg => { const a: @Vector(2, i64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(2, i64), @splat(@as(i64, 0))) -% a)); },
            .i8x16_popcnt => {
                const a: @Vector(16, u8) = @bitCast(self.popV128());
                const counts: @Vector(16, u4) = @popCount(a);
                const widened: @Vector(16, u8) = counts;
                try self.pushV128(@bitCast(widened));
            },
            .i8x16_all_true => try self.simdAllTrue(u8, 16),
            .i16x8_all_true => try self.simdAllTrue(u16, 8),
            .i32x4_all_true => try self.simdAllTrue(u32, 4),
            .i64x2_all_true => try self.simdAllTrue(u64, 2),
            .i8x16_bitmask => try self.simdBitmask(16, 8),
            .i16x8_bitmask => try self.simdBitmask(8, 16),
            .i32x4_bitmask => try self.simdBitmask(4, 32),
            .i64x2_bitmask => try self.simdBitmask(2, 64),

            // ---- Narrowing (36.3) ----
            .i8x16_narrow_i16x8_s => try self.simdNarrow(i8, i16, 8),
            .i8x16_narrow_i16x8_u => try self.simdNarrow(u8, i16, 8),
            .i16x8_narrow_i32x4_s => try self.simdNarrow(i16, i32, 4),
            .i16x8_narrow_i32x4_u => try self.simdNarrow(u16, i32, 4),

            // ---- Extending (36.3) ----
            .i16x8_extend_low_i8x16_s => try self.simdExtend(i16, i8, 8, true),
            .i16x8_extend_high_i8x16_s => try self.simdExtend(i16, i8, 8, false),
            .i16x8_extend_low_i8x16_u => try self.simdExtend(i16, u8, 8, true),
            .i16x8_extend_high_i8x16_u => try self.simdExtend(i16, u8, 8, false),
            .i32x4_extend_low_i16x8_s => try self.simdExtend(i32, i16, 4, true),
            .i32x4_extend_high_i16x8_s => try self.simdExtend(i32, i16, 4, false),
            .i32x4_extend_low_i16x8_u => try self.simdExtend(i32, u16, 4, true),
            .i32x4_extend_high_i16x8_u => try self.simdExtend(i32, u16, 4, false),
            .i64x2_extend_low_i32x4_s => try self.simdExtend(i64, i32, 2, true),
            .i64x2_extend_high_i32x4_s => try self.simdExtend(i64, i32, 2, false),
            .i64x2_extend_low_i32x4_u => try self.simdExtend(i64, u32, 2, true),
            .i64x2_extend_high_i32x4_u => try self.simdExtend(i64, u32, 2, false),

            // ---- Shift (36.3) ----
            .i8x16_shl => try self.simdShift(u8, 16, .shl),
            .i8x16_shr_s => try self.simdShift(i8, 16, .shr),
            .i8x16_shr_u => try self.simdShift(u8, 16, .shr),
            .i16x8_shl => try self.simdShift(u16, 8, .shl),
            .i16x8_shr_s => try self.simdShift(i16, 8, .shr),
            .i16x8_shr_u => try self.simdShift(u16, 8, .shr),
            .i32x4_shl => try self.simdShift(u32, 4, .shl),
            .i32x4_shr_s => try self.simdShift(i32, 4, .shr),
            .i32x4_shr_u => try self.simdShift(u32, 4, .shr),
            .i64x2_shl => try self.simdShift(u64, 2, .shl),
            .i64x2_shr_s => try self.simdShift(i64, 2, .shr),
            .i64x2_shr_u => try self.simdShift(u64, 2, .shr),

            // ---- Wrapping arithmetic (36.3) ----
            .i8x16_add => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i8x16_sub => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i16x8_add => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i16x8_sub => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i16x8_mul => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },
            .i32x4_add => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i32x4_sub => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i32x4_mul => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },
            .i64x2_add => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i64x2_sub => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i64x2_mul => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },

            // ---- Saturating arithmetic (36.3) ----
            .i8x16_add_sat_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i8x16_add_sat_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i8x16_sub_sat_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i8x16_sub_sat_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i16x8_add_sat_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i16x8_add_sat_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i16x8_sub_sat_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i16x8_sub_sat_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },

            // ---- Min / max (36.3) ----
            .i8x16_min_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i8x16_min_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i8x16_max_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i8x16_max_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i16x8_min_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i16x8_min_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i16x8_max_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i16x8_max_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i32x4_min_s => { const b: @Vector(4, i32) = @bitCast(self.popV128()); const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i32x4_min_u => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i32x4_max_s => { const b: @Vector(4, i32) = @bitCast(self.popV128()); const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i32x4_max_u => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },

            // ---- Unsigned rounding average (36.3) ----
            .i8x16_avgr_u => {
                const b: [16]u8 = @bitCast(self.popV128());
                const a: [16]u8 = @bitCast(self.popV128());
                var r: [16]u8 = undefined;
                inline for (0..16) |i| r[i] = @truncate((@as(u16, a[i]) + @as(u16, b[i]) + 1) / 2);
                try self.pushV128(@bitCast(r));
            },
            .i16x8_avgr_u => {
                const b: [8]u16 = @bitCast(self.popV128());
                const a: [8]u16 = @bitCast(self.popV128());
                var r: [8]u16 = undefined;
                inline for (0..8) |i| r[i] = @truncate((@as(u32, a[i]) + @as(u32, b[i]) + 1) / 2);
                try self.pushV128(@bitCast(r));
            },

            // ---- Extended pairwise addition (36.3) ----
            .i16x8_extadd_pairwise_i8x16_s => try self.simdExtAddPairwise(i8, i16),
            .i16x8_extadd_pairwise_i8x16_u => try self.simdExtAddPairwise(u8, u16),
            .i32x4_extadd_pairwise_i16x8_s => try self.simdExtAddPairwise(i16, i32),
            .i32x4_extadd_pairwise_i16x8_u => try self.simdExtAddPairwise(u16, u32),

            // ---- Extended multiply (36.3) ----
            .i16x8_extmul_low_i8x16_s => try self.simdExtMul(i8, i16, 8, true),
            .i16x8_extmul_high_i8x16_s => try self.simdExtMul(i8, i16, 8, false),
            .i16x8_extmul_low_i8x16_u => try self.simdExtMul(u8, u16, 8, true),
            .i16x8_extmul_high_i8x16_u => try self.simdExtMul(u8, u16, 8, false),
            .i32x4_extmul_low_i16x8_s => try self.simdExtMul(i16, i32, 4, true),
            .i32x4_extmul_high_i16x8_s => try self.simdExtMul(i16, i32, 4, false),
            .i32x4_extmul_low_i16x8_u => try self.simdExtMul(u16, u32, 4, true),
            .i32x4_extmul_high_i16x8_u => try self.simdExtMul(u16, u32, 4, false),
            .i64x2_extmul_low_i32x4_s => try self.simdExtMul(i32, i64, 2, true),
            .i64x2_extmul_high_i32x4_s => try self.simdExtMul(i32, i64, 2, false),
            .i64x2_extmul_low_i32x4_u => try self.simdExtMul(u32, u64, 2, true),
            .i64x2_extmul_high_i32x4_u => try self.simdExtMul(u32, u64, 2, false),

            // ---- Dot product (36.3) ----
            .i32x4_dot_i16x8_s => {
                const b: [8]i16 = @bitCast(self.popV128());
                const a: [8]i16 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| r[i] = @as(i32, a[i * 2]) * @as(i32, b[i * 2]) + @as(i32, a[i * 2 + 1]) * @as(i32, b[i * 2 + 1]);
                try self.pushV128(@bitCast(r));
            },

            // ---- Q15 saturating multiply (36.3) ----
            .i16x8_q15mulr_sat_s => {
                const b: [8]i16 = @bitCast(self.popV128());
                const a: [8]i16 = @bitCast(self.popV128());
                var r: [8]i16 = undefined;
                inline for (0..8) |i| {
                    const product: i32 = @as(i32, a[i]) * @as(i32, b[i]);
                    r[i] = @intCast(std.math.clamp((product + 0x4000) >> 15, -32768, 32767));
                }
                try self.pushV128(@bitCast(r));
            },

            // ---- Float comparison (36.4) ----
            .f32x4_eq => try self.simdCmpOp(f32, 4, .eq),
            .f32x4_ne => try self.simdCmpOp(f32, 4, .ne),
            .f32x4_lt => try self.simdCmpOp(f32, 4, .lt),
            .f32x4_gt => try self.simdCmpOp(f32, 4, .gt),
            .f32x4_le => try self.simdCmpOp(f32, 4, .le),
            .f32x4_ge => try self.simdCmpOp(f32, 4, .ge),
            .f64x2_eq => try self.simdCmpOp(f64, 2, .eq),
            .f64x2_ne => try self.simdCmpOp(f64, 2, .ne),
            .f64x2_lt => try self.simdCmpOp(f64, 2, .lt),
            .f64x2_gt => try self.simdCmpOp(f64, 2, .gt),
            .f64x2_le => try self.simdCmpOp(f64, 2, .le),
            .f64x2_ge => try self.simdCmpOp(f64, 2, .ge),

            // ---- Float unary (36.4) ----
            .f32x4_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(4, f32), @bitCast(self.popV128()))))); },
            .f64x2_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(2, f64), @bitCast(self.popV128()))))); },
            .f32x4_neg => {
                const a_bits: @Vector(4, u32) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(a_bits ^ @as(@Vector(4, u32), @splat(@as(u32, 0x80000000)))));
            },
            .f64x2_neg => {
                const a_bits: @Vector(2, u64) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(a_bits ^ @as(@Vector(2, u64), @splat(@as(u64, 0x8000000000000000)))));
            },
            .f32x4_sqrt => { try self.pushV128(@bitCast(@sqrt(@as(@Vector(4, f32), @bitCast(self.popV128()))))); },
            .f64x2_sqrt => { try self.pushV128(@bitCast(@sqrt(@as(@Vector(2, f64), @bitCast(self.popV128()))))); },

            // ---- Float arithmetic (36.4) ----
            .f32x4_add => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a + b)); },
            .f32x4_sub => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a - b)); },
            .f32x4_mul => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a * b)); },
            .f32x4_div => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a / b)); },
            .f64x2_add => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a + b)); },
            .f64x2_sub => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a - b)); },
            .f64x2_mul => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a * b)); },
            .f64x2_div => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a / b)); },

            // ---- Float min/max (36.4) — IEEE 754 semantics with NaN propagation ----
            .f32x4_min => { try self.simdMinMax(f32, 4, .min); },
            .f32x4_max => { try self.simdMinMax(f32, 4, .max); },
            .f64x2_min => { try self.simdMinMax(f64, 2, .min); },
            .f64x2_max => { try self.simdMinMax(f64, 2, .max); },

            // ---- Float pseudo min/max (36.4) — simple comparison, no NaN propagation ----
            .f32x4_pmin => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f32, b < a, b, a))); },
            .f32x4_pmax => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f32, a < b, b, a))); },
            .f64x2_pmin => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f64, b < a, b, a))); },
            .f64x2_pmax => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f64, a < b, b, a))); },

            // ---- Float rounding (36.4) ----
            .f32x4_ceil => try self.simdRound(f32, 4, .ceil),
            .f32x4_floor => try self.simdRound(f32, 4, .floor),
            .f32x4_trunc => try self.simdRound(f32, 4, .trunc_fn),
            .f32x4_nearest => try self.simdRound(f32, 4, .nearest),
            .f64x2_ceil => try self.simdRound(f64, 2, .ceil),
            .f64x2_floor => try self.simdRound(f64, 2, .floor),
            .f64x2_trunc => try self.simdRound(f64, 2, .trunc_fn),
            .f64x2_nearest => try self.simdRound(f64, 2, .nearest),

            // ---- Float conversion (36.4) ----
            .i32x4_trunc_sat_f32x4_s => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(i32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f32x4_u => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]u32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(u32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_convert_i32x4_s => {
                const a: [4]i32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_convert_i32x4_u => {
                const a: [4]u32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f64x2_s_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]i32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(i32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f64x2_u_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]u32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(u32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_convert_low_i32x4_s => {
                const a: [4]i32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_convert_low_i32x4_u => {
                const a: [4]u32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_demote_f64x2_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]f32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = @floatCast(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_promote_low_f32x4 => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatCast(a[i]);
                try self.pushV128(@bitCast(r));
            },

            _ => return error.Trap,
        }
    }

    // SIMD helper: extending load (e.g. load 8 i8 values, extend to 8 i16 values)
    fn simdExtendLoad(
        self: *Vm,
        comptime NarrowT: type,
        comptime WideT: type,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        const N = 16 / @sizeOf(WideT); // number of lanes
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        // Read N narrow values
        const byte_count = N * @sizeOf(NarrowT);
        const effective = @as(u33, offset) + @as(u33, base);
        if (effective + byte_count > m.data.items.len) return error.OutOfBoundsMemoryAccess;
        var narrow: [N]NarrowT = undefined;
        for (&narrow, 0..) |*n, i| {
            const ptr: *const [@sizeOf(NarrowT)]u8 = @ptrCast(&m.data.items[effective + i * @sizeOf(NarrowT)]);
            n.* = std.mem.readInt(NarrowT, ptr, .little);
        }
        // Extend to wide
        var wide: @Vector(N, WideT) = undefined;
        for (0..N) |i| {
            wide[i] = @as(WideT, narrow[i]);
        }
        try self.pushV128(@bitCast(wide));
    }

    // SIMD helper: load a value from memory into a specific lane of v128
    fn simdLoadLane(
        self: *Vm,
        comptime T: type,
        comptime N: comptime_int,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const lane = try reader.readByte();
        var vec: @Vector(N, T) = @bitCast(self.popV128());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        const val = m.read(T, offset, base) catch return error.OutOfBoundsMemoryAccess;
        vec[lane] = val;
        try self.pushV128(@bitCast(vec));
    }

    // SIMD helper: store a specific lane of v128 to memory
    fn simdStoreLane(
        self: *Vm,
        comptime T: type,
        comptime N: comptime_int,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        _ = try reader.readU32(); // alignment
        const offset = try reader.readU32();
        const lane = try reader.readByte();
        const vec: @Vector(N, T) = @bitCast(self.popV128());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(T, offset, base, vec[lane]) catch return error.OutOfBoundsMemoryAccess;
    }

    // SIMD helper: lane-wise comparison producing all-ones/all-zeros result
    fn simdCmpOp(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { eq, ne, lt, gt, le, ge }) WasmError!void {
        const VT = @Vector(N, T);
        const b: VT = @bitCast(self.popV128());
        const a: VT = @bitCast(self.popV128());
        const mask = switch (op) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .gt => a > b,
            .le => a <= b,
            .ge => a >= b,
        };
        const ResultT = std.meta.Int(.signed, @bitSizeOf(T));
        try self.pushV128(@bitCast(@select(ResultT, mask, @as(@Vector(N, ResultT), @splat(@as(ResultT, -1))), @as(@Vector(N, ResultT), @splat(@as(ResultT, 0))))));
    }

    // SIMD helper: shift by scalar amount (mod lane_bits)
    fn simdShift(self: *Vm, comptime T: type, comptime N: comptime_int, comptime dir: enum { shl, shr }) WasmError!void {
        const ShiftT = std.math.Log2Int(T);
        const shift: ShiftT = @truncate(@as(u32, @bitCast(self.popI32())));
        const vec: @Vector(N, T) = @bitCast(self.popV128());
        try self.pushV128(@bitCast(switch (dir) {
            .shl => vec << @splat(shift),
            .shr => vec >> @splat(shift),
        }));
    }

    // SIMD helper: narrowing with saturation (two wide vectors → one narrow vector)
    fn simdNarrow(self: *Vm, comptime DstT: type, comptime SrcT: type, comptime SrcN: comptime_int) WasmError!void {
        const DstN = SrcN * 2;
        const b: [SrcN]SrcT = @bitCast(self.popV128());
        const a: [SrcN]SrcT = @bitCast(self.popV128());
        const min_val: SrcT = std.math.minInt(DstT);
        const max_val: SrcT = std.math.maxInt(DstT);
        var result: [DstN]DstT = undefined;
        inline for (0..SrcN) |i| result[i] = @intCast(std.math.clamp(a[i], min_val, max_val));
        inline for (0..SrcN) |i| result[SrcN + i] = @intCast(std.math.clamp(b[i], min_val, max_val));
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extend half of narrow vector to wider lanes
    fn simdExtend(self: *Vm, comptime DstT: type, comptime SrcT: type, comptime DstN: comptime_int, comptime low: bool) WasmError!void {
        const SrcN = DstN * 2;
        const src: [SrcN]SrcT = @bitCast(self.popV128());
        const offset = if (low) 0 else DstN;
        var result: [DstN]DstT = undefined;
        inline for (0..DstN) |i| result[i] = src[offset + i];
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extended (widening) multiply of half-width lanes
    fn simdExtMul(self: *Vm, comptime NarrowT: type, comptime WideT: type, comptime N: comptime_int, comptime low: bool) WasmError!void {
        const SrcN = N * 2;
        const b: [SrcN]NarrowT = @bitCast(self.popV128());
        const a: [SrcN]NarrowT = @bitCast(self.popV128());
        const offset = if (low) 0 else N;
        var result: [N]WideT = undefined;
        inline for (0..N) |i| result[i] = @as(WideT, a[offset + i]) * @as(WideT, b[offset + i]);
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extended pairwise addition (adjacent lane pairs summed into wider lanes)
    fn simdExtAddPairwise(self: *Vm, comptime NarrowT: type, comptime WideT: type) WasmError!void {
        const WideN = 16 / @sizeOf(WideT);
        const a: [WideN * 2]NarrowT = @bitCast(self.popV128());
        var result: [WideN]WideT = undefined;
        inline for (0..WideN) |i| result[i] = @as(WideT, a[i * 2]) + @as(WideT, a[i * 2 + 1]);
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: all_true — 1 if all lanes non-zero
    fn simdAllTrue(self: *Vm, comptime T: type, comptime N: comptime_int) WasmError!void {
        const a: @Vector(N, T) = @bitCast(self.popV128());
        try self.pushI32(b2i(@reduce(.And, a != @as(@Vector(N, T), @splat(@as(T, 0))))));
    }

    // SIMD helper: bitmask — extract high bit of each lane into i32
    fn simdBitmask(self: *Vm, comptime N: comptime_int, comptime bits: comptime_int) WasmError!void {
        const T = std.meta.Int(.signed, bits);
        const a: [N]T = @bitCast(self.popV128());
        var mask: u32 = 0;
        inline for (0..N) |i| {
            if (a[i] < 0) mask |= @as(u32, 1) << @as(u5, i);
        }
        try self.pushI32(@bitCast(mask));
    }

    // SIMD helper: IEEE 754 min/max with NaN propagation and -0/+0 handling
    fn simdMinMax(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { min, max }) WasmError!void {
        const b: [N]T = @bitCast(self.popV128());
        const a: [N]T = @bitCast(self.popV128());
        var r: [N]T = undefined;
        inline for (0..N) |i| {
            r[i] = switch (op) {
                .min => wasmMin(T, a[i], b[i]),
                .max => wasmMax(T, a[i], b[i]),
            };
        }
        try self.pushV128(@bitCast(r));
    }

    fn simdRound(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { ceil, floor, trunc_fn, nearest }) WasmError!void {
        var a: [N]T = @bitCast(self.popV128());
        inline for (0..N) |i| {
            a[i] = switch (op) {
                .ceil => @ceil(a[i]),
                .floor => @floor(a[i]),
                .trunc_fn => @trunc(a[i]),
                .nearest => roundToEven(T, a[i]),
            };
        }
        try self.pushV128(@bitCast(a));
    }

    // ================================================================
    // Call helpers
    // ================================================================

    fn doCall(self: *Vm, instance: *Instance, func_idx: u32, reader: *Reader) WasmError!void {
        const func_ptr = try instance.getFuncPtr(func_idx);
        try self.doCallDirect(instance, func_ptr, reader);
    }

    fn doCallDirect(self: *Vm, instance: *Instance, func_ptr: *store_mod.Function, reader: *Reader) WasmError!void {
        switch (func_ptr.subtype) {
            .wasm_function => |*wf| {
                const param_count = func_ptr.params.len;
                const locals_start = self.op_ptr - param_count;

                // Zero-initialize locals
                for (0..wf.locals_count) |_| try self.push(0);

                // Lazy branch table computation
                if (wf.branch_table == null) {
                    wf.branch_table = computeBranchTable(self.alloc, wf.code) catch null;
                }
                const saved_bt = self.current_branch_table;
                self.current_branch_table = wf.branch_table;

                try self.pushFrame(.{
                    .locals_start = locals_start,
                    .locals_count = param_count + wf.locals_count,
                    .return_arity = func_ptr.results.len,
                    .op_stack_base = locals_start,
                    .label_stack_base = self.label_ptr,
                    .return_reader = reader.*,
                    .instance = instance,
                });

                var body_reader = Reader.init(wf.code);
                try self.pushLabel(.{
                    .arity = func_ptr.results.len,
                    .op_stack_base = self.op_ptr,
                    .target = .{ .forward = body_reader },
                });

                const callee_inst: *Instance = @ptrCast(@alignCast(wf.instance));
                try self.execute(&body_reader, callee_inst);

                // Move results to correct position
                const frame = self.popFrame();
                self.current_branch_table = saved_bt;
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
        // Sign/zero extend to ResultT then push.
        // Same-size: bitCast (e.g. i32→u32). Different-size: intCast (e.g. i8→i32 sign-ext).
        const result: ResultT = if (@bitSizeOf(LoadT) == @bitSizeOf(ResultT))
            @bitCast(val)
        else
            @intCast(val);
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
        self.op_stack[self.op_ptr] = @as(u128, val);
        self.op_ptr += 1;
    }

    fn pop(self: *Vm) u64 {
        self.op_ptr -= 1;
        return @truncate(self.op_stack[self.op_ptr]);
    }

    fn peek(self: *Vm) u64 {
        return @truncate(self.op_stack[self.op_ptr - 1]);
    }

    fn pushV128(self: *Vm, val: u128) WasmError!void {
        if (self.op_ptr >= OPERAND_STACK_SIZE) return error.StackOverflow;
        self.op_stack[self.op_ptr] = val;
        self.op_ptr += 1;
    }

    fn popV128(self: *Vm) u128 {
        self.op_ptr -= 1;
        return self.op_stack[self.op_ptr];
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
            .simd_prefix => try skipSimdImmediates(reader),
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
            .simd_prefix => try skipSimdImmediates(reader),
            else => {},
        }
    }
    return found_else;
}

/// Skip SIMD instruction immediates when scanning bytecode (for skipToEnd/findElseOrEnd).
fn skipSimdImmediates(reader: *Reader) !void {
    const sub = try reader.readU32();
    switch (sub) {
        // Memory ops: memarg (align u32 + offset u32)
        0x00...0x0B, 0x5C, 0x5D => {
            _ = try reader.readU32(); // align
            _ = try reader.readU32(); // offset
        },
        // v128.const: 16 raw bytes
        0x0C => _ = try reader.readBytes(16),
        // i8x16.shuffle: 16 lane indices
        0x0D => _ = try reader.readBytes(16),
        // Extract/replace lane: 1 byte lane index
        0x15...0x22 => _ = try reader.readByte(),
        // Lane load/store: memarg + 1 byte lane index
        0x54...0x5B => {
            _ = try reader.readU32(); // align
            _ = try reader.readU32(); // offset
            _ = try reader.readByte(); // lane
        },
        // All other ops: no immediates
        else => {},
    }
}

/// Wasm nearest (round-to-even).
fn wasmNearest(comptime T: type, val: T) T {
    return roundToEven(T, val);
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

/// IEEE 754 roundToIntegralTiesToEven (Wasm nearest).
fn roundToEven(comptime T: type, x: T) T {
    if (math.isNan(x) or math.isInf(x) or x == 0) return x;
    const magic: T = switch (T) {
        f32 => 8388608.0, // 2^23
        f64 => 4503599627370496.0, // 2^52
        else => unreachable,
    };
    const ax = @abs(x);
    if (ax >= magic) return x;
    if (x > 0) return (x + magic) - magic;
    return (x - magic) + magic;
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

test "VM — memory sum_range (loop branch)" {
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

    // Store values: mem[100]=10, mem[104]=20, mem[108]=30
    var s1 = [_]u64{ 100, 10 };
    var s2 = [_]u64{ 104, 20 };
    var s3 = [_]u64{ 108, 30 };
    var no_results = [_]u64{};
    try vm.invoke(&inst, "store", &s1, &no_results);
    try vm.invoke(&inst, "store", &s2, &no_results);
    try vm.invoke(&inst, "store", &s3, &no_results);

    // sum_range(100, 3) should return 60
    var sum_args = [_]u64{ 100, 3 };
    var sum_results = [_]u64{0};
    try vm.invoke(&inst, "sum_range", &sum_args, &sum_results);
    try testing.expectEqual(@as(u64, 60), sum_results[0]);
}

test "VM — table indirect call" {
    const wasm = try readTestFile(testing.allocator, "05_table_indirect_call.wasm");
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

    // dispatch(0, 10, 20) — calls function at table[0]
    var args0 = [_]u64{ 0, 10, 20 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "dispatch", &args0, &results);
    const r0 = @as(u32, @truncate(results[0]));

    // dispatch(1, 10, 20) — calls function at table[1]
    var args1 = [_]u64{ 1, 10, 20 };
    try vm.invoke(&inst, "dispatch", &args1, &results);
    const r1 = @as(u32, @truncate(results[0]));

    // Two different functions should return different results (add vs sub)
    try testing.expect(r0 != r1);
}

test "VM — multi-value return" {
    const wasm = try readTestFile(testing.allocator, "08_multi_value.wasm");
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

    // swap(10, 20) should return (20, 10)
    var args = [_]u64{ 10, 20 };
    var results = [_]u64{ 0, 0 };
    try vm.invoke(&inst, "swap", &args, &results);
    try testing.expectEqual(@as(u64, 20), results[0]);
    try testing.expectEqual(@as(u64, 10), results[1]);
}

test "VM — host function imports" {
    const alloc = testing.allocator;
    const wasm = try readTestFile(alloc, "04_imports.wasm");
    defer alloc.free(wasm);

    var mod = Module.init(alloc, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(alloc);
    defer store.deinit();

    // Stub host functions — pop args from the Vm operand stack
    const stub_i32 = struct {
        fn f(ctx: *anyopaque, _: usize) anyerror!void {
            const vm_inner: *Vm = @ptrCast(@alignCast(ctx));
            _ = vm_inner.popOperand(); // value
        }
    }.f;

    const stub_i32_i32 = struct {
        fn f(ctx: *anyopaque, _: usize) anyerror!void {
            const vm_inner: *Vm = @ptrCast(@alignCast(ctx));
            _ = vm_inner.popOperand(); // len
            _ = vm_inner.popOperand(); // offset
        }
    }.f;

    try store.exposeHostFunction("env", "print_i32", &stub_i32, 0,
        &.{.i32}, &.{});
    try store.exposeHostFunction("env", "print_str", &stub_i32_i32, 0,
        &.{ .i32, .i32 }, &.{});

    var inst = Instance.init(alloc, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm_inst = Vm.init(alloc);

    // greet() should succeed (calls print_str host function)
    var no_args = [_]u64{};
    var no_results = [_]u64{};
    try vm_inst.invoke(&inst, "greet", &no_args, &no_results);

    // compute_and_print(10, 20) should succeed
    var compute_args = [_]u64{ 10, 20 };
    try vm_inst.invoke(&inst, "compute_and_print", &compute_args, &no_results);
}

test "VM — fib(20) = 6765" {
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
    var args = [_]u64{20};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 6765), results[0]);
}

// --- Conformance tests ---

test "Conformance — block control flow" {
    const wasm = try readTestFile(testing.allocator, "conformance/block.wasm");
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
    var results = [_]u64{0};

    // block_result: returns 42
    try vm.invoke(&inst, "block_result", &.{}, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // nested_br: param=0 → falls through inner block, drop, return 20
    var args0 = [_]u64{0};
    try vm.invoke(&inst, "nested_br", &args0, &results);
    try testing.expectEqual(@as(u64, 20), results[0]);

    // nested_br: param=1 → br_if 1 jumps to outer with value 99
    var args1 = [_]u64{1};
    try vm.invoke(&inst, "nested_br", &args1, &results);
    try testing.expectEqual(@as(u64, 99), results[0]);

    // loop_sum: sum(10) = 55
    var args10 = [_]u64{10};
    try vm.invoke(&inst, "loop_sum", &args10, &results);
    try testing.expectEqual(@as(u64, 55), results[0]);

    // if_else: true → 1, false → 0
    try vm.invoke(&inst, "if_else", &args1, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    try vm.invoke(&inst, "if_else", &args0, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}

test "Conformance — i32 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/i32_arith.wasm");
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
    var results = [_]u64{0};

    // add(7, 3) = 10
    var args_add = [_]u64{ 7, 3 };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(u64, 10), results[0]);

    // sub(10, 4) = 6
    var args_sub = [_]u64{ 10, 4 };
    try vm.invoke(&inst, "sub", &args_sub, &results);
    try testing.expectEqual(@as(u64, 6), results[0]);

    // mul(6, 7) = 42
    var args_mul = [_]u64{ 6, 7 };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // div_s(-10, 3) = -3 (signed)
    var args_divs = [_]u64{ @bitCast(@as(i64, -10)), 3 };
    try vm.invoke(&inst, "div_s", &args_divs, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), @as(u32, @truncate(results[0])));

    // div_u(10, 3) = 3 (unsigned)
    var args_divu = [_]u64{ 10, 3 };
    try vm.invoke(&inst, "div_u", &args_divu, &results);
    try testing.expectEqual(@as(u64, 3), results[0]);

    // rem_s(10, 3) = 1
    var args_rem = [_]u64{ 10, 3 };
    try vm.invoke(&inst, "rem_s", &args_rem, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // clz(1) = 31
    var args_clz = [_]u64{1};
    try vm.invoke(&inst, "clz", &args_clz, &results);
    try testing.expectEqual(@as(u64, 31), results[0]);

    // ctz(0x80) = 7
    var args_ctz = [_]u64{0x80};
    try vm.invoke(&inst, "ctz", &args_ctz, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);

    // popcnt(0xFF) = 8
    var args_pop = [_]u64{0xFF};
    try vm.invoke(&inst, "popcnt", &args_pop, &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // rotl(0x80000001, 1) = 0x00000003
    var args_rotl = [_]u64{ 0x80000001, 1 };
    try vm.invoke(&inst, "rotl", &args_rotl, &results);
    try testing.expectEqual(@as(u64, 0x00000003), results[0]);

    // rotr(0x80000001, 1) = 0xC0000000
    var args_rotr = [_]u64{ 0x80000001, 1 };
    try vm.invoke(&inst, "rotr", &args_rotr, &results);
    try testing.expectEqual(@as(u64, 0xC0000000), results[0]);
}

test "Conformance — i64 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/i64_arith.wasm");
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
    var results = [_]u64{0};

    // add
    var args_add = [_]u64{ 100, 200 };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(u64, 300), results[0]);

    // sub
    var args_sub = [_]u64{ 500, 200 };
    try vm.invoke(&inst, "sub", &args_sub, &results);
    try testing.expectEqual(@as(u64, 300), results[0]);

    // mul
    var args_mul = [_]u64{ 1000000, 1000000 };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(u64, 1000000000000), results[0]);

    // div_s(-100, 3) = -33
    var args_divs = [_]u64{@bitCast(@as(i64, -100)), 3};
    try vm.invoke(&inst, "div_s", &args_divs, &results);
    try testing.expectEqual(@as(i64, -33), @as(i64, @bitCast(results[0])));

    // clz(1) = 63
    var args_clz = [_]u64{1};
    try vm.invoke(&inst, "clz", &args_clz, &results);
    try testing.expectEqual(@as(u64, 63), results[0]);

    // popcnt(0xFF) = 8
    var args_pop = [_]u64{0xFF};
    try vm.invoke(&inst, "popcnt", &args_pop, &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // eqz(0) = 1, eqz(5) = 0
    var args_eqz0 = [_]u64{0};
    try vm.invoke(&inst, "eqz", &args_eqz0, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    var args_eqz5 = [_]u64{5};
    try vm.invoke(&inst, "eqz", &args_eqz5, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}

test "Conformance — f64 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/f64_arith.wasm");
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
    var results = [_]u64{0};

    // add(1.5, 2.5) = 4.0
    var args_add = [_]u64{ @bitCast(@as(f64, 1.5)), @bitCast(@as(f64, 2.5)) };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(results[0])));

    // mul(3.0, 4.0) = 12.0
    var args_mul = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 4.0)) };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(f64, 12.0), @as(f64, @bitCast(results[0])));

    // sqrt(9.0) = 3.0
    var args_sqrt = [_]u64{@bitCast(@as(f64, 9.0))};
    try vm.invoke(&inst, "sqrt", &args_sqrt, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // min(3.0, 5.0) = 3.0
    var args_min = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 5.0)) };
    try vm.invoke(&inst, "min", &args_min, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // max(3.0, 5.0) = 5.0
    var args_max = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 5.0)) };
    try vm.invoke(&inst, "max", &args_max, &results);
    try testing.expectEqual(@as(f64, 5.0), @as(f64, @bitCast(results[0])));

    // floor(3.7) = 3.0
    var args_floor = [_]u64{@bitCast(@as(f64, 3.7))};
    try vm.invoke(&inst, "floor", &args_floor, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // ceil(3.2) = 4.0
    var args_ceil = [_]u64{@bitCast(@as(f64, 3.2))};
    try vm.invoke(&inst, "ceil", &args_ceil, &results);
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(results[0])));

    // abs(-5.0) = 5.0
    var args_abs = [_]u64{@bitCast(@as(f64, -5.0))};
    try vm.invoke(&inst, "abs", &args_abs, &results);
    try testing.expectEqual(@as(f64, 5.0), @as(f64, @bitCast(results[0])));

    // neg(5.0) = -5.0
    var args_neg = [_]u64{@bitCast(@as(f64, 5.0))};
    try vm.invoke(&inst, "neg", &args_neg, &results);
    try testing.expectEqual(@as(f64, -5.0), @as(f64, @bitCast(results[0])));
}

test "Conformance — type conversions" {
    const wasm = try readTestFile(testing.allocator, "conformance/conversions.wasm");
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
    var results = [_]u64{0};

    // i64_extend_i32_s(-1) = -1 as i64
    var args_ext_s = [_]u64{@bitCast(@as(i64, -1))};
    try vm.invoke(&inst, "i64_extend_i32_s", &args_ext_s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));

    // i64_extend_i32_u(0xFFFFFFFF) = 0xFFFFFFFF as u64
    var args_ext_u = [_]u64{0xFFFFFFFF};
    try vm.invoke(&inst, "i64_extend_i32_u", &args_ext_u, &results);
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), results[0]);

    // i32_wrap_i64(0x100000042) = 0x42
    var args_wrap = [_]u64{0x100000042};
    try vm.invoke(&inst, "i32_wrap_i64", &args_wrap, &results);
    try testing.expectEqual(@as(u64, 0x42), results[0]);

    // f64_convert_i32_s(-42) = -42.0
    var args_cvt = [_]u64{@bitCast(@as(i64, -42))};
    try vm.invoke(&inst, "f64_convert_i32_s", &args_cvt, &results);
    try testing.expectEqual(@as(f64, -42.0), @as(f64, @bitCast(results[0])));

    // i32_trunc_f64_s(3.9) = 3
    var args_trunc = [_]u64{@bitCast(@as(f64, 3.9))};
    try vm.invoke(&inst, "i32_trunc_f64_s", &args_trunc, &results);
    try testing.expectEqual(@as(u64, 3), results[0]);

    // f32_reinterpret_i32(0x40490FDB) ≈ pi
    var args_reint = [_]u64{0x40490FDB};
    try vm.invoke(&inst, "f32_reinterpret_i32", &args_reint, &results);
    const f32_val: f32 = @bitCast(@as(u32, @truncate(results[0])));
    try testing.expect(@abs(f32_val - 3.14159265) < 0.001);
}

test "Conformance — sign extension (Wasm 2.0)" {
    const wasm = try readTestFile(testing.allocator, "conformance/sign_extension.wasm");
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
    var results = [_]u64{0};

    // i32_extend8_s(0x80) = -128 (sign-extend from bit 7)
    var args_8s = [_]u64{0x80};
    try vm.invoke(&inst, "i32_extend8_s", &args_8s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -128))), @as(u32, @truncate(results[0])));

    // i32_extend8_s(0x7F) = 127
    var args_7f = [_]u64{0x7F};
    try vm.invoke(&inst, "i32_extend8_s", &args_7f, &results);
    try testing.expectEqual(@as(u64, 127), results[0]);

    // i32_extend16_s(0x8000) = -32768
    var args_16s = [_]u64{0x8000};
    try vm.invoke(&inst, "i32_extend16_s", &args_16s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -32768))), @as(u32, @truncate(results[0])));

    // i64_extend8_s(0xFF) = -1
    var args_i64_8s = [_]u64{0xFF};
    try vm.invoke(&inst, "i64_extend8_s", &args_i64_8s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));

    // i64_extend32_s(0xFFFFFFFF) = -1
    var args_i64_32s = [_]u64{0xFFFFFFFF};
    try vm.invoke(&inst, "i64_extend32_s", &args_i64_32s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));
}

test "Conformance — memory operations" {
    const wasm = try readTestFile(testing.allocator, "conformance/memory_ops.wasm");
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
    var results = [_]u64{0};

    // i32 store+load
    var args_i32 = [_]u64{ 0, 12345 };
    try vm.invoke(&inst, "i32_store_load", &args_i32, &results);
    try testing.expectEqual(@as(u64, 12345), results[0]);

    // i64 store+load
    var args_i64 = [_]u64{ 8, 0xDEADBEEFCAFE };
    try vm.invoke(&inst, "i64_store_load", &args_i64, &results);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), results[0]);

    // i32.store8 + i32.load8_u: 0xFF → 255
    var args_8u = [_]u64{ 16, 0xFF };
    try vm.invoke(&inst, "i32_store8_load8_u", &args_8u, &results);
    try testing.expectEqual(@as(u64, 255), results[0]);

    // i32.store8 + i32.load8_s: 0xFF → -1 (sign-extended)
    var args_8s = [_]u64{ 17, 0xFF };
    try vm.invoke(&inst, "i32_store8_load8_s", &args_8s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), @as(u32, @truncate(results[0])));

    // memory_size = 1 (one page)
    try vm.invoke(&inst, "memory_size", &.{}, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // memory_grow(2) returns old size 1, new size 3
    var args_grow = [_]u64{2};
    try vm.invoke(&inst, "memory_grow", &args_grow, &results);
    try testing.expectEqual(@as(u64, 1), results[0]); // old size
    try vm.invoke(&inst, "memory_size", &.{}, &results);
    try testing.expectEqual(@as(u64, 3), results[0]); // new size
}

test "Conformance — bulk memory (Wasm 2.0)" {
    const wasm = try readTestFile(testing.allocator, "conformance/bulk_memory.wasm");
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
    var results = [_]u64{0};

    // memory.fill: fill 4 bytes at offset 0 with value 0xAB
    var args_fill = [_]u64{ 0, 0xAB, 4 };
    try vm.invoke(&inst, "memory_fill", &args_fill, &.{});

    // verify: load i32 at offset 0 = 0xABABABAB
    var args_load = [_]u64{0};
    try vm.invoke(&inst, "load_i32", &args_load, &results);
    try testing.expectEqual(@as(u64, 0xABABABAB), results[0]);

    // store at offset 16: 0xDEADBEEF
    var args_store = [_]u64{ 16, 0xDEADBEEF };
    try vm.invoke(&inst, "store_i32", &args_store, &.{});

    // memory.copy: copy 4 bytes from offset 16 to offset 32
    var args_copy = [_]u64{ 32, 16, 4 };
    try vm.invoke(&inst, "memory_copy", &args_copy, &.{});

    // verify: load i32 at offset 32 = 0xDEADBEEF
    var args_load32 = [_]u64{32};
    try vm.invoke(&inst, "load_i32", &args_load32, &results);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), results[0]);
}

test "Conformance — SIMD basic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_basic.wasm");
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
    var results = [_]u64{0};
    const no_args = [_]u64{};

    // v128.const + i32x4.extract_lane 0 = 42
    try vm.invoke(&inst, "const_extract", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // v128.const + i32x4.extract_lane 2 = 30
    try vm.invoke(&inst, "const_extract_lane2", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 30), results[0]);

    // i32x4.splat(7) + extract_lane 0 = 7
    var args_splat = [_]u64{7};
    try vm.invoke(&inst, "splat_i32", &args_splat, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);

    // i8x16.splat(0xAB) + extract_lane_u 5 = 0xAB
    var args_i8 = [_]u64{0xAB};
    try vm.invoke(&inst, "splat_i8", &args_i8, &results);
    try testing.expectEqual(@as(u64, 0xAB), results[0]);

    // v128.store + v128.load roundtrip, lane 1 = 200
    try vm.invoke(&inst, "store_load", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 200), results[0]);

    // v128.not(0) = all 1s, extract byte 0 = 255
    try vm.invoke(&inst, "v128_not", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 255), results[0]);

    // v128.and(0xFF00FF, 0x00FFFF) = 0x0000FF
    try vm.invoke(&inst, "v128_and", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0x0000FF), results[0]);

    // v128.or(0xF0, 0x0F) = 0xFF
    try vm.invoke(&inst, "v128_or", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0xFF), results[0]);

    // v128.xor(0xFF, 0x0F) = 0xF0
    try vm.invoke(&inst, "v128_xor", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0xF0), results[0]);

    // v128.any_true(0,0,1,0) = 1
    try vm.invoke(&inst, "any_true_yes", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // v128.any_true(0,0,0,0) = 0
    try vm.invoke(&inst, "any_true_no", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // i8x16.shuffle — swap first two bytes: 0x01,0x02,0x03,0x04 → byte 0 = 0x02
    try vm.invoke(&inst, "shuffle_swap", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0x02), results[0]);

    // i32x4.replace_lane 2 with 999, extract lane 2 = 999
    try vm.invoke(&inst, "replace_lane", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 999), results[0]);

    // v128.load32_zero: lane 1 should be 0 (only lane 0 loaded)
    try vm.invoke(&inst, "load32_zero", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // v128.load8_splat: byte 7 at offset 0, splat to all lanes, extract lane 15 = 7
    try vm.invoke(&inst, "load8_splat", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "Conformance — SIMD integer arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_integer.wasm");
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
    var results = [_]u64{0};
    const no_args = [_]u64{};

    // i32x4.eq: lane 0 matches → -1 (all ones)
    try vm.invoke(&inst, "i32x4_eq", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, 0xFFFFFFFF)), results[0]);

    // i32x4.lt_s: -1 < 0 → -1
    try vm.invoke(&inst, "i32x4_lt_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, 0xFFFFFFFF)), results[0]);

    // i8x16.add: 0x64 + 0x01 = 0x65 = 101
    try vm.invoke(&inst, "i8x16_add", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 101), results[0]);

    // i16x8.mul: 10 * 3 = 30
    try vm.invoke(&inst, "i16x8_mul", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 30), results[0]);

    // i8x16.add_sat_s: 120 + 120 saturated = 127
    try vm.invoke(&inst, "i8x16_add_sat_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 127), results[0]);

    // i32x4.shl: 1 << 2 = 4
    try vm.invoke(&inst, "i32x4_shl", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 4), results[0]);

    // i32x4.shr_s: -8 >> 1 = -4
    try vm.invoke(&inst, "i32x4_shr_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -4)))), results[0]);

    // i32x4.abs: |-5| = 5
    try vm.invoke(&inst, "i32x4_abs", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 5), results[0]);

    // i32x4.neg: -(5) = -5
    try vm.invoke(&inst, "i32x4_neg", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -5)))), results[0]);

    // i8x16.min_s: min(10, 20) = 10
    try vm.invoke(&inst, "i8x16_min_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 10), results[0]);

    // i32x4.max_s: max(10, 20) = 20
    try vm.invoke(&inst, "i32x4_max_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 20), results[0]);

    // i16x8.narrow_i32x4_s: 32768 saturated to i16 → 32767
    try vm.invoke(&inst, "narrow_sat", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 32767), results[0]);

    // i32x4.extend_low_i16x8_s: -5 sign-extended to i32
    try vm.invoke(&inst, "extend_low_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -5)))), results[0]);

    // i32x4.extmul_low_i16x8_s: -10 * 5 = -50
    try vm.invoke(&inst, "extmul_low_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -50)))), results[0]);

    // i32x4.dot_i16x8_s: 1*2 + 3*4 = 14
    try vm.invoke(&inst, "dot_product", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 14), results[0]);

    // i8x16.all_true: all non-zero → 1
    try vm.invoke(&inst, "all_true_yes", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // i8x16.all_true: has zero → 0
    try vm.invoke(&inst, "all_true_no", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // i32x4.bitmask: (-1, 0, -1, 0) → 0b0101 = 5
    try vm.invoke(&inst, "bitmask", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 5), results[0]);

    // i8x16.popcnt: popcount(0xFF) = 8
    try vm.invoke(&inst, "popcnt", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // i16x8.extadd_pairwise: (-1) + 2 = 1
    try vm.invoke(&inst, "extadd_pairwise", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // i8x16.avgr_u: (10 + 20 + 1) / 2 = 15 (truncated)
    try vm.invoke(&inst, "avgr_u", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 15), results[0]);
}

test "Conformance — SIMD float arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_float.wasm");
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
    const no_args = [_]u64{};

    // f32 results use bit comparison via u64
    var r64 = [_]u64{0};

    // f32x4.add: 1.5 + 0.5 = 2.0
    try vm.invoke(&inst, "f32x4_add", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f64x2.mul: 2.0 * 4.0 = 8.0
    try vm.invoke(&inst, "f64x2_mul", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 8.0))), r64[0]);

    // f32x4.eq: 1.0 == 1.0 → all-ones (0xFFFFFFFF)
    try vm.invoke(&inst, "f32x4_eq", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), r64[0]);

    // f32x4.abs: |-1.5| = 1.5
    try vm.invoke(&inst, "f32x4_abs", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.5)))), r64[0]);

    // f32x4.neg: -(1.0) = -1.0
    try vm.invoke(&inst, "f32x4_neg", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -1.0)))), r64[0]);

    // f32x4.sqrt: sqrt(4.0) = 2.0
    try vm.invoke(&inst, "f32x4_sqrt", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.ceil: ceil(1.3) = 2.0
    try vm.invoke(&inst, "f32x4_ceil", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.floor: floor(1.7) = 1.0
    try vm.invoke(&inst, "f32x4_floor", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // f32x4.nearest: nearest(2.5) = 2.0 (round to even)
    try vm.invoke(&inst, "f32x4_nearest", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.min: min(1.0, 2.0) = 1.0
    try vm.invoke(&inst, "f32x4_min", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // f32x4.max: max(1.0, 2.0) = 2.0
    try vm.invoke(&inst, "f32x4_max", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.pmin: pmin(3.0, 1.0) = 1.0
    try vm.invoke(&inst, "f32x4_pmin", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // i32x4.trunc_sat_f32x4_s: trunc(2.9) = 2
    try vm.invoke(&inst, "trunc_sat_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 2), r64[0]);

    // f32x4.convert_i32x4_s: convert(42) = 42.0
    try vm.invoke(&inst, "convert_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 42.0)))), r64[0]);

    // f32x4.demote: lane 2 = 0.0 (zero-padded)
    try vm.invoke(&inst, "demote", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 0.0)))), r64[0]);

    // f64x2.promote_low_f32x4: promote(1.5f) ≈ 1.5
    try vm.invoke(&inst, "promote", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), r64[0]);

    // f64x2.convert_low_i32x4_s: convert(-7) = -7.0
    try vm.invoke(&inst, "f64_convert_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -7.0))), r64[0]);

    // i32x4.trunc_sat_f64x2_s_zero: lane 2 = 0 (zero-padded)
    try vm.invoke(&inst, "trunc_f64_zero", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 0), r64[0]);
}
