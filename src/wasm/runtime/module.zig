// Wasm binary module decoder — parses sections 0-12.
//
// Design: no intermediate representation (no Rr). Code bodies and init
// expressions are stored as raw bytecode slices that the VM interprets
// directly. This saves ~500 LOC vs zware's Rr approach.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

// ============================================================
// Module types
// ============================================================

/// Function signature.
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Import descriptor.
pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: opcode.ExternalKind,
    /// For func: type index. For table/memory/global: encoded inline.
    index: u32,
    // Table/memory/global inline data (only used when kind != func)
    table_type: ?TableDef = null,
    memory_type: ?MemoryDef = null,
    global_type: ?GlobalDef = null,
};

/// Export descriptor.
pub const Export = struct {
    name: []const u8,
    kind: opcode.ExternalKind,
    index: u32,
};

/// Function section entry — maps to a type index.
pub const FunctionDef = struct {
    type_idx: u32,
};

/// Table definition.
pub const TableDef = struct {
    reftype: opcode.RefType,
    limits: opcode.Limits,
};

/// Memory definition.
pub const MemoryDef = struct {
    limits: opcode.Limits,
};

/// Global definition.
pub const GlobalDef = struct {
    valtype: ValType,
    mutability: u8, // 0 = immutable, 1 = mutable
    init_expr: []const u8, // raw bytecode of init expression
};

/// Local variable definition within a code body.
pub const LocalEntry = struct {
    count: u32,
    valtype: ValType,
};

/// Code section entry — a function body.
pub const Code = struct {
    locals: []const LocalEntry,
    body: []const u8, // raw Wasm bytecode (up to but not including final `end`)
    locals_count: u32, // total number of locals (sum of all LocalEntry.count)
};

/// Element segment.
pub const ElementSegment = struct {
    mode: ElementMode,
    reftype: opcode.RefType,
    init: ElementInit,
};

pub const ElementMode = union(enum) {
    passive,
    active: struct { table_idx: u32, offset_expr: []const u8 },
    declarative,
};

pub const ElementInit = union(enum) {
    func_indices: []const u32,
    expressions: []const []const u8,
};

/// Data segment.
pub const DataSegment = struct {
    mode: DataMode,
    data: []const u8,
};

pub const DataMode = union(enum) {
    passive,
    active: struct { mem_idx: u32, offset_expr: []const u8 },
};

// ============================================================
// Module
// ============================================================

pub const Module = struct {
    alloc: Allocator,
    wasm_bin: []const u8,
    decoded: bool,

    // Decoded sections
    types: ArrayList(FuncType),
    imports: ArrayList(Import),
    functions: ArrayList(FunctionDef),
    tables: ArrayList(TableDef),
    memories: ArrayList(MemoryDef),
    globals: ArrayList(GlobalDef),
    exports: ArrayList(Export),
    start: ?u32,
    elements: ArrayList(ElementSegment),
    codes: ArrayList(Code),
    datas: ArrayList(DataSegment),
    data_count: ?u32,

    // Derived counts
    num_imported_funcs: u32,
    num_imported_tables: u32,
    num_imported_memories: u32,
    num_imported_globals: u32,

    pub fn init(alloc: Allocator, wasm_bin: []const u8) Module {
        return .{
            .alloc = alloc,
            .wasm_bin = wasm_bin,
            .decoded = false,
            .types = .empty,
            .imports = .empty,
            .functions = .empty,
            .tables = .empty,
            .memories = .empty,
            .globals = .empty,
            .exports = .empty,
            .start = null,
            .elements = .empty,
            .codes = .empty,
            .datas = .empty,
            .data_count = null,
            .num_imported_funcs = 0,
            .num_imported_tables = 0,
            .num_imported_memories = 0,
            .num_imported_globals = 0,
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.types.items) |ft| {
            self.alloc.free(ft.params);
            self.alloc.free(ft.results);
        }
        self.types.deinit(self.alloc);

        self.imports.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.tables.deinit(self.alloc);
        self.memories.deinit(self.alloc);

        for (self.globals.items) |g| _ = g; // init_expr is a slice into wasm_bin
        self.globals.deinit(self.alloc);

        self.exports.deinit(self.alloc);

        for (self.elements.items) |es| {
            switch (es.init) {
                .func_indices => |fi| self.alloc.free(fi),
                .expressions => |exprs| self.alloc.free(exprs),
            }
        }
        self.elements.deinit(self.alloc);

        for (self.codes.items) |c| self.alloc.free(c.locals);
        self.codes.deinit(self.alloc);

        self.datas.deinit(self.alloc);
    }

    pub fn decode(self: *Module) !void {
        if (self.wasm_bin.len < 8) return error.InvalidWasm;

        // Verify magic and version
        if (!mem.eql(u8, self.wasm_bin[0..4], &opcode.MAGIC))
            return error.InvalidWasm;
        if (!mem.eql(u8, self.wasm_bin[4..8], &opcode.VERSION))
            return error.InvalidWasm;

        var reader = Reader.init(self.wasm_bin[8..]);

        while (reader.hasMore()) {
            try self.decodeSection(&reader);
        }

        // Verify function/code count consistency
        if (self.functions.items.len != self.codes.items.len)
            return error.FunctionCodeMismatch;

        self.decoded = true;
    }

    fn decodeSection(self: *Module, reader: *Reader) !void {
        const section_id = try reader.readByte();
        const section_size = try reader.readU32();
        var sub = try reader.subReader(section_size);

        const section: opcode.Section = @enumFromInt(section_id);
        switch (section) {
            .custom => {}, // skip custom sections
            .type => try self.decodeTypeSection(&sub),
            .import => try self.decodeImportSection(&sub),
            .function => try self.decodeFunctionSection(&sub),
            .table => try self.decodeTableSection(&sub),
            .memory => try self.decodeMemorySection(&sub),
            .global => try self.decodeGlobalSection(&sub),
            .@"export" => try self.decodeExportSection(&sub),
            .start => try self.decodeStartSection(&sub),
            .element => try self.decodeElementSection(&sub),
            .code => try self.decodeCodeSection(&sub),
            .data => try self.decodeDataSection(&sub),
            .data_count => try self.decodeDataCountSection(&sub),
            _ => {}, // skip unknown sections
        }
    }

    // ---- Section 1: Type ----
    fn decodeTypeSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.types.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const form = try reader.readByte();
            if (form != 0x60) return error.InvalidWasm; // functype marker

            // Params
            const param_count = try reader.readU32();
            const params = try self.alloc.alloc(ValType, param_count);
            errdefer self.alloc.free(params);
            for (params) |*p| p.* = @enumFromInt(try reader.readByte());

            // Results
            const result_count = try reader.readU32();
            const results = try self.alloc.alloc(ValType, result_count);
            errdefer self.alloc.free(results);
            for (results) |*r| r.* = @enumFromInt(try reader.readByte());

            try self.types.append(self.alloc, .{ .params = params, .results = results });
        }
    }

    // ---- Section 2: Import ----
    fn decodeImportSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.imports.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const mod_len = try reader.readU32();
            const mod_name = try reader.readBytes(mod_len);
            const name_len = try reader.readU32();
            const name = try reader.readBytes(name_len);
            const kind_byte = try reader.readByte();
            const kind: opcode.ExternalKind = @enumFromInt(kind_byte);

            var imp = Import{
                .module = mod_name,
                .name = name,
                .kind = kind,
                .index = 0,
            };

            switch (kind) {
                .func => {
                    imp.index = try reader.readU32();
                    self.num_imported_funcs += 1;
                },
                .table => {
                    imp.table_type = try readTableDef(reader);
                    self.num_imported_tables += 1;
                },
                .memory => {
                    imp.memory_type = try readMemoryDef(reader);
                    self.num_imported_memories += 1;
                },
                .global => {
                    imp.global_type = try readGlobalImportDef(reader);
                    self.num_imported_globals += 1;
                },
            }

            try self.imports.append(self.alloc, imp);
        }
    }

    // ---- Section 3: Function ----
    fn decodeFunctionSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.functions.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.functions.append(self.alloc, .{ .type_idx = try reader.readU32() });
        }
    }

    // ---- Section 4: Table ----
    fn decodeTableSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.tables.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.tables.append(self.alloc, try readTableDef(reader));
        }
    }

    // ---- Section 5: Memory ----
    fn decodeMemorySection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.memories.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.memories.append(self.alloc, try readMemoryDef(reader));
        }
    }

    // ---- Section 6: Global ----
    fn decodeGlobalSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.globals.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            const valtype: ValType = @enumFromInt(try reader.readByte());
            const mutability = try reader.readByte();
            const init_start = reader.pos;
            try skipInitExpr(reader);
            const init_end = reader.pos;

            try self.globals.append(self.alloc, .{
                .valtype = valtype,
                .mutability = mutability,
                .init_expr = reader.bytes[init_start..init_end],
            });
        }
    }

    // ---- Section 7: Export ----
    fn decodeExportSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.exports.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            const name_len = try reader.readU32();
            const name = try reader.readBytes(name_len);
            const kind: opcode.ExternalKind = @enumFromInt(try reader.readByte());
            const index = try reader.readU32();
            try self.exports.append(self.alloc, .{ .name = name, .kind = kind, .index = index });
        }
    }

    // ---- Section 8: Start ----
    fn decodeStartSection(self: *Module, reader: *Reader) !void {
        self.start = try reader.readU32();
    }

    // ---- Section 9: Element ----
    fn decodeElementSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.elements.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const elem_type = try reader.readU32();
            try self.elements.append(self.alloc, try self.decodeElementSegment(reader, elem_type));
        }
    }

    fn decodeElementSegment(self: *Module, reader: *Reader, elem_type: u32) !ElementSegment {
        switch (elem_type) {
            0 => {
                // Active, table 0, func indices
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .{ .active = .{
                        .table_idx = 0,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            1 => {
                // Passive, elemkind, func indices
                const elemkind = try reader.readByte();
                _ = elemkind; // 0x00 = funcref
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .passive,
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            2 => {
                // Active, explicit table, elemkind, func indices
                const table_idx = try reader.readU32();
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const elemkind = try reader.readByte();
                _ = elemkind;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .{ .active = .{
                        .table_idx = table_idx,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            3 => {
                // Declarative, elemkind, func indices
                const elemkind = try reader.readByte();
                _ = elemkind;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .declarative,
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            4 => {
                // Active, table 0, expressions
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .{ .active = .{
                        .table_idx = 0,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .expressions = exprs },
                };
            },
            5 => {
                // Passive, explicit reftype, expressions
                const reftype: opcode.RefType = @enumFromInt(try reader.readByte());
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .passive,
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            6 => {
                // Active, explicit table + reftype, expressions
                const table_idx = try reader.readU32();
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const reftype: opcode.RefType = @enumFromInt(try reader.readByte());
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .{ .active = .{
                        .table_idx = table_idx,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            7 => {
                // Declarative, explicit reftype, expressions
                const reftype: opcode.RefType = @enumFromInt(try reader.readByte());
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .declarative,
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            else => return error.InvalidWasm,
        }
    }

    // ---- Section 10: Code ----
    fn decodeCodeSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.codes.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const body_size = try reader.readU32();
            var body_reader = try reader.subReader(body_size);

            // Parse locals
            const num_local_entries = try body_reader.readU32();
            const locals = try self.alloc.alloc(LocalEntry, num_local_entries);
            errdefer self.alloc.free(locals);
            var locals_count: u32 = 0;
            for (locals) |*le| {
                le.count = try body_reader.readU32();
                le.valtype = @enumFromInt(try body_reader.readByte());
                locals_count += le.count;
            }

            // Remaining bytes are the function body (includes trailing `end`)
            const body = body_reader.bytes[body_reader.pos..];

            try self.codes.append(self.alloc, .{
                .locals = locals,
                .body = body,
                .locals_count = locals_count,
            });
        }
    }

    // ---- Section 11: Data ----
    fn decodeDataSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.datas.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const data_type = try reader.readU32();
            switch (data_type) {
                0 => {
                    // Active, memory 0
                    const offset_start = reader.pos;
                    try skipInitExpr(reader);
                    const offset_end = reader.pos;
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .{ .active = .{
                            .mem_idx = 0,
                            .offset_expr = reader.bytes[offset_start..offset_end],
                        } },
                        .data = data,
                    });
                },
                1 => {
                    // Passive
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .passive,
                        .data = data,
                    });
                },
                2 => {
                    // Active, explicit memory
                    const mem_idx = try reader.readU32();
                    const offset_start = reader.pos;
                    try skipInitExpr(reader);
                    const offset_end = reader.pos;
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .{ .active = .{
                            .mem_idx = mem_idx,
                            .offset_expr = reader.bytes[offset_start..offset_end],
                        } },
                        .data = data,
                    });
                },
                else => return error.InvalidWasm,
            }
        }
    }

    // ---- Section 12: Data Count ----
    fn decodeDataCountSection(self: *Module, reader: *Reader) !void {
        self.data_count = try reader.readU32();
    }

    // ---- Export lookup helpers ----

    pub fn getExport(self: *const Module, name: []const u8, kind: opcode.ExternalKind) ?u32 {
        for (self.exports.items) |exp| {
            if (exp.kind == kind and mem.eql(u8, exp.name, name))
                return exp.index;
        }
        return null;
    }

    /// Get the FuncType for a function by its function index (imports first, then local).
    pub fn getFuncType(self: *const Module, func_idx: u32) ?FuncType {
        if (func_idx < self.num_imported_funcs) {
            // Imported function
            var import_func_idx: u32 = 0;
            for (self.imports.items) |imp| {
                if (imp.kind == .func) {
                    if (import_func_idx == func_idx) {
                        if (imp.index < self.types.items.len)
                            return self.types.items[imp.index];
                        return null;
                    }
                    import_func_idx += 1;
                }
            }
            return null;
        } else {
            // Local function
            const local_idx = func_idx - self.num_imported_funcs;
            if (local_idx >= self.functions.items.len) return null;
            const type_idx = self.functions.items[local_idx].type_idx;
            if (type_idx >= self.types.items.len) return null;
            return self.types.items[type_idx];
        }
    }
};

// ============================================================
// Helpers
// ============================================================

fn readTableDef(reader: *Reader) !TableDef {
    const reftype: opcode.RefType = @enumFromInt(try reader.readByte());
    const limits = try readLimits(reader);
    return .{ .reftype = reftype, .limits = limits };
}

fn readMemoryDef(reader: *Reader) !MemoryDef {
    const limits = try readLimits(reader);
    return .{ .limits = limits };
}

fn readGlobalImportDef(reader: *Reader) !GlobalDef {
    const valtype: ValType = @enumFromInt(try reader.readByte());
    const mutability = try reader.readByte();
    return .{ .valtype = valtype, .mutability = mutability, .init_expr = &.{} };
}

fn readLimits(reader: *Reader) !opcode.Limits {
    const has_max = try reader.readByte();
    const min = try reader.readU32();
    const max: ?u32 = if (has_max == 1) try reader.readU32() else null;
    return .{ .min = min, .max = max };
}

/// Skip over an init expression (reads until `end` opcode 0x0B).
fn skipInitExpr(reader: *Reader) !void {
    while (true) {
        const byte = try reader.readByte();
        const op: opcode.Opcode = @enumFromInt(byte);
        switch (op) {
            .end => return,
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .global_get => _ = try reader.readU32(),
            .ref_null => _ = try reader.readByte(),
            .ref_func => _ = try reader.readU32(),
            else => return error.InvalidWasm,
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Read a wasm test file at runtime (avoids @embedFile package path issues).
fn readTestFile(alloc: Allocator, name: []const u8) ![]const u8 {
    // Try relative path from project root (for `zig test` and `zig build test`)
    const prefixes = [_][]const u8{
        "src/wasm/testdata/",
        "testdata/",
    };
    for (prefixes) |prefix| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        defer alloc.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();
        const stat = try file.stat();
        const data = try alloc.alloc(u8, stat.size);
        const read = try file.readAll(data);
        return data[0..read];
    }
    return error.FileNotFound;
}

test "Module — decode 01_add.wasm" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // Type section: one func type (i32, i32) -> i32
    try testing.expectEqual(@as(usize, 1), mod.types.items.len);
    try testing.expectEqual(@as(usize, 2), mod.types.items[0].params.len);
    try testing.expectEqual(ValType.i32, mod.types.items[0].params[0]);
    try testing.expectEqual(ValType.i32, mod.types.items[0].params[1]);
    try testing.expectEqual(@as(usize, 1), mod.types.items[0].results.len);
    try testing.expectEqual(ValType.i32, mod.types.items[0].results[0]);

    // Function section: one function
    try testing.expectEqual(@as(usize, 1), mod.functions.items.len);
    try testing.expectEqual(@as(u32, 0), mod.functions.items[0].type_idx);

    // Export section: "add"
    try testing.expectEqual(@as(usize, 1), mod.exports.items.len);
    try testing.expectEqualStrings("add", mod.exports.items[0].name);
    try testing.expectEqual(opcode.ExternalKind.func, mod.exports.items[0].kind);

    // Code section: one code body
    try testing.expectEqual(@as(usize, 1), mod.codes.items.len);
    try testing.expect(mod.codes.items[0].body.len > 0);

    // No imports, no start
    try testing.expectEqual(@as(usize, 0), mod.imports.items.len);
    try testing.expect(mod.start == null);
}

test "Module — decode 02_fibonacci.wasm" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.getExport("fib", .func) != null);
}

test "Module — decode 03_memory.wasm" {
    const wasm = try readTestFile(testing.allocator, "03_memory.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.memories.items.len > 0);
    try testing.expect(mod.getExport("store", .func) != null);
    try testing.expect(mod.getExport("load", .func) != null);
}

test "Module — decode 04_imports.wasm" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.imports.items.len >= 2);
    try testing.expectEqualStrings("env", mod.imports.items[0].module);
    try testing.expectEqual(@as(u32, 2), mod.num_imported_funcs);
    try testing.expect(mod.getExport("greet", .func) != null);
}

test "Module — decode 05_table_indirect_call.wasm" {
    const wasm = try readTestFile(testing.allocator, "05_table_indirect_call.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.tables.items.len > 0 or mod.num_imported_tables > 0);
    try testing.expect(mod.elements.items.len > 0);
}

test "Module — decode 06_globals.wasm" {
    const wasm = try readTestFile(testing.allocator, "06_globals.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.globals.items.len > 0);
}

test "Module — decode 07_wasi_hello.wasm" {
    const wasm = try readTestFile(testing.allocator, "07_wasi_hello.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.imports.items.len > 0);
    try testing.expectEqualStrings("wasi_snapshot_preview1", mod.imports.items[0].module);
}

test "Module — decode 08_multi_value.wasm" {
    const wasm = try readTestFile(testing.allocator, "08_multi_value.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var has_multi = false;
    for (mod.types.items) |ft| {
        if (ft.results.len > 1) has_multi = true;
    }
    try testing.expect(has_multi);
}

test "Module — decode 09_go_math.wasm (large TinyGo module)" {
    const wasm = try readTestFile(testing.allocator, "09_go_math.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.functions.items.len > 10);
    try testing.expect(mod.codes.items.len > 10);
}

test "Module — decode 10_greet.wasm" {
    const wasm = try readTestFile(testing.allocator, "10_greet.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // 10_greet.wasm has memory + globals + exported greet function
    try testing.expect(mod.memories.items.len > 0);
    try testing.expect(mod.getExport("greet", .func) != null);
}

test "Module — data section in imports module" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // 04_imports.wasm has a data section with "Hello from Wasm!"
    try testing.expect(mod.datas.items.len > 0);
    try testing.expectEqualStrings("Hello from Wasm!", mod.datas.items[0].data);
}

test "Module — getExport nonexistent" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.getExport("nonexistent", .func) == null);
}

test "Module — getFuncType" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    const ft = mod.getFuncType(0);
    try testing.expect(ft != null);
    try testing.expectEqual(@as(usize, 2), ft.?.params.len);
    try testing.expectEqual(@as(usize, 1), ft.?.results.len);
}

test "Module — invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &bad);
    defer mod.deinit();
    try testing.expectError(error.InvalidWasm, mod.decode());
}

test "Module — too short" {
    const short = [_]u8{ 0x00, 0x61, 0x73 };
    var mod = Module.init(testing.allocator, &short);
    defer mod.deinit();
    try testing.expectError(error.InvalidWasm, mod.decode());
}
