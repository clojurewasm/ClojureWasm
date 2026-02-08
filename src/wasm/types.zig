// Wasm InterOp types — Value wrappers for Wasm module interaction (Phase 25).
//
// Provides WasmModule and WasmFunction types that wrap the custom Wasm runtime's
// Store/Module/Instance into ClojureWasm's Value system. These become first-class
// Clojure values accessible via (wasm/load ...) and (wasm/fn ...).

const std = @import("std");
const Allocator = std.mem.Allocator;
const wit_parser = @import("wit_parser.zig");

// Custom Wasm runtime (Phase 35W)
const rt = struct {
    const store_mod = @import("runtime/store.zig");
    const module_mod = @import("runtime/module.zig");
    const instance_mod = @import("runtime/instance.zig");
    const vm_mod = @import("runtime/vm.zig");
    const wasi = @import("runtime/wasi.zig");
    const opcode = @import("runtime/opcode.zig");
};

/// Wasm value types exposed to Clojure code.
pub const WasmValType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn fromRuntime(vt: rt.opcode.ValType) ?WasmValType {
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
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
/// Heap-allocated because Instance holds internal pointers — the
/// struct must not move after instantiation.
pub const WasmModule = struct {
    allocator: Allocator,
    store: rt.store_mod.Store,
    module: rt.module_mod.Module,
    instance: rt.instance_mod.Instance,
    wasi_ctx: ?rt.wasi.WasiContext = null,
    export_fns: []const ExportInfo = &[_]ExportInfo{},
    /// Pre-generated WasmFn instances for keyword lookup dispatch.
    cached_fns: []WasmFn = &[_]WasmFn{},
    /// WIT function signatures (set via wasm/load :wit option).
    wit_funcs: []const wit_parser.WitFunc = &[_]wit_parser.WitFunc{},
    /// Cached VM instance — reused across invoke() calls to avoid stack reallocation.
    vm: *rt.vm_mod.Vm = undefined,

    /// Load a Wasm module from binary bytes, decode, and instantiate.
    /// Returns a heap-allocated WasmModule (pointer-stable).
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
        self.store = rt.store_mod.Store.init(allocator);
        errdefer self.store.deinit();

        self.module = rt.module_mod.Module.init(allocator, wasm_bytes);
        errdefer self.module.deinit();
        try self.module.decode();

        if (wasi) {
            try rt.wasi.registerAll(&self.store, &self.module);
            self.wasi_ctx = rt.wasi.WasiContext.init(allocator);
        } else {
            self.wasi_ctx = null;
        }
        errdefer if (self.wasi_ctx) |*wc| wc.deinit();

        if (imports_map) |im| try registerHostFunctions(&self.store, &self.module, im, allocator);

        self.instance = rt.instance_mod.Instance.init(allocator, &self.store, &self.module);
        errdefer self.instance.deinit();
        if (self.wasi_ctx) |*wc| self.instance.wasi = wc;
        try self.instance.instantiate();

        self.export_fns = buildExportInfo(allocator, &self.module) catch &[_]ExportInfo{};
        self.cached_fns = buildCachedFns(allocator, self) catch &[_]WasmFn{};
        self.wit_funcs = &[_]wit_parser.WitFunc{};

        self.vm = try allocator.create(rt.vm_mod.Vm);
        self.vm.* = rt.vm_mod.Vm.init(allocator);

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
        allocator.destroy(self.vm);
        self.instance.deinit();
        if (self.wasi_ctx) |*wc| wc.deinit();
        self.module.deinit();
        self.store.deinit();
        allocator.destroy(self);
    }

    /// Invoke an exported function by name.
    /// Args and results are passed as u64 arrays.
    pub fn invoke(self: *WasmModule, name: []const u8, args: []u64, results: []u64) !void {
        self.vm.reset();
        try self.vm.invoke(&self.instance, name, args, results);
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

    /// Attach WIT info parsed from a .wit file.
    pub fn setWitInfo(self: *WasmModule, funcs: []const wit_parser.WitFunc) void {
        self.wit_funcs = funcs;
        for (self.cached_fns) |*cf| {
            for (funcs) |wf| {
                if (std.mem.eql(u8, cf.name, wf.name)) {
                    cf.wit_params = wf.params;
                    cf.wit_result = wf.result;
                    break;
                }
            }
        }
    }

    /// Get WIT function info by name.
    pub fn getWitFunc(self: *const WasmModule, name: []const u8) ?wit_parser.WitFunc {
        for (self.wit_funcs) |wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
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
    /// WIT-level parameter types (null = no WIT info, use raw core types).
    wit_params: ?[]const wit_parser.WitParam = null,
    /// WIT-level result type (null = no WIT info).
    wit_result: ?wit_parser.WitType = null,

    /// Call this Wasm function with Clojure Value arguments.
    pub fn call(self: *const WasmFn, allocator: Allocator, args: []const Value) !Value {
        // WIT marshalling path
        if (self.wit_params) |wps| {
            return self.callWithWitMarshalling(allocator, args, wps);
        }

        // Core-type path (no WIT)
        if (args.len != self.param_types.len)
            return error.ArityError;

        var wasm_args: [16]u64 = undefined;
        for (args, 0..) |arg, i| {
            wasm_args[i] = try valueToWasm(arg, self.param_types[i]);
        }

        var wasm_results: [4]u64 = undefined;
        try self.module.invoke(
            self.name,
            wasm_args[0..args.len],
            wasm_results[0..self.result_types.len],
        );

        if (self.result_types.len == 0) return Value.nil_val;
        return wasmToValue(allocator, wasm_results[0], self.result_types[0]);
    }

    /// WIT-aware call: handles string marshalling via cabi_realloc + memory.
    fn callWithWitMarshalling(self: *const WasmFn, allocator: Allocator, args: []const Value, wit_params: []const wit_parser.WitParam) !Value {
        if (args.len != wit_params.len) return error.ArityError;

        var wasm_args: [32]u64 = undefined;
        var wasm_arg_count: usize = 0;

        for (args, 0..) |arg, i| {
            switch (wit_params[i].type_) {
                .string => {
                    const str = switch (arg.tag()) {
                        .string => arg.asString(),
                        else => return error.TypeError,
                    };
                    const ptr = try self.cabiRealloc(@intCast(str.len));
                    try self.module.memoryWrite(ptr, str);
                    wasm_args[wasm_arg_count] = ptr;
                    wasm_arg_count += 1;
                    wasm_args[wasm_arg_count] = str.len;
                    wasm_arg_count += 1;
                },
                else => {
                    wasm_args[wasm_arg_count] = try valueToWasm(arg, self.param_types[wasm_arg_count]);
                    wasm_arg_count += 1;
                },
            }
        }

        var wasm_results: [8]u64 = undefined;
        try self.module.invoke(
            self.name,
            wasm_args[0..wasm_arg_count],
            wasm_results[0..self.result_types.len],
        );

        const wit_result = self.wit_result orelse {
            if (self.result_types.len == 0) return Value.nil_val;
            return wasmToValue(allocator, wasm_results[0], self.result_types[0]);
        };

        switch (wit_result) {
            .string => {
                if (self.result_types.len < 2) return error.TypeError;
                const len: u32 = @truncate(wasm_results[0]);
                const ptr: u32 = @truncate(wasm_results[1]);
                const bytes = try self.module.memoryRead(allocator, ptr, len);
                return Value.initString(allocator, bytes);
            },
            else => {
                if (self.result_types.len == 0) return Value.nil_val;
                return wasmToValue(allocator, wasm_results[0], self.result_types[0]);
            },
        }
    }

    fn cabiRealloc(self: *const WasmFn, size: u32) !u32 {
        var realloc_args = [_]u64{ 0, 0, 1, size };
        var realloc_results = [_]u64{0};
        self.module.invoke("cabi_realloc", &realloc_args, &realloc_results) catch
            return error.WasmAllocError;
        return @truncate(realloc_results[0]);
    }
};

const Value = @import("../common/value.zig").Value;

/// Convert a Clojure Value to a Wasm u64 based on the expected type.
fn valueToWasm(val: Value, wasm_type: WasmValType) !u64 {
    return switch (wasm_type) {
        .i32 => switch (val.tag()) {
            .integer => @bitCast(@as(i64, @intCast(@as(i32, @intCast(val.asInteger()))))),
            .boolean => if (val.asBoolean()) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .i64 => switch (val.tag()) {
            .integer => @bitCast(val.asInteger()),
            .boolean => if (val.asBoolean()) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .f32 => switch (val.tag()) {
            .float => @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(val.asFloat()))))),
            .integer => @as(u64, @as(u32, @bitCast(@as(f32, @floatFromInt(val.asInteger()))))),
            else => return error.TypeError,
        },
        .f64 => switch (val.tag()) {
            .float => @bitCast(val.asFloat()),
            .integer => @bitCast(@as(f64, @floatFromInt(val.asInteger()))),
            else => return error.TypeError,
        },
    };
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

/// Trampoline: called by custom VM, invokes the Clojure function.
fn hostTrampoline(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const vm: *rt.vm_mod.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx = host_contexts[context_id] orelse return error.Trap;

    // Pop args from VM stack (reverse order)
    var args_buf: [16]Value = undefined;
    const pc = ctx.param_count;
    if (pc > 16) return error.Trap;

    var i: u32 = pc;
    while (i > 0) {
        i -= 1;
        const raw = vm.popOperand();
        args_buf[i] = Value.initInteger(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))));
    }

    // Call the Clojure function
    const result = bootstrap.callFnVal(ctx.allocator, ctx.clj_fn, args_buf[0..pc]) catch {
        return error.Trap;
    };

    // Push result to VM stack
    if (ctx.result_count > 0) {
        const raw: u64 = switch (result.tag()) {
            .integer => @bitCast(@as(i64, @intCast(@as(i32, @intCast(result.asInteger()))))),
            .float => @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(result.asFloat()))))),
            .nil => 0,
            .boolean => if (result.asBoolean()) @as(u64, 1) else 0,
            else => 0,
        };
        try vm.pushOperand(raw);
    }
}

/// Register Clojure functions as Wasm host functions.
/// imports_map: {"module_name" {"func_name" clj-fn}}
pub fn registerHostFunctions(
    store: *rt.store_mod.Store,
    module: *const rt.module_mod.Module,
    imports_map: Value,
    allocator: Allocator,
) !void {
    for (module.imports.items) |imp| {
        if (imp.kind != .func) continue;

        // Skip wasi imports (handled separately)
        if (std.mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;

        if (imp.index >= module.types.items.len) continue;
        const functype = module.types.items[imp.index];

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
fn buildExportInfo(allocator: Allocator, module: *const rt.module_mod.Module) ![]const ExportInfo {
    var func_count: usize = 0;
    for (module.exports.items) |exp| {
        if (exp.kind == .func) func_count += 1;
    }
    if (func_count == 0) return &[_]ExportInfo{};

    const infos = try allocator.alloc(ExportInfo, func_count);
    errdefer allocator.free(infos);

    var idx: usize = 0;
    for (module.exports.items) |exp| {
        if (exp.kind != .func) continue;

        const functype = module.getFuncType(exp.index) orelse continue;

        const params = try allocator.alloc(WasmValType, functype.params.len);
        errdefer allocator.free(params);
        var valid = true;
        for (functype.params, 0..) |p, i| {
            params[i] = WasmValType.fromRuntime(p) orelse {
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
            results[i] = WasmValType.fromRuntime(r) orelse {
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

    if (idx < func_count) {
        if (idx == 0) {
            allocator.free(infos);
            return &[_]ExportInfo{};
        }
        const trimmed = try allocator.alloc(ExportInfo, idx);
        @memcpy(trimmed, infos[0..idx]);
        allocator.free(infos);
        return trimmed;
    }

    return infos;
}

/// Pre-generate WasmFn instances for all exports (used by keyword dispatch).
fn buildCachedFns(allocator: Allocator, wasm_mod: *WasmModule) ![]WasmFn {
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
    const alloc = std.heap.page_allocator;
    const mod_key = Value.initString(alloc, module_name);
    const sub_map_val = switch (imports_map.tag()) {
        .map => imports_map.asMap().get(mod_key),
        .hash_map => imports_map.asHashMap().get(mod_key),
        else => null,
    } orelse return null;

    const fn_key = Value.initString(alloc, func_name);
    return switch (sub_map_val.tag()) {
        .map => sub_map_val.asMap().get(fn_key),
        .hash_map => sub_map_val.asHashMap().get(fn_key),
        else => null,
    };
}

/// Convert a Wasm u64 result to a Clojure Value based on the result type.
fn wasmToValue(_: Allocator, raw: u64, wasm_type: WasmValType) Value {
    return switch (wasm_type) {
        .i32 => Value.initInteger(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw)))))),
        .i64 => Value.initInteger(@bitCast(raw)),
        .f32 => Value.initFloat(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw)))))),
        .f64 => Value.initFloat(@bitCast(raw)),
    };
}

// === Tests ===

const testing = std.testing;

test "smoke test — load and call add(3, 4)" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);

    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "smoke test — fibonacci(10) = 55" {
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

    try wasm_mod.memoryWrite(0, "Hello");
    const read_back = try wasm_mod.memoryRead(testing.allocator, 0, 5);
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("Hello", read_back);

    try wasm_mod.memoryWrite(1024, "Wasm");
    const read2 = try wasm_mod.memoryRead(testing.allocator, 1024, 4);
    defer testing.allocator.free(read2);
    try testing.expectEqualStrings("Wasm", read2);
}

test "memory write then call store/load" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var store_args = [_]u64{ 0, 42 };
    var store_results = [_]u64{};
    try wasm_mod.invoke("store", &store_args, &store_results);

    var load_args = [_]u64{0};
    var load_results = [_]u64{0};
    try wasm_mod.invoke("load", &load_args, &load_results);
    try testing.expectEqual(@as(u64, 42), load_results[0]);

    const raw = try wasm_mod.memoryRead(testing.allocator, 0, 4);
    defer testing.allocator.free(raw);
    const value = std.mem.readInt(u32, raw[0..4], .little);
    try testing.expectEqual(@as(u32, 42), value);
}

test "allocContext — allocate and reclaim slots" {
    const saved_contexts = host_contexts;
    const saved_next = next_context_id;
    defer {
        host_contexts = saved_contexts;
        next_context_id = saved_next;
    }

    host_contexts = [_]?HostContext{null} ** MAX_CONTEXTS;
    next_context_id = 0;

    const ctx = HostContext{
        .clj_fn = Value.nil_val,
        .param_count = 1,
        .result_count = 0,
        .allocator = testing.allocator,
    };

    const id0 = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 0), id0);

    const id1 = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 1), id1);

    host_contexts[0] = null;
    next_context_id = 0;
    const id_reused = try allocContext(ctx);
    try testing.expectEqual(@as(usize, 0), id_reused);
}

test "lookupImportFn — nested map lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const collections = @import("../common/collections.zig");

    const target_val = Value.initKeyword(alloc, .{ .name = "found", .ns = null });
    var inner_entries = [_]Value{
        Value.initString(alloc, "print_i32"), target_val,
    };
    const inner_map = try alloc.create(collections.PersistentArrayMap);
    inner_map.* = .{ .entries = &inner_entries };

    var outer_entries = [_]Value{
        Value.initString(alloc, "env"), Value.initMap(inner_map),
    };
    const outer_map = try alloc.create(collections.PersistentArrayMap);
    outer_map.* = .{ .entries = &outer_entries };

    const imports = Value.initMap(outer_map);

    const result = lookupImportFn(imports, "env", "print_i32");
    try testing.expect(result != null);
    try testing.expect(result.?.eql(target_val));

    try testing.expect(lookupImportFn(imports, "env", "missing") == null);
    try testing.expect(lookupImportFn(imports, "other", "print_i32") == null);
}

test "buildExportInfo — add module exports" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

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
