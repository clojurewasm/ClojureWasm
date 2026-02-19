// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Wasm InterOp types — thin bridge over zwasm runtime.
//!
//! Provides WasmModule and WasmFn types that wrap zwasm's public API
//! into ClojureWasm's Value system. These become first-class Clojure values
//! accessible via (wasm/load ...) and (wasm/fn ...).

const std = @import("std");
const Allocator = std.mem.Allocator;
const wit_parser = @import("wit_parser.zig");
const build_options = @import("build_options");
pub const enable_wasm = build_options.enable_wasm;
const zwasm = if (enable_wasm) @import("zwasm") else struct {};

/// Non-GC allocator for all Wasm internals. Wasm modules and their
/// children (zwasm VM, store, instance, etc.) must not be GC-managed
/// because the GC cannot trace into opaque zwasm data structures.
/// Without this, GC sweeps the ~1MB zwasm VM causing segfaults.
const wasm_alloc = if (enable_wasm) std.heap.smp_allocator else std.heap.page_allocator;

// ============================================================
// CW-specific types
// ============================================================

/// Wasm value types exposed to Clojure code (4-variant subset).
pub const WasmValType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn fromZwasm(vt: if (enable_wasm) zwasm.WasmValType else noreturn) ?WasmValType {
        if (comptime !enable_wasm) unreachable;
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .v128, .funcref, .externref => null,
        };
    }
};

/// Export function signature — extracted from Wasm binary at load time.
pub const ExportInfo = struct {
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,
};

// ============================================================
// WasmModule — delegates to zwasm.WasmModule
// ============================================================

/// A loaded and instantiated Wasm module.
/// Wraps zwasm.WasmModule with CW-specific bookkeeping.
pub const WasmModule = struct {
    inner: if (enable_wasm) *zwasm.WasmModule else *anyopaque,
    allocator: Allocator,
    export_fns: []const ExportInfo,
    cached_fns: []WasmFn,
    wit_funcs: []const wit_parser.WitFunc,
    owned_bytes: []const u8, // wasm binary copy (zwasm stores reference, not copy)

    pub fn load(_: Allocator, wasm_bytes: []const u8) !*WasmModule {
        if (comptime !enable_wasm) @compileError("wasm support not enabled");
        // Copy bytes to non-GC allocator (zwasm Module stores a reference)
        const owned = try wasm_alloc.alloc(u8, wasm_bytes.len);
        @memcpy(owned, wasm_bytes);
        errdefer wasm_alloc.free(owned);
        const inner = try zwasm.WasmModule.load(wasm_alloc, owned);
        return wrapInner(inner, owned);
    }

    pub fn loadWasi(_: Allocator, wasm_bytes: []const u8) !*WasmModule {
        if (comptime !enable_wasm) @compileError("wasm support not enabled");
        const owned = try wasm_alloc.alloc(u8, wasm_bytes.len);
        @memcpy(owned, wasm_bytes);
        errdefer wasm_alloc.free(owned);
        const inner = try zwasm.WasmModule.loadWasiWithOptions(wasm_alloc, owned, .{
            .caps = zwasm.Capabilities.all,
        });
        return wrapInner(inner, owned);
    }

    pub fn loadWithImports(allocator: Allocator, wasm_bytes: []const u8, imports_map: Value) !*WasmModule {
        if (comptime !enable_wasm) @compileError("wasm support not enabled");
        const owned = try wasm_alloc.alloc(u8, wasm_bytes.len);
        @memcpy(owned, wasm_bytes);
        errdefer wasm_alloc.free(owned);

        // Temporary data — use caller's allocator (freed via defer)
        const import_infos = try zwasm.inspectImportFunctions(allocator, owned);
        defer if (import_infos.len > 0) allocator.free(import_infos);

        // Build ImportEntry[] from the Clojure Value map
        const entries = try buildImportEntries(allocator, imports_map, import_infos);
        defer allocator.free(entries);

        const inner = try zwasm.WasmModule.loadWithImports(wasm_alloc, owned, entries);
        return wrapInner(inner, owned);
    }

    fn wrapInner(inner: if (enable_wasm) *zwasm.WasmModule else *anyopaque, owned_bytes: []const u8) !*WasmModule {
        const self = try wasm_alloc.create(WasmModule);
        errdefer wasm_alloc.destroy(self);
        self.inner = inner;
        self.allocator = wasm_alloc;
        self.owned_bytes = owned_bytes;
        self.export_fns = buildExportInfo(wasm_alloc, inner) catch &[_]ExportInfo{};
        self.cached_fns = buildCachedFns(wasm_alloc, self) catch &[_]WasmFn{};
        self.wit_funcs = &[_]wit_parser.WitFunc{};
        return self;
    }

    pub fn deinit(self: *WasmModule) void {
        if (comptime !enable_wasm) return;
        const allocator = self.allocator;
        if (self.cached_fns.len > 0) allocator.free(self.cached_fns);
        for (self.export_fns) |ei| {
            allocator.free(ei.param_types);
            allocator.free(ei.result_types);
        }
        if (self.export_fns.len > 0) allocator.free(self.export_fns);
        self.inner.deinit();
        if (self.owned_bytes.len > 0) allocator.free(self.owned_bytes);
        allocator.destroy(self);
    }

    pub fn invoke(self: *WasmModule, name: []const u8, args: []u64, results: []u64) !void {
        if (comptime !enable_wasm) return error.WasmAllocError;
        try self.inner.invoke(name, args, results);
    }

    pub fn memoryRead(self: *WasmModule, allocator: Allocator, offset: u32, length: u32) ![]const u8 {
        if (comptime !enable_wasm) return error.WasmAllocError;
        return self.inner.memoryRead(allocator, offset, length);
    }

    pub fn memoryWrite(self: *WasmModule, offset: u32, data: []const u8) !void {
        if (comptime !enable_wasm) return error.WasmAllocError;
        return self.inner.memoryWrite(offset, data);
    }

    pub fn setWitInfo(self: *WasmModule, funcs: []const wit_parser.WitFunc) void {
        if (comptime !enable_wasm) return;
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

    pub fn getWitFunc(self: *const WasmModule, name: []const u8) ?wit_parser.WitFunc {
        if (comptime !enable_wasm) return null;
        for (self.wit_funcs) |wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
    }

    pub fn getExportInfo(self: *const WasmModule, name: []const u8) ?ExportInfo {
        if (comptime !enable_wasm) return null;
        for (self.export_fns) |ei| {
            if (std.mem.eql(u8, ei.name, name)) return ei;
        }
        return null;
    }

    pub fn getExportFn(self: *const WasmModule, name: []const u8) ?*const WasmFn {
        if (comptime !enable_wasm) return null;
        for (self.cached_fns) |*wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
    }
};

// ============================================================
// WasmFn — Value↔u64 marshalling (CW-specific)
// ============================================================

pub const WasmFn = struct {
    module: *WasmModule,
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,
    wit_params: ?[]const wit_parser.WitParam = null,
    wit_result: ?wit_parser.WitType = null,

    pub fn call(self: *const WasmFn, allocator: Allocator, args: []const Value) !Value {
        if (comptime !enable_wasm) return error.TypeError;
        if (self.wit_params) |wps| {
            return self.callWithWitMarshalling(allocator, args, wps);
        }

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
                const ptr: u32 = @truncate(wasm_results[0]);
                const len: u32 = @truncate(wasm_results[1]);
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

const Value = @import("../runtime/value.zig").Value;

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

/// Convert a Wasm u64 result to a Clojure Value based on the result type.
fn wasmToValue(_: Allocator, raw: u64, wasm_type: WasmValType) Value {
    return switch (wasm_type) {
        .i32 => Value.initInteger(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw)))))),
        .i64 => Value.initInteger(@bitCast(raw)),
        .f32 => Value.initFloat(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw)))))),
        .f64 => Value.initFloat(@bitCast(raw)),
    };
}

// ============================================================
// Host function infrastructure (Clojure → Wasm callbacks)
// ============================================================

const bootstrap = @import("../runtime/bootstrap.zig");

const HostContext = struct {
    clj_fn: Value,
    param_count: u32,
    result_count: u32,
    allocator: Allocator,
};

const MAX_CONTEXTS = 256;
var host_contexts: [MAX_CONTEXTS]?HostContext = [_]?HostContext{null} ** MAX_CONTEXTS;
var next_context_id: usize = 0;
var context_mutex: std.Thread.Mutex = .{};

fn allocContext(ctx: HostContext) !usize {
    context_mutex.lock();
    defer context_mutex.unlock();
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

/// Trampoline: called by zwasm VM, invokes the Clojure function.
fn hostTrampoline(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    if (comptime !enable_wasm) unreachable;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    context_mutex.lock();
    const ctx = host_contexts[context_id] orelse {
        context_mutex.unlock();
        return error.Trap;
    };
    context_mutex.unlock();

    var args_buf: [16]Value = undefined;
    const pc = ctx.param_count;
    if (pc > 16) return error.Trap;

    var i: u32 = pc;
    while (i > 0) {
        i -= 1;
        const raw = vm.popOperand();
        args_buf[i] = Value.initInteger(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))));
    }

    const result = bootstrap.callFnVal(ctx.allocator, ctx.clj_fn, args_buf[0..pc]) catch {
        return error.Trap;
    };

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

// ============================================================
// Import bridge — converts Clojure Value map → zwasm ImportEntry[]
// ============================================================

/// Build zwasm ImportEntry[] from Clojure imports map.
/// imports_map: {"module_name" WasmModule-or-{fn-map}}
/// Iterates import_infos (from inspectImportFunctions) to discover module names,
/// then looks up each in the Clojure map via get().
fn buildImportEntries(
    allocator: Allocator,
    imports_map: Value,
    import_infos: []const zwasm.ImportFuncInfo,
) ![]const zwasm.ImportEntry {
    var entries = std.ArrayList(zwasm.ImportEntry).empty;
    defer entries.deinit(allocator);

    // Collect unique module names from import_infos
    var seen_modules = std.ArrayList([]const u8).empty;
    defer seen_modules.deinit(allocator);

    for (import_infos) |info| {
        if (std.mem.eql(u8, info.module, "wasi_snapshot_preview1")) continue;
        var already = false;
        for (seen_modules.items) |seen| {
            if (std.mem.eql(u8, seen, info.module)) {
                already = true;
                break;
            }
        }
        if (!already) try seen_modules.append(allocator, info.module);
    }

    for (seen_modules.items) |mod_name| {
        const mod_val = lookupMapValue(imports_map, mod_name) orelse continue;

        if (mod_val.tag() == .wasm_module) {
            try entries.append(allocator, .{
                .module = mod_name,
                .source = .{ .wasm_module = mod_val.asWasmModule().inner },
            });
        } else {
            // Map of {func_name: clj-fn} — host function imports
            const host_fns = try buildHostFns(allocator, mod_name, mod_val, import_infos);
            try entries.append(allocator, .{
                .module = mod_name,
                .source = .{ .host_fns = host_fns },
            });
        }
    }

    return entries.toOwnedSlice(allocator);
}

/// Build host function entries from a Clojure map of {func_name: clj-fn}.
fn buildHostFns(
    allocator: Allocator,
    mod_name: []const u8,
    fn_map: Value,
    import_infos: []const zwasm.ImportFuncInfo,
) ![]const zwasm.HostFnEntry {
    var host_fns = std.ArrayList(zwasm.HostFnEntry).empty;
    defer host_fns.deinit(allocator);

    // Iterate import_infos to find functions for this module, then look up in fn_map
    for (import_infos) |info| {
        if (!std.mem.eql(u8, info.module, mod_name)) continue;

        const clj_fn = lookupMapValue(fn_map, info.name) orelse continue;

        const ctx_id = allocContext(.{
            .clj_fn = clj_fn,
            .param_count = info.param_count,
            .result_count = info.result_count,
            .allocator = allocator,
        }) catch return error.WasmHostContextFull;

        try host_fns.append(allocator, .{
            .name = info.name,
            .callback = &hostTrampoline,
            .context = ctx_id,
        });
    }

    return host_fns.toOwnedSlice(allocator);
}

/// Lookup a string-keyed value in a Clojure map (PersistentArrayMap or PersistentHashMap).
fn lookupMapValue(map: Value, key_str: []const u8) ?Value {
    const alloc = std.heap.page_allocator;
    const key = Value.initString(alloc, key_str);
    return switch (map.tag()) {
        .map => map.asMap().get(key),
        .hash_map => map.asHashMap().get(key),
        else => null,
    };
}

// ============================================================
// Internal helpers
// ============================================================

/// Build CW ExportInfo from zwasm's export info.
fn buildExportInfo(allocator: Allocator, inner: *zwasm.WasmModule) ![]const ExportInfo {
    // Read exports from the zwasm module via getExportInfo iteration
    // zwasm doesn't expose a list API, but export_fns are public
    const src = inner.export_fns;
    if (src.len == 0) return &[_]ExportInfo{};

    const infos = try allocator.alloc(ExportInfo, src.len);
    var idx: usize = 0;
    for (src) |ei| {
        const params = try allocator.alloc(WasmValType, ei.param_types.len);
        var valid = true;
        for (ei.param_types, 0..) |p, i| {
            params[i] = WasmValType.fromZwasm(p) orelse {
                valid = false;
                break;
            };
        }
        if (!valid) {
            allocator.free(params);
            continue;
        }

        const results = try allocator.alloc(WasmValType, ei.result_types.len);
        for (ei.result_types, 0..) |r, i| {
            results[i] = WasmValType.fromZwasm(r) orelse {
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
            .name = ei.name,
            .param_types = params,
            .result_types = results,
        };
        idx += 1;
    }

    if (idx == 0) {
        allocator.free(infos);
        return &[_]ExportInfo{};
    }
    if (idx < src.len) {
        const trimmed = try allocator.alloc(ExportInfo, idx);
        @memcpy(trimmed, infos[0..idx]);
        allocator.free(infos);
        return trimmed;
    }
    return infos;
}

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

// === Tests ===

const testing = std.testing;

test "smoke test — load and call add(3, 4)" {
    if (!enable_wasm) return;
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);

    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "smoke test — fibonacci(10) = 55" {
    if (!enable_wasm) return;
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{10};
    var results = [_]u64{0};
    try wasm_mod.invoke("fib", &args, &results);

    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "memory read/write round-trip" {
    if (!enable_wasm) return;
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
    if (!enable_wasm) return;
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
    if (!enable_wasm) return;
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

test "buildExportInfo — add module exports" {
    if (!enable_wasm) return;
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
    if (!enable_wasm) return;
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
    if (!enable_wasm) return;
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
    if (!enable_wasm) return;
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    try testing.expect(wasm_mod.getExportInfo("nonexistent") == null);
}

test "multi-module — two modules, function import" {
    if (!enable_wasm) return;
    const collections = @import("../runtime/collections.zig");

    const math_bytes = @embedFile("testdata/20_math_export.wasm");
    var math_mod = try WasmModule.load(testing.allocator, math_bytes);
    defer math_mod.deinit();

    var add_args = [_]u64{ 3, 4 };
    var add_results = [_]u64{0};
    try math_mod.invoke("add", &add_args, &add_results);
    try testing.expectEqual(@as(u64, 7), add_results[0]);

    const math_val = Value.initWasmModule(math_mod);
    var import_entries = [_]Value{
        Value.initString(std.heap.page_allocator, "math"), math_val,
    };
    const import_map = try testing.allocator.create(collections.PersistentArrayMap);
    import_map.* = .{ .entries = &import_entries };
    defer testing.allocator.destroy(import_map);

    const app_bytes = @embedFile("testdata/21_app_import.wasm");
    var app_mod = try WasmModule.loadWithImports(testing.allocator, app_bytes, Value.initMap(import_map));
    defer app_mod.deinit();

    var args = [_]u64{ 3, 4, 5 };
    var results = [_]u64{0};
    try app_mod.invoke("add_and_mul", &args, &results);
    try testing.expectEqual(@as(u64, 35), results[0]);
}

test "multi-module — three module chain" {
    if (!enable_wasm) return;
    const collections = @import("../runtime/collections.zig");

    const base_bytes = @embedFile("testdata/22_base.wasm");
    var base_mod = try WasmModule.load(testing.allocator, base_bytes);
    defer base_mod.deinit();

    const base_val = Value.initWasmModule(base_mod);
    var base_entries = [_]Value{
        Value.initString(std.heap.page_allocator, "base"), base_val,
    };
    const base_map = try testing.allocator.create(collections.PersistentArrayMap);
    base_map.* = .{ .entries = &base_entries };
    defer testing.allocator.destroy(base_map);

    const mid_bytes = @embedFile("testdata/23_mid.wasm");
    var mid_mod = try WasmModule.loadWithImports(testing.allocator, mid_bytes, Value.initMap(base_map));
    defer mid_mod.deinit();

    var mid_args = [_]u64{5};
    var mid_results = [_]u64{0};
    try mid_mod.invoke("quadruple", &mid_args, &mid_results);
    try testing.expectEqual(@as(u64, 20), mid_results[0]);

    const mid_val = Value.initWasmModule(mid_mod);
    var mid_entries = [_]Value{
        Value.initString(std.heap.page_allocator, "mid"), mid_val,
    };
    const mid_map = try testing.allocator.create(collections.PersistentArrayMap);
    mid_map.* = .{ .entries = &mid_entries };
    defer testing.allocator.destroy(mid_map);

    const top_bytes = @embedFile("testdata/24_top.wasm");
    var top_mod = try WasmModule.loadWithImports(testing.allocator, top_bytes, Value.initMap(mid_map));
    defer top_mod.deinit();

    var top_args = [_]u64{3};
    var top_results = [_]u64{0};
    try top_mod.invoke("octuple", &top_args, &top_results);
    try testing.expectEqual(@as(u64, 24), top_results[0]);
}
