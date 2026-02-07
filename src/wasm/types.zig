// Wasm InterOp types — Value wrappers for Wasm module interaction (Phase 25).
//
// Provides WasmModule and WasmFunction types that wrap zware's Store/Module/
// Instance into ClojureWasm's Value system. These become first-class Clojure
// values accessible via (wasm/load ...) and (wasm/fn ...).

const std = @import("std");
const zware = @import("zware");
const Allocator = std.mem.Allocator;

/// Wasm value types exposed to Clojure code.
pub const WasmValType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn toZware(self: WasmValType) zware.ValType {
        return switch (self) {
            .i32 => .I32,
            .i64 => .I64,
            .f32 => .F32,
            .f64 => .F64,
        };
    }

    pub fn fromZware(vt: zware.ValType) ?WasmValType {
        return switch (vt) {
            .I32 => .i32,
            .I64 => .i64,
            .F32 => .f32,
            .F64 => .f64,
            else => null,
        };
    }
};

/// Export function signature — extracted from Wasm binary at load time.
pub const ExportInfo = struct {
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,
};

/// A loaded and instantiated Wasm module.
/// Heap-allocated because zware Instance holds a *Store pointer — the
/// struct must not move after instantiation.
pub const WasmModule = struct {
    allocator: Allocator,
    store: zware.Store,
    module: zware.Module,
    instance: zware.Instance,
    export_fns: []const ExportInfo = &[_]ExportInfo{},
    /// Pre-generated WasmFn instances for keyword lookup dispatch.
    cached_fns: []const WasmFn = &[_]WasmFn{},

    /// Load a Wasm module from binary bytes, decode, and instantiate.
    /// Returns a heap-allocated WasmModule (pointer-stable for zware).
    pub fn load(allocator: Allocator, wasm_bytes: []const u8) !*WasmModule {
        return loadCore(allocator, wasm_bytes, false, null);
    }

    /// Load a WASI module — registers wasi_snapshot_preview1 imports.
    pub fn loadWasi(allocator: Allocator, wasm_bytes: []const u8) !*WasmModule {
        return loadCore(allocator, wasm_bytes, true, null);
    }

    /// Load with host function imports (Clojure fns callable from Wasm).
    pub fn loadWithImports(allocator: Allocator, wasm_bytes: []const u8, imports_map: Value) !*WasmModule {
        return loadCore(allocator, wasm_bytes, false, imports_map);
    }

    fn loadCore(allocator: Allocator, wasm_bytes: []const u8, wasi: bool, imports_map: ?Value) !*WasmModule {
        const self = try allocator.create(WasmModule);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.store = zware.Store.init(allocator);
        errdefer self.store.deinit();

        self.module = zware.Module.init(allocator, wasm_bytes);
        errdefer self.module.deinit();
        try self.module.decode();

        if (wasi) try registerWasiFunctions(&self.store, &self.module);
        if (imports_map) |im| try registerHostFunctions(&self.store, &self.module, im, allocator);

        self.instance = zware.Instance.init(allocator, &self.store, self.module);
        errdefer self.instance.deinit();
        try self.instance.instantiate();

        self.export_fns = buildExportInfo(allocator, &self.module) catch &[_]ExportInfo{};
        self.cached_fns = buildCachedFns(allocator, self) catch &[_]WasmFn{};

        return self;
    }

    pub fn deinit(self: *WasmModule) void {
        const allocator = self.allocator;
        // Free cached WasmFn instances
        if (self.cached_fns.len > 0) allocator.free(self.cached_fns);
        // Free export info
        for (self.export_fns) |ei| {
            allocator.free(ei.param_types);
            allocator.free(ei.result_types);
        }
        if (self.export_fns.len > 0) allocator.free(self.export_fns);
        self.instance.deinit();
        self.module.deinit();
        self.store.deinit();
        allocator.destroy(self);
    }

    /// Invoke an exported function by name.
    /// Args and results are passed as u64 arrays (zware convention).
    pub fn invoke(self: *WasmModule, name: []const u8, args: []u64, results: []u64) !void {
        try self.instance.invoke(name, args, results, .{});
    }

    /// Read bytes from linear memory at the given offset.
    pub fn memoryRead(self: *WasmModule, allocator: Allocator, offset: u32, length: u32) ![]const u8 {
        const mem = try self.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const end = @as(u64, offset) + @as(u64, length);
        if (end > mem_bytes.len) return error.OutOfBoundsMemoryAccess;
        const result = try allocator.alloc(u8, length);
        @memcpy(result, mem_bytes[offset..][0..length]);
        return result;
    }

    /// Write bytes to linear memory at the given offset.
    pub fn memoryWrite(self: *WasmModule, offset: u32, data: []const u8) !void {
        const mem = try self.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const end = @as(u64, offset) + @as(u64, data.len);
        if (end > mem_bytes.len) return error.OutOfBoundsMemoryAccess;
        @memcpy(mem_bytes[offset..][0..data.len], data);
    }

    /// Lookup export function info by name.
    pub fn getExportInfo(self: *const WasmModule, name: []const u8) ?ExportInfo {
        for (self.export_fns) |ei| {
            if (std.mem.eql(u8, ei.name, name)) return ei;
        }
        return null;
    }

    /// Lookup a cached WasmFn by export name (for keyword dispatch).
    pub fn getExportFn(self: *const WasmModule, name: []const u8) ?*const WasmFn {
        for (self.cached_fns) |*wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
    }
};

/// A bound Wasm function — module ref + export name + signature.
/// Returned by (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}).
/// Callable as a first-class Clojure function via callFnVal dispatch.
pub const WasmFn = struct {
    module: *WasmModule,
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,

    /// Call this Wasm function with Clojure Value arguments.
    /// Converts Value args to u64[], invokes via zware, converts results back.
    pub fn call(self: *const WasmFn, allocator: Allocator, args: []const Value) !Value {
        if (args.len != self.param_types.len)
            return error.ArityError;

        // Convert Clojure Values to u64 args
        var wasm_args: [16]u64 = undefined;
        for (args, 0..) |arg, i| {
            wasm_args[i] = try valueToWasm(arg, self.param_types[i]);
        }

        // Invoke
        var wasm_results: [4]u64 = undefined;
        try self.module.invoke(
            self.name,
            wasm_args[0..args.len],
            wasm_results[0..self.result_types.len],
        );

        // Convert results back to Clojure Values
        if (self.result_types.len == 0) return Value.nil;
        return wasmToValue(allocator, wasm_results[0], self.result_types[0]);
    }
};

const Value = @import("../common/value.zig").Value;

/// Convert a Clojure Value to a Wasm u64 based on the expected type.
fn valueToWasm(val: Value, wasm_type: WasmValType) !u64 {
    return switch (wasm_type) {
        .i32 => switch (val) {
            .integer => |n| @bitCast(@as(i64, @intCast(@as(i32, @intCast(n))))),
            .boolean => |b| if (b) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .i64 => switch (val) {
            .integer => |n| @bitCast(n),
            .boolean => |b| if (b) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .f32 => switch (val) {
            .float => |f| @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(f))))),
            .integer => |n| @as(u64, @as(u32, @bitCast(@as(f32, @floatFromInt(n))))),
            else => return error.TypeError,
        },
        .f64 => switch (val) {
            .float => |f| @bitCast(f),
            .integer => |n| @bitCast(@as(f64, @floatFromInt(n))),
            else => return error.TypeError,
        },
    };
}

// ============================================================
// WASI Preview 1 support
// ============================================================

/// Known wasi_snapshot_preview1 functions mapped to zware builtins.
const WasiEntry = struct {
    name: []const u8,
    func: *const fn (*zware.VirtualMachine) zware.WasmError!void,
};

const wasi_functions = [_]WasiEntry{
    .{ .name = "args_get", .func = &zware.wasi.args_get },
    .{ .name = "args_sizes_get", .func = &zware.wasi.args_sizes_get },
    .{ .name = "environ_get", .func = &zware.wasi.environ_get },
    .{ .name = "environ_sizes_get", .func = &zware.wasi.environ_sizes_get },
    .{ .name = "clock_time_get", .func = &zware.wasi.clock_time_get },
    .{ .name = "fd_close", .func = &zware.wasi.fd_close },
    .{ .name = "fd_fdstat_get", .func = &zware.wasi.fd_fdstat_get },
    .{ .name = "fd_filestat_get", .func = &zware.wasi.fd_filestat_get },
    .{ .name = "fd_prestat_get", .func = &zware.wasi.fd_prestat_get },
    .{ .name = "fd_prestat_dir_name", .func = &zware.wasi.fd_prestat_dir_name },
    .{ .name = "fd_read", .func = &zware.wasi.fd_read },
    .{ .name = "fd_seek", .func = &zware.wasi.fd_seek },
    .{ .name = "fd_write", .func = &zware.wasi.fd_write },
    .{ .name = "fd_tell", .func = &zware.wasi.fd_tell },
    .{ .name = "fd_readdir", .func = &zware.wasi.fd_readdir },
    .{ .name = "path_filestat_get", .func = &zware.wasi.path_filestat_get },
    .{ .name = "path_open", .func = &zware.wasi.path_open },
    .{ .name = "proc_exit", .func = &zware.wasi.proc_exit },
    .{ .name = "random_get", .func = &zware.wasi.random_get },
};

fn lookupWasiFunc(name: []const u8) ?*const fn (*zware.VirtualMachine) zware.WasmError!void {
    for (wasi_functions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

/// Scan module imports for wasi_snapshot_preview1 functions and register them.
fn registerWasiFunctions(store: *zware.Store, module: *zware.Module) !void {
    for (module.imports.list.items, 0..) |imp, import_idx| {
        if (imp.desc_tag != .Func) continue;
        if (!std.mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;

        const wasi_fn = lookupWasiFunc(imp.name) orelse
            return error.WasmWasiUnsupported;

        const func_entry = module.functions.lookup(import_idx) catch
            return error.WasmDecodeError;
        const functype = module.types.lookup(func_entry.typeidx) catch
            return error.WasmDecodeError;

        // zware WASI functions are fn(*VM) but exposeHostFunction wants fn(*VM, usize).
        // The extra context arg is unused — @ptrCast is safe per zware convention.
        store.exposeHostFunction(
            imp.module,
            imp.name,
            @ptrCast(wasi_fn),
            0,
            functype.params,
            functype.results,
        ) catch return error.WasmInstantiateError;
    }
}

// ============================================================
// Host function injection (Clojure -> Wasm callbacks)
// ============================================================

const bootstrap = @import("../common/bootstrap.zig");

/// Host function callback context — stores Clojure fn + signature.
const HostContext = struct {
    clj_fn: Value,
    param_count: u32,
    result_count: u32,
    allocator: Allocator,
};

/// Global context table (max 256 host functions across all modules).
const MAX_CONTEXTS = 256;
var host_contexts: [MAX_CONTEXTS]?HostContext = [_]?HostContext{null} ** MAX_CONTEXTS;
var next_context_id: usize = 0;

fn allocContext(ctx: HostContext) !usize {
    var id = next_context_id;
    var tried: usize = 0;
    while (tried < MAX_CONTEXTS) : ({
        id = (id + 1) % MAX_CONTEXTS;
        tried += 1;
    }) {
        if (host_contexts[id] == null) {
            host_contexts[id] = ctx;
            next_context_id = (id + 1) % MAX_CONTEXTS;
            return id;
        }
    }
    return error.WasmHostContextFull;
}

/// Trampoline: called by zware VM, invokes the Clojure function.
fn hostTrampoline(vm: *zware.VirtualMachine, context_id: usize) zware.WasmError!void {
    const ctx = host_contexts[context_id] orelse return zware.WasmError.Trap;

    // Pop args from zware stack (reverse order)
    var args_buf: [16]Value = undefined;
    const pc = ctx.param_count;
    if (pc > 16) return zware.WasmError.Trap;

    var i: u32 = pc;
    while (i > 0) {
        i -= 1;
        const raw = vm.popAnyOperand();
        // Default to i32 conversion for host function args
        args_buf[i] = .{ .integer = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))) };
    }

    // Call the Clojure function
    const result = bootstrap.callFnVal(ctx.allocator, ctx.clj_fn, args_buf[0..pc]) catch {
        return zware.WasmError.Trap;
    };

    // Push result to zware stack
    if (ctx.result_count > 0) {
        const raw: u64 = switch (result) {
            .integer => |n| @bitCast(@as(i64, @intCast(@as(i32, @intCast(n))))),
            .float => |f| @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(f))))),
            .nil => 0,
            .boolean => |b| if (b) @as(u64, 1) else 0,
            else => 0,
        };
        vm.pushOperand(u64, raw) catch return zware.WasmError.Trap;
    }
}

/// Register Clojure functions as Wasm host functions.
/// imports_map: {"module_name" {"func_name" clj-fn}}
pub fn registerHostFunctions(
    store: *zware.Store,
    module: *zware.Module,
    imports_map: Value,
    allocator: Allocator,
) !void {
    for (module.imports.list.items, 0..) |imp, import_idx| {
        if (imp.desc_tag != .Func) continue;

        const func_entry = module.functions.lookup(import_idx) catch continue;
        const functype = module.types.lookup(func_entry.typeidx) catch continue;

        const clj_fn = lookupImportFn(imports_map, imp.module, imp.name) orelse continue;

        const ctx_id = allocContext(.{
            .clj_fn = clj_fn,
            .param_count = @intCast(functype.params.len),
            .result_count = @intCast(functype.results.len),
            .allocator = allocator,
        }) catch return error.WasmHostContextFull;

        store.exposeHostFunction(
            imp.module,
            imp.name,
            &hostTrampoline,
            ctx_id,
            functype.params,
            functype.results,
        ) catch {
            host_contexts[ctx_id] = null;
            return error.WasmInstantiateError;
        };
    }
}

/// Build export function info by introspecting the Wasm binary's exports + types.
fn buildExportInfo(allocator: Allocator, module: *zware.Module) ![]const ExportInfo {
    // Count function exports
    var func_count: usize = 0;
    for (module.exports.list.items) |exp| {
        if (exp.tag == .Func) func_count += 1;
    }
    if (func_count == 0) return &[_]ExportInfo{};

    const infos = try allocator.alloc(ExportInfo, func_count);
    errdefer allocator.free(infos);

    var idx: usize = 0;
    for (module.exports.list.items) |exp| {
        if (exp.tag != .Func) continue;

        const func_entry = module.functions.lookup(exp.index) catch continue;
        const functype = module.types.lookup(func_entry.typeidx) catch continue;

        // Convert zware ValType slices to WasmValType slices
        const params = try allocator.alloc(WasmValType, functype.params.len);
        errdefer allocator.free(params);
        var valid = true;
        for (functype.params, 0..) |p, i| {
            params[i] = WasmValType.fromZware(p) orelse {
                valid = false;
                break;
            };
        }
        if (!valid) {
            allocator.free(params);
            continue;
        }

        const results = try allocator.alloc(WasmValType, functype.results.len);
        errdefer allocator.free(results);
        for (functype.results, 0..) |r, i| {
            results[i] = WasmValType.fromZware(r) orelse {
                valid = false;
                break;
            };
        }
        if (!valid) {
            allocator.free(params);
            allocator.free(results);
            continue;
        }

        infos[idx] = .{
            .name = exp.name,
            .param_types = params,
            .result_types = results,
        };
        idx += 1;
    }

    // If some exports were skipped (unsupported types), shrink
    if (idx < func_count) {
        if (idx == 0) {
            allocator.free(infos);
            return &[_]ExportInfo{};
        }
        // Just return the full allocation — unused slots are harmless
        // since we track idx. Actually, we need to return the right length.
        const trimmed = try allocator.alloc(ExportInfo, idx);
        @memcpy(trimmed, infos[0..idx]);
        allocator.free(infos);
        return trimmed;
    }

    return infos;
}

/// Pre-generate WasmFn instances for all exports (used by keyword dispatch).
fn buildCachedFns(allocator: Allocator, wasm_mod: *WasmModule) ![]const WasmFn {
    const exports = wasm_mod.export_fns;
    if (exports.len == 0) return &[_]WasmFn{};

    const fns = try allocator.alloc(WasmFn, exports.len);
    for (exports, 0..) |ei, i| {
        fns[i] = .{
            .module = wasm_mod,
            .name = ei.name,
            .param_types = ei.param_types,
            .result_types = ei.result_types,
        };
    }
    return fns;
}

/// Lookup a Clojure function from the nested imports map.
fn lookupImportFn(imports_map: Value, module_name: []const u8, func_name: []const u8) ?Value {
    const mod_key = Value{ .string = module_name };
    const sub_map_val = switch (imports_map) {
        .map => |m| m.get(mod_key),
        .hash_map => |hm| hm.get(mod_key),
        else => null,
    } orelse return null;

    const fn_key = Value{ .string = func_name };
    return switch (sub_map_val) {
        .map => |m| m.get(fn_key),
        .hash_map => |hm| hm.get(fn_key),
        else => null,
    };
}

/// Convert a Wasm u64 result to a Clojure Value based on the result type.
fn wasmToValue(_: Allocator, raw: u64, wasm_type: WasmValType) Value {
    return switch (wasm_type) {
        .i32 => .{ .integer = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))) },
        .i64 => .{ .integer = @bitCast(raw) },
        .f32 => .{ .float = @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw))))) },
        .f64 => .{ .float = @bitCast(raw) },
    };
}

// === Tests ===

const testing = std.testing;

test "zware smoke test — load and call add(3, 4)" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);

    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "zware smoke test — fibonacci(10) = 55" {
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{10};
    var results = [_]u64{0};
    try wasm_mod.invoke("fib", &args, &results);

    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "memory read/write round-trip" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // Write "Hello" at offset 0
    try wasm_mod.memoryWrite(0, "Hello");
    const read_back = try wasm_mod.memoryRead(testing.allocator, 0, 5);
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("Hello", read_back);

    // Write at higher offset
    try wasm_mod.memoryWrite(1024, "Wasm");
    const read2 = try wasm_mod.memoryRead(testing.allocator, 1024, 4);
    defer testing.allocator.free(read2);
    try testing.expectEqualStrings("Wasm", read2);
}

test "memory write then call store/load" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // Use Wasm store function to write value 42 at offset 0
    var store_args = [_]u64{ 0, 42 };
    var store_results = [_]u64{};
    try wasm_mod.invoke("store", &store_args, &store_results);

    // Read it back with Wasm load function
    var load_args = [_]u64{0};
    var load_results = [_]u64{0};
    try wasm_mod.invoke("load", &load_args, &load_results);
    try testing.expectEqual(@as(u64, 42), load_results[0]);

    // Also read via memoryRead (4 bytes = i32, little-endian)
    const raw = try wasm_mod.memoryRead(testing.allocator, 0, 4);
    defer testing.allocator.free(raw);
    const value = std.mem.readInt(u32, raw[0..4], .little);
    try testing.expectEqual(@as(u32, 42), value);
}

test "WasmValType conversion" {
    try testing.expectEqual(zware.ValType.I32, WasmValType.i32.toZware());
    try testing.expectEqual(zware.ValType.F64, WasmValType.f64.toZware());
    try testing.expectEqual(WasmValType.i64, WasmValType.fromZware(.I64).?);
    try testing.expect(WasmValType.fromZware(.FuncRef) == null);
}

test "allocContext — allocate and reclaim slots" {
    // Save and restore global state
    const saved_contexts = host_contexts;
    const saved_next = next_context_id;
    defer {
        host_contexts = saved_contexts;
        next_context_id = saved_next;
    }

    // Reset context table
    host_contexts = [_]?HostContext{null} ** MAX_CONTEXTS;
    next_context_id = 0;

    const ctx = HostContext{
        .clj_fn = Value.nil,
        .param_count = 1,
        .result_count = 0,
        .allocator = testing.allocator,
    };

    const id0 = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 0), id0);

    const id1 = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 1), id1);

    // Free slot 0 and reallocate
    host_contexts[0] = null;
    next_context_id = 0;
    const id_reused = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 0), id_reused);
}

test "lookupImportFn — nested map lookup" {
    const collections = @import("../common/collections.zig");

    // Build {"env" {"print_i32" :found}}
    const target_val = Value{ .keyword = .{ .name = "found", .ns = null } };
    var inner_entries = [_]Value{
        .{ .string = "print_i32" }, target_val,
    };
    const inner_map = try testing.allocator.create(collections.PersistentArrayMap);
    defer testing.allocator.destroy(inner_map);
    inner_map.* = .{ .entries = &inner_entries };

    var outer_entries = [_]Value{
        .{ .string = "env" }, .{ .map = inner_map },
    };
    const outer_map = try testing.allocator.create(collections.PersistentArrayMap);
    defer testing.allocator.destroy(outer_map);
    outer_map.* = .{ .entries = &outer_entries };

    const imports = Value{ .map = outer_map };

    // Found
    const result = lookupImportFn(imports, "env", "print_i32");
    try testing.expect(result != null);
    try testing.expect(result.?.eql(target_val));

    // Not found — wrong function name
    try testing.expect(lookupImportFn(imports, "env", "missing") == null);

    // Not found — wrong module name
    try testing.expect(lookupImportFn(imports, "other", "print_i32") == null);
}

test "buildExportInfo — add module exports" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // 01_add.wasm exports "add" with (i32, i32) -> i32
    try testing.expect(wasm_mod.export_fns.len > 0);
    const add_info = wasm_mod.getExportInfo("add");
    try testing.expect(add_info != null);
    const info = add_info.?;
    try testing.expectEqual(@as(usize, 2), info.param_types.len);
    try testing.expectEqual(WasmValType.i32, info.param_types[0]);
    try testing.expectEqual(WasmValType.i32, info.param_types[1]);
    try testing.expectEqual(@as(usize, 1), info.result_types.len);
    try testing.expectEqual(WasmValType.i32, info.result_types[0]);
}

test "buildExportInfo — fibonacci module exports" {
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // 02_fibonacci.wasm exports "fib" with (i32) -> i32
    const fib_info = wasm_mod.getExportInfo("fib");
    try testing.expect(fib_info != null);
    const info = fib_info.?;
    try testing.expectEqual(@as(usize, 1), info.param_types.len);
    try testing.expectEqual(WasmValType.i32, info.param_types[0]);
    try testing.expectEqual(@as(usize, 1), info.result_types.len);
    try testing.expectEqual(WasmValType.i32, info.result_types[0]);
}

test "buildExportInfo — memory module exports" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // 03_memory.wasm exports "store" (i32, i32) -> void and "load" (i32) -> i32
    const store_info = wasm_mod.getExportInfo("store");
    try testing.expect(store_info != null);
    try testing.expectEqual(@as(usize, 2), store_info.?.param_types.len);
    try testing.expectEqual(@as(usize, 0), store_info.?.result_types.len);

    const load_info = wasm_mod.getExportInfo("load");
    try testing.expect(load_info != null);
    try testing.expectEqual(@as(usize, 1), load_info.?.param_types.len);
    try testing.expectEqual(@as(usize, 1), load_info.?.result_types.len);
}

test "getExportInfo — nonexistent name returns null" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    try testing.expect(wasm_mod.getExportInfo("nonexistent") == null);
}
