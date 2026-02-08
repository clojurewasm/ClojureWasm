// Wasm module instance — instantiation, import resolution, and invoke API.
//
// Links a decoded Module with a Store, resolving imports, allocating memories/
// tables/globals, applying data/element initializers, and running start fn.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const wasi_mod = @import("wasi.zig");
pub const WasiContext = wasi_mod.WasiContext;
const WasmMemory = @import("memory.zig").Memory;
const module_mod = @import("module.zig");
const Module = module_mod.Module;

pub const Instance = struct {
    alloc: Allocator,
    module: *const Module,
    store: *Store,

    // Address mappings — module-local indices → store addresses
    funcaddrs: ArrayList(usize),
    memaddrs: ArrayList(usize),
    tableaddrs: ArrayList(usize),
    globaladdrs: ArrayList(usize),
    elemaddrs: ArrayList(usize),
    dataaddrs: ArrayList(usize),

    // WASI context (optional, set before instantiate for WASI modules)
    wasi: ?*WasiContext = null,

    pub fn init(alloc: Allocator, store: *Store, module: *const Module) Instance {
        return .{
            .alloc = alloc,
            .module = module,
            .store = store,
            .funcaddrs = .empty,
            .memaddrs = .empty,
            .tableaddrs = .empty,
            .globaladdrs = .empty,
            .elemaddrs = .empty,
            .dataaddrs = .empty,
        };
    }

    pub fn deinit(self: *Instance) void {
        self.funcaddrs.deinit(self.alloc);
        self.memaddrs.deinit(self.alloc);
        self.tableaddrs.deinit(self.alloc);
        self.globaladdrs.deinit(self.alloc);
        self.elemaddrs.deinit(self.alloc);
        self.dataaddrs.deinit(self.alloc);
    }

    pub fn instantiate(self: *Instance) !void {
        if (!self.module.decoded) return error.ModuleNotDecoded;

        try self.resolveImports();
        try self.instantiateFunctions();
        try self.instantiateMemories();
        try self.instantiateTables();
        try self.instantiateGlobals();
        try self.instantiateElems();
        try self.instantiateData();
        try self.applyActiveElements();
        try self.applyActiveData();

        // Start function is deferred — needs VM (35W.6)
    }

    // ---- Lookup helpers ----

    pub fn getFunc(self: *Instance, idx: usize) !store_mod.Function {
        if (idx >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        return self.store.getFunction(self.funcaddrs.items[idx]);
    }

    pub fn getFuncPtr(self: *Instance, idx: usize) !*store_mod.Function {
        if (idx >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        return self.store.getFunctionPtr(self.funcaddrs.items[idx]);
    }

    pub fn getMemory(self: *Instance, idx: usize) !*WasmMemory {
        if (idx >= self.memaddrs.items.len) return error.MemoryIndexOutOfBounds;
        return self.store.getMemory(self.memaddrs.items[idx]);
    }

    pub fn getTable(self: *Instance, idx: usize) !*store_mod.Table {
        if (idx >= self.tableaddrs.items.len) return error.TableIndexOutOfBounds;
        return self.store.getTable(self.tableaddrs.items[idx]);
    }

    pub fn getGlobal(self: *Instance, idx: usize) !*store_mod.Global {
        if (idx >= self.globaladdrs.items.len) return error.GlobalIndexOutOfBounds;
        return self.store.getGlobal(self.globaladdrs.items[idx]);
    }

    // ---- Export lookup ----

    /// Find an exported function's store address by name.
    pub fn getExportFunc(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .func) orelse return null;
        if (idx >= self.funcaddrs.items.len) return null;
        return self.funcaddrs.items[idx];
    }

    /// Find the exported memory by index (usually 0).
    pub fn getExportMemory(self: *Instance, name: []const u8) ?*WasmMemory {
        const idx = self.module.getExport(name, .memory) orelse return null;
        if (idx >= self.memaddrs.items.len) return null;
        return self.store.getMemory(self.memaddrs.items[idx]) catch null;
    }

    // ---- Instantiation steps ----

    fn resolveImports(self: *Instance) !void {
        for (self.module.imports.items) |imp| {
            const handle = self.store.lookupImport(imp.module, imp.name, imp.kind) catch
                return error.ImportNotFound;

            switch (imp.kind) {
                .func => try self.funcaddrs.append(self.alloc, handle),
                .memory => try self.memaddrs.append(self.alloc, handle),
                .table => try self.tableaddrs.append(self.alloc, handle),
                .global => try self.globaladdrs.append(self.alloc, handle),
            }
        }
    }

    fn instantiateFunctions(self: *Instance) !void {
        for (self.module.functions.items, 0..) |func_def, i| {
            if (i >= self.module.codes.items.len) return error.FunctionCodeMismatch;
            const code = self.module.codes.items[i];
            const func_type = if (func_def.type_idx < self.module.types.items.len)
                self.module.types.items[func_def.type_idx]
            else
                return error.InvalidTypeIndex;

            const addr = try self.store.addFunction(.{
                .params = func_type.params,
                .results = func_type.results,
                .subtype = .{ .wasm_function = .{
                    .locals_count = code.locals_count,
                    .code = code.body,
                    .instance = @ptrCast(self),
                } },
            });
            try self.funcaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateMemories(self: *Instance) !void {
        for (self.module.memories.items) |mem_def| {
            const addr = try self.store.addMemory(mem_def.limits.min, mem_def.limits.max);
            const m = try self.store.getMemory(addr);
            try m.allocateInitial();
            try self.memaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateTables(self: *Instance) !void {
        for (self.module.tables.items) |tab_def| {
            const addr = try self.store.addTable(
                tab_def.reftype,
                tab_def.limits.min,
                tab_def.limits.max,
            );
            try self.tableaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateGlobals(self: *Instance) !void {
        for (self.module.globals.items) |glob_def| {
            const init_val = try evalInitExpr(glob_def.init_expr, self);
            const addr = try self.store.addGlobal(.{
                .value = init_val,
                .valtype = glob_def.valtype,
                .mutability = @enumFromInt(glob_def.mutability),
            });
            try self.globaladdrs.append(self.alloc, addr);
        }
    }

    fn instantiateElems(self: *Instance) !void {
        for (0..self.module.elements.items.len) |_| {
            const addr = try self.store.addElem(.funcref, 0);
            try self.elemaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateData(self: *Instance) !void {
        for (0..self.module.datas.items.len) |_| {
            const addr = try self.store.addData(0);
            try self.dataaddrs.append(self.alloc, addr);
        }
    }

    fn applyActiveElements(self: *Instance) !void {
        for (self.module.elements.items) |elem_seg| {
            switch (elem_seg.mode) {
                .active => |active| {
                    const offset = try evalInitExpr(active.offset_expr, self);
                    const table_idx = active.table_idx;
                    const t = try self.getTable(table_idx);

                    switch (elem_seg.init) {
                        .func_indices => |indices| {
                            for (indices, 0..) |func_idx, i| {
                                const dest: u32 = @intCast(@as(u64, @truncate(offset)) + i);
                                const func_addr = if (func_idx < self.funcaddrs.items.len)
                                    self.funcaddrs.items[func_idx]
                                else
                                    return error.FunctionIndexOutOfBounds;
                                try t.set(dest, func_addr);
                            }
                        },
                        .expressions => {}, // Expression-based init deferred to VM
                    }
                },
                .passive, .declarative => {},
            }
        }
    }

    fn applyActiveData(self: *Instance) !void {
        for (self.module.datas.items) |data_seg| {
            switch (data_seg.mode) {
                .active => |active| {
                    const offset = try evalInitExpr(active.offset_expr, self);
                    const m = try self.getMemory(active.mem_idx);
                    try m.copy(@truncate(offset), data_seg.data);
                },
                .passive => {},
            }
        }
    }
};

/// Evaluate a constant init expression (i32.const, i64.const, f32.const,
/// f64.const, global.get, ref.null, ref.func). Returns u64.
pub fn evalInitExpr(expr: []const u8, instance: *Instance) !u64 {
    var reader = Reader.init(expr);
    while (reader.hasMore()) {
        const byte = try reader.readByte();
        const op: opcode.Opcode = @enumFromInt(byte);
        switch (op) {
            .i32_const => {
                const val = try reader.readI32();
                return @bitCast(@as(i64, val));
            },
            .i64_const => {
                const val = try reader.readI64();
                return @bitCast(val);
            },
            .f32_const => {
                const val = try reader.readF32();
                return @as(u64, @as(u32, @bitCast(val)));
            },
            .f64_const => {
                const val = try reader.readF64();
                return @bitCast(val);
            },
            .global_get => {
                const idx = try reader.readU32();
                const g = try instance.getGlobal(idx);
                return g.value;
            },
            .ref_null => {
                _ = try reader.readByte(); // reftype
                return 0; // null ref
            },
            .ref_func => {
                const idx = try reader.readU32();
                return idx;
            },
            .end => return 0, // empty init expr
            else => return error.InvalidInitExpr,
        }
    }
    return 0;
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

test "Instance — instantiate 01_add.wasm" {
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

    // Should have one function
    try testing.expectEqual(@as(usize, 1), inst.funcaddrs.items.len);

    // Should be able to look up "add" export
    const add_addr = inst.getExportFunc("add");
    try testing.expect(add_addr != null);
}

test "Instance — instantiate 03_memory.wasm" {
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

    // Should have memory
    try testing.expect(inst.memaddrs.items.len > 0);
    const m = try inst.getMemory(0);
    try testing.expect(m.size() > 0);
}

test "Instance — instantiate 04_imports.wasm with host functions" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Register host functions that the module imports
    const dummy_fn: store_mod.HostFn = @ptrFromInt(@intFromPtr(&struct {
        fn f(_: *anyopaque, _: usize) anyerror!void {}
    }.f));

    try store.exposeHostFunction("env", "print_i32", dummy_fn, 0,
        &[_]ValType{.i32}, &[_]ValType{});
    try store.exposeHostFunction("env", "print_str", dummy_fn, 0,
        &[_]ValType{ .i32, .i32 }, &[_]ValType{});

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    // 2 imported + 2 local functions
    try testing.expectEqual(@as(usize, 4), inst.funcaddrs.items.len);

    // Data segment should have been applied
    const m = try inst.getMemory(0);
    const bytes = m.memory();
    try testing.expectEqualStrings("Hello from Wasm!", bytes[0..16]);
}

test "Instance — instantiate 06_globals.wasm" {
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

    // Should have globals
    try testing.expect(inst.globaladdrs.items.len > 0);
}

test "Instance — missing import returns error" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Don't register any imports
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try testing.expectError(error.ImportNotFound, inst.instantiate());
}

test "evalInitExpr — i32.const" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const 42, end
    const expr = [_]u8{ 0x41, 42, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u64, 42), val);
}

test "evalInitExpr — i32.const negative" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const -1, end
    const expr = [_]u8{ 0x41, 0x7F, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    // -1 as i32 sign-extended to i64 then bitcast to u64
    const expected: u64 = @bitCast(@as(i64, -1));
    try testing.expectEqual(expected, val);
}

test "evalInitExpr — i64.const" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i64.const 100, end
    const expr = [_]u8{ 0x42, 0xE4, 0x00, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u64, 100), val);
}
