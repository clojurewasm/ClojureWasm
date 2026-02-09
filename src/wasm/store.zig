// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Wasm runtime store — function registry, memories, tables, globals.
//!
//! The store holds all runtime state shared across module instances.
//! Functions can be Wasm bytecode or host (native) callbacks.

const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const WasmMemory = @import("memory.zig").Memory;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

/// Forward declaration — Instance defined in instance.zig.
pub const Instance = opaque {};

/// Wasm function signature.
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Mutability of a global variable.
pub const Mutability = enum(u8) {
    immutable = 0,
    mutable = 1,
};

/// A Wasm or host function stored in the Store.
pub const Function = struct {
    params: []const ValType,
    results: []const ValType,
    subtype: union(enum) {
        wasm_function: WasmFunction,
        host_function: HostFunction,
    },
};

/// A Wasm function — references bytecode in a module.
pub const WasmFunction = struct {
    locals_count: usize,
    code: []const u8,
    instance: *Instance,
    /// Pre-computed branch targets (lazy: null until first call).
    branch_table: ?*vm_mod.BranchTable = null,
    /// Predecoded IR (lazy: null until first call, stays null if predecode fails).
    ir: ?*predecode_mod.IrFunc = null,
    /// True if predecoding was attempted and failed (avoid retrying).
    ir_failed: bool = false,
};

const vm_mod = @import("vm.zig");
const predecode_mod = @import("predecode.zig");

/// Host function callback signature.
/// Takes a pointer to the VM and a context value.
pub const HostFn = *const fn (*anyopaque, usize) anyerror!void;

/// A host-provided function (native callback).
pub const HostFunction = struct {
    func: HostFn,
    context: usize,
};

/// A Wasm table (indirect function references).
pub const Table = struct {
    alloc: mem.Allocator,
    data: ArrayList(?usize),
    min: u32,
    max: ?u32,
    reftype: opcode.RefType,

    pub fn init(alloc: mem.Allocator, reftype: opcode.RefType, min: u32, max: ?u32) !Table {
        var t = Table{
            .alloc = alloc,
            .data = .empty,
            .min = min,
            .max = max,
            .reftype = reftype,
        };
        _ = try t.data.resize(alloc, min);
        @memset(t.data.items, null);
        return t;
    }

    pub fn deinit(self: *Table) void {
        self.data.deinit(self.alloc);
    }

    pub fn lookup(self: *Table, index: u32) !usize {
        if (index >= self.data.items.len) return error.UndefinedElement;
        return self.data.items[index] orelse error.UndefinedElement;
    }

    pub fn get(self: *Table, index: u32) !?usize {
        if (index >= self.data.items.len) return error.OutOfBounds;
        return self.data.items[index];
    }

    pub fn set(self: *Table, index: u32, value: ?usize) !void {
        if (index >= self.data.items.len) return error.OutOfBounds;
        self.data.items[index] = value;
    }

    pub fn size(self: *const Table) u32 {
        return @intCast(self.data.items.len);
    }

    pub fn grow(self: *Table, n: u32, init_val: ?usize) !u32 {
        const old_size = self.size();
        const new_size = @as(u64, old_size) + n;
        if (self.max) |mx| {
            if (new_size > mx) return error.OutOfBounds;
        }
        _ = try self.data.resize(self.alloc, @intCast(new_size));
        @memset(self.data.items[old_size..], init_val);
        return old_size;
    }
};

/// A Wasm global variable.
pub const Global = struct {
    value: u64,
    valtype: ValType,
    mutability: Mutability,
};

/// An element segment (for table initialization).
pub const Elem = struct {
    reftype: opcode.RefType,
    data: []u32,
    alloc: mem.Allocator,
    dropped: bool,

    pub fn init(alloc: mem.Allocator, reftype: opcode.RefType, count: u32) !Elem {
        const data = try alloc.alloc(u32, count);
        @memset(data, 0);
        return .{
            .reftype = reftype,
            .data = data,
            .alloc = alloc,
            .dropped = false,
        };
    }

    pub fn deinit(self: *Elem) void {
        self.alloc.free(self.data);
    }

    pub fn set(self: *Elem, index: usize, value: u32) void {
        self.data[index] = value;
    }
};

/// A data segment (for memory initialization).
pub const Data = struct {
    data: []u8,
    alloc: mem.Allocator,
    dropped: bool,

    pub fn init(alloc: mem.Allocator, count: u32) !Data {
        const data = try alloc.alloc(u8, count);
        @memset(data, 0);
        return .{
            .data = data,
            .alloc = alloc,
            .dropped = false,
        };
    }

    pub fn deinit(self: *Data) void {
        self.alloc.free(self.data);
    }

    pub fn set(self: *Data, index: usize, value: u8) void {
        self.data[index] = value;
    }
};

/// Import/export descriptor tag (matches opcode.ExternalKind).
pub const Tag = opcode.ExternalKind;

/// An import-export binding in the store.
const ImportExport = struct {
    module: []const u8,
    name: []const u8,
    tag: Tag,
    handle: usize,
};

/// The Wasm runtime store — holds all runtime state.
pub const Store = struct {
    alloc: mem.Allocator,
    functions: ArrayList(Function),
    memories: ArrayList(WasmMemory),
    tables: ArrayList(Table),
    globals: ArrayList(Global),
    elems: ArrayList(Elem),
    datas: ArrayList(Data),
    imports: ArrayList(ImportExport),

    pub fn init(alloc: mem.Allocator) Store {
        return .{
            .alloc = alloc,
            .functions = .empty,
            .memories = .empty,
            .tables = .empty,
            .globals = .empty,
            .elems = .empty,
            .datas = .empty,
            .imports = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.functions.items) |*f| {
            if (f.subtype == .wasm_function) {
                if (f.subtype.wasm_function.branch_table) |bt| {
                    bt.deinit();
                    self.alloc.destroy(bt);
                }
                if (f.subtype.wasm_function.ir) |ir| {
                    ir.deinit();
                    self.alloc.destroy(ir);
                }
            }
        }
        for (self.memories.items) |*m| m.deinit();
        for (self.tables.items) |*t| t.deinit();
        for (self.elems.items) |*e| e.deinit();
        for (self.datas.items) |*d| d.deinit();
        self.functions.deinit(self.alloc);
        self.memories.deinit(self.alloc);
        self.tables.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.elems.deinit(self.alloc);
        self.datas.deinit(self.alloc);
        self.imports.deinit(self.alloc);
    }

    // ---- Lookup by address ----

    pub fn getFunction(self: *Store, addr: usize) !Function {
        if (addr >= self.functions.items.len) return error.BadFunctionIndex;
        return self.functions.items[addr];
    }

    pub fn getFunctionPtr(self: *Store, addr: usize) !*Function {
        if (addr >= self.functions.items.len) return error.BadFunctionIndex;
        return &self.functions.items[addr];
    }

    pub fn getMemory(self: *Store, addr: usize) !*WasmMemory {
        if (addr >= self.memories.items.len) return error.BadMemoryIndex;
        return &self.memories.items[addr];
    }

    pub fn getTable(self: *Store, addr: usize) !*Table {
        if (addr >= self.tables.items.len) return error.BadTableIndex;
        return &self.tables.items[addr];
    }

    pub fn getGlobal(self: *Store, addr: usize) !*Global {
        if (addr >= self.globals.items.len) return error.BadGlobalIndex;
        return &self.globals.items[addr];
    }

    pub fn getElem(self: *Store, addr: usize) !*Elem {
        if (addr >= self.elems.items.len) return error.BadElemAddr;
        return &self.elems.items[addr];
    }

    pub fn getData(self: *Store, addr: usize) !*Data {
        if (addr >= self.datas.items.len) return error.BadDataAddr;
        return &self.datas.items[addr];
    }

    // ---- Add items ----

    pub fn addFunction(self: *Store, func: Function) !usize {
        const ptr = try self.functions.addOne(self.alloc);
        ptr.* = func;
        return self.functions.items.len - 1;
    }

    pub fn addMemory(self: *Store, min: u32, max: ?u32) !usize {
        const ptr = try self.memories.addOne(self.alloc);
        ptr.* = WasmMemory.init(self.alloc, min, max);
        return self.memories.items.len - 1;
    }

    pub fn addTable(self: *Store, reftype: opcode.RefType, min: u32, max: ?u32) !usize {
        const ptr = try self.tables.addOne(self.alloc);
        ptr.* = try Table.init(self.alloc, reftype, min, max);
        return self.tables.items.len - 1;
    }

    pub fn addGlobal(self: *Store, global: Global) !usize {
        const ptr = try self.globals.addOne(self.alloc);
        ptr.* = global;
        return self.globals.items.len - 1;
    }

    pub fn addElem(self: *Store, reftype: opcode.RefType, count: u32) !usize {
        const ptr = try self.elems.addOne(self.alloc);
        ptr.* = try Elem.init(self.alloc, reftype, count);
        return self.elems.items.len - 1;
    }

    pub fn addData(self: *Store, count: u32) !usize {
        const ptr = try self.datas.addOne(self.alloc);
        ptr.* = try Data.init(self.alloc, count);
        return self.datas.items.len - 1;
    }

    // ---- Import/export ----

    /// Look up an import by module name, field name, and tag.
    pub fn lookupImport(self: *Store, module: []const u8, name: []const u8, tag: Tag) !usize {
        for (self.imports.items) |ie| {
            if (ie.tag != tag) continue;
            if (!mem.eql(u8, module, ie.module)) continue;
            if (!mem.eql(u8, name, ie.name)) continue;
            return ie.handle;
        }
        return error.ImportNotFound;
    }

    /// Register an export (used by exposeHostFunction and instance instantiation).
    pub fn addExport(self: *Store, module: []const u8, name: []const u8, tag: Tag, handle: usize) !void {
        try self.imports.append(self.alloc, .{
            .module = module,
            .name = name,
            .tag = tag,
            .handle = handle,
        });
    }

    // ---- Convenience helpers ----

    /// Register a host function and expose it as an import.
    pub fn exposeHostFunction(
        self: *Store,
        module: []const u8,
        name: []const u8,
        func: HostFn,
        context: usize,
        params: []const ValType,
        results: []const ValType,
    ) !void {
        const addr = try self.addFunction(.{
            .params = params,
            .results = results,
            .subtype = .{ .host_function = .{ .func = func, .context = context } },
        });
        try self.addExport(module, name, .func, addr);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Store — init and deinit" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.functions.items.len);
    try testing.expectEqual(@as(usize, 0), store.memories.items.len);
}

test "Store — addFunction and getFunction" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const addr = try store.addFunction(.{
        .params = &[_]ValType{ .i32, .i32 },
        .results = &[_]ValType{.i32},
        .subtype = .{ .host_function = .{ .func = undefined, .context = 0 } },
    });

    try testing.expectEqual(@as(usize, 0), addr);
    const func = try store.getFunction(0);
    try testing.expectEqual(@as(usize, 2), func.params.len);
    try testing.expectEqual(@as(usize, 1), func.results.len);
}

test "Store — addMemory and getMemory" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const addr = try store.addMemory(1, 10);
    const m = try store.getMemory(addr);
    try testing.expectEqual(@as(u32, 1), m.min);
    try testing.expectEqual(@as(u32, 10), m.max.?);
}

test "Store — addTable and getTable" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const addr = try store.addTable(.funcref, 4, 16);
    const t = try store.getTable(addr);
    try testing.expectEqual(@as(u32, 4), t.size());
    try testing.expectEqual(@as(u32, 16), t.max.?);
}

test "Store — addGlobal and getGlobal" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const addr = try store.addGlobal(.{
        .value = 42,
        .valtype = .i32,
        .mutability = .mutable,
    });
    const g = try store.getGlobal(addr);
    try testing.expectEqual(@as(u64, 42), g.value);
    try testing.expectEqual(Mutability.mutable, g.mutability);
}

test "Store — lookupImport and addExport" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addExport("env", "memory", .memory, 0);
    const handle = try store.lookupImport("env", "memory", .memory);
    try testing.expectEqual(@as(usize, 0), handle);

    try testing.expectError(error.ImportNotFound, store.lookupImport("env", "missing", .memory));
    try testing.expectError(error.ImportNotFound, store.lookupImport("other", "memory", .memory));
}

test "Store — exposeHostFunction" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const dummy_fn: HostFn = @ptrFromInt(@intFromPtr(&struct {
        fn f(_: *anyopaque, _: usize) anyerror!void {}
    }.f));

    try store.exposeHostFunction(
        "env",
        "print",
        dummy_fn,
        0,
        &[_]ValType{.i32},
        &[_]ValType{},
    );

    const handle = try store.lookupImport("env", "print", .func);
    try testing.expectEqual(@as(usize, 0), handle);
    const func = try store.getFunction(handle);
    try testing.expectEqual(@as(usize, 1), func.params.len);
}

test "Store — bad index errors" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expectError(error.BadFunctionIndex, store.getFunction(0));
    try testing.expectError(error.BadMemoryIndex, store.getMemory(0));
    try testing.expectError(error.BadTableIndex, store.getTable(0));
    try testing.expectError(error.BadGlobalIndex, store.getGlobal(0));
}

test "Table — init, set, get, lookup" {
    var t = try Table.init(testing.allocator, .funcref, 4, 8);
    defer t.deinit();

    try testing.expectEqual(@as(u32, 4), t.size());

    // All entries start as null
    try testing.expect((try t.get(0)) == null);

    // Set and lookup
    try t.set(0, 42);
    try testing.expectEqual(@as(usize, 42), try t.lookup(0));

    // Null entry lookup fails
    try testing.expectError(error.UndefinedElement, t.lookup(1));
}

test "Table — grow" {
    var t = try Table.init(testing.allocator, .funcref, 2, 6);
    defer t.deinit();

    const old = try t.grow(2, null);
    try testing.expectEqual(@as(u32, 2), old);
    try testing.expectEqual(@as(u32, 4), t.size());

    // Grow with init value
    _ = try t.grow(1, 99);
    try testing.expectEqual(@as(usize, 99), try t.lookup(4));

    // Grow beyond max fails
    try testing.expectError(error.OutOfBounds, t.grow(2, null));
}

test "Elem — init, set, deinit" {
    var e = try Elem.init(testing.allocator, .funcref, 3);
    defer e.deinit();

    e.set(0, 10);
    e.set(1, 20);
    e.set(2, 30);
    try testing.expectEqual(@as(u32, 10), e.data[0]);
    try testing.expectEqual(@as(u32, 30), e.data[2]);
}

test "Data — init, set, deinit" {
    var d = try Data.init(testing.allocator, 5);
    defer d.deinit();

    d.set(0, 0xAA);
    d.set(4, 0xBB);
    try testing.expectEqual(@as(u8, 0xAA), d.data[0]);
    try testing.expectEqual(@as(u8, 0xBB), d.data[4]);
}
