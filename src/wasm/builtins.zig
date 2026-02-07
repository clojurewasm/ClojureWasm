// Wasm namespace builtins — wasm/load, wasm/fn (Phase 25.1).
//
// (wasm/load "path.wasm")  => WasmModule value
// (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}) => WasmFn value
// The returned WasmFn is callable as a first-class Clojure function.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../common/value.zig").Value;
const var_mod = @import("../common/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../common/error.zig");
const wasm_types = @import("types.zig");
const WasmModule = wasm_types.WasmModule;
const WasmFn = wasm_types.WasmFn;
const WasmValType = wasm_types.WasmValType;

/// (wasm/load path) or (wasm/load path opts) => WasmModule
/// Reads a .wasm file from disk and instantiates it.
/// opts: {:imports {"module" {"func" clj-fn}}} — register Clojure fns as host imports.
pub fn wasmLoadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/load", .{args.len});

    const path = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load expects a string path, got {s}", .{@tagName(args[0])}),
    };

    // Read .wasm binary from disk
    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: file not found: {s}", .{path});
    defer file.close();

    const wasm_bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch
        return error.IOError;

    // Parse optional :imports from opts map
    if (args.len == 2) {
        const imports_key = Value{ .keyword = .{ .name = "imports", .ns = null } };
        const imports_val = switch (args[1]) {
            .map => |m| m.get(imports_key),
            .hash_map => |hm| hm.get(imports_key),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load opts must be a map, got {s}", .{@tagName(args[1])}),
        };
        if (imports_val) |iv| {
            const wasm_mod = WasmModule.loadWithImports(allocator, wasm_bytes, iv) catch
                return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to instantiate module with imports: {s}", .{path});
            return Value{ .wasm_module = wasm_mod };
        }
    }

    // Default: no imports
    const wasm_mod = WasmModule.load(allocator, wasm_bytes) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to instantiate module: {s}", .{path});

    return Value{ .wasm_module = wasm_mod };
}

/// (wasm/load-wasi path) => WasmModule
/// Reads a WASI .wasm file, registers WASI imports, and instantiates it.
/// Required for TinyGo, Rust wasm32-wasi, and other WASI-targeting compilers.
pub fn wasmLoadWasiFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/load-wasi", .{args.len});

    const path = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load-wasi expects a string path, got {s}", .{@tagName(args[0])}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load-wasi: file not found: {s}", .{path});
    defer file.close();

    const wasm_bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch
        return error.IOError;

    const wasm_mod = WasmModule.loadWasi(allocator, wasm_bytes) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load-wasi: failed to instantiate module: {s}", .{path});

    return Value{ .wasm_module = wasm_mod };
}

/// (wasm/fn module name) => WasmFn        ;; auto-resolve from binary
/// (wasm/fn module name sig) => WasmFn     ;; explicit sig with cross-validation
pub fn wasmFnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/fn", .{args.len});

    const wasm_mod = switch (args[0]) {
        .wasm_module => |m| m,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a WasmModule as first arg, got {s}", .{@tagName(args[0])}),
    };

    const name = switch (args[1]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a string function name, got {s}", .{@tagName(args[1])}),
    };

    if (args.len == 2) {
        // Auto-resolve from binary export info
        const ei = wasm_mod.getExportInfo(name) orelse
            return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn: no exported function \"{s}\" found in module", .{name});
        const wfn = try allocator.create(WasmFn);
        wfn.* = .{
            .module = wasm_mod,
            .name = name,
            .param_types = ei.param_types,
            .result_types = ei.result_types,
        };
        return Value{ .wasm_fn = wfn };
    }

    // 3-arg: parse explicit signature
    const params_key = Value{ .keyword = .{ .name = "params", .ns = null } };
    const results_key = Value{ .keyword = .{ .name = "results", .ns = null } };

    const sig_map = args[2];
    const params_val = switch (sig_map) {
        .map => |m| m.get(params_key),
        .hash_map => |hm| hm.get(params_key),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a map as third arg, got {s}", .{@tagName(args[2])}),
    };
    const results_val = switch (sig_map) {
        .map => |m| m.get(results_key),
        .hash_map => |hm| hm.get(results_key),
        else => unreachable,
    };

    const param_types = try parseTypeVec(allocator, params_val, "params");
    const result_types = try parseTypeVec(allocator, results_val, "results");

    // Cross-validate explicit sig against binary if export info exists
    if (wasm_mod.getExportInfo(name)) |ei| {
        if (!typesMatch(param_types, ei.param_types))
            return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn: :params mismatch for \"{s}\" — declared vs binary signature differ", .{name});
        if (!typesMatch(result_types, ei.result_types))
            return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn: :results mismatch for \"{s}\" — declared vs binary signature differ", .{name});
    }

    const wfn = try allocator.create(WasmFn);
    wfn.* = .{
        .module = wasm_mod,
        .name = name,
        .param_types = param_types,
        .result_types = result_types,
    };

    return Value{ .wasm_fn = wfn };
}

/// Compare two WasmValType slices for equality.
fn typesMatch(a: []const WasmValType, b: []const WasmValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Parse a Value (expected to be a vector of keywords like [:i32 :i64])
/// into a slice of WasmValType.
fn parseTypeVec(allocator: Allocator, val: ?Value, field_name: []const u8) ![]const WasmValType {
    const v = val orelse return &[_]WasmValType{};
    const items = switch (v) {
        .vector => |vec| vec.items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn :{s} must be a vector", .{field_name}),
    };

    const types = try allocator.alloc(WasmValType, items.len);
    for (items, 0..) |item, i| {
        const kw_name = switch (item) {
            .keyword => |kw| kw.name,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn :{s} elements must be keywords, got {s}", .{ field_name, @tagName(item) }),
        };
        types[i] = parseWasmType(kw_name) orelse
            return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn: unknown Wasm type :{s}", .{kw_name});
    }
    return types;
}

fn parseWasmType(name: []const u8) ?WasmValType {
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    return null;
}

/// (wasm/memory-read module offset length) => string
/// Read bytes from the module's linear memory.
pub fn wasmMemoryReadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/memory-read", .{args.len});

    const wasm_mod = switch (args[0]) {
        .wasm_module => |m| m,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-read expects a WasmModule, got {s}", .{@tagName(args[0])}),
    };
    const offset: u32 = switch (args[1]) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.IndexError,
        else => return error.TypeError,
    };
    const length: u32 = switch (args[2]) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.IndexError,
        else => return error.TypeError,
    };

    const bytes = wasm_mod.memoryRead(allocator, offset, length) catch
        return err.setErrorFmt(.eval, .index_error, .{}, "wasm/memory-read: out of bounds (offset={d}, length={d})", .{ offset, length });
    return Value{ .string = bytes };
}

/// (wasm/memory-write module offset data) => nil
/// Write bytes from a string to the module's linear memory.
pub fn wasmMemoryWriteFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/memory-write", .{args.len});

    const wasm_mod = switch (args[0]) {
        .wasm_module => |m| m,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-write expects a WasmModule, got {s}", .{@tagName(args[0])}),
    };
    const offset: u32 = switch (args[1]) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.IndexError,
        else => return error.TypeError,
    };
    const data = switch (args[2]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-write expects a string, got {s}", .{@tagName(args[2])}),
    };

    wasm_mod.memoryWrite(offset, data) catch
        return err.setErrorFmt(.eval, .index_error, .{}, "wasm/memory-write: out of bounds (offset={d}, length={d})", .{ offset, data.len });
    return Value.nil;
}

const collections = @import("../common/collections.zig");
const ExportInfo = wasm_types.ExportInfo;

/// (wasm/exports module) => {"name" {:params [...] :results [...]}}
/// Returns a map of exported function names to their type signatures.
pub fn wasmExportsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/exports", .{args.len});

    const wasm_mod = switch (args[0]) {
        .wasm_module => |m| m,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/exports expects a WasmModule, got {s}", .{@tagName(args[0])}),
    };

    const export_fns = wasm_mod.export_fns;
    // Build outer map entries: [name1, sig1, name2, sig2, ...]
    const outer_entries = try allocator.alloc(Value, export_fns.len * 2);
    for (export_fns, 0..) |ei, i| {
        outer_entries[i * 2] = .{ .string = ei.name };
        outer_entries[i * 2 + 1] = try exportInfoToSigMap(allocator, ei);
    }

    const outer_map = try allocator.create(collections.PersistentArrayMap);
    outer_map.* = .{ .entries = outer_entries };
    return Value{ .map = outer_map };
}

/// Convert an ExportInfo into a Clojure map {:params [:i32 ...] :results [:i32 ...]}.
fn exportInfoToSigMap(allocator: Allocator, ei: ExportInfo) !Value {
    // Build :params vector
    const param_items = try allocator.alloc(Value, ei.param_types.len);
    for (ei.param_types, 0..) |pt, i| {
        param_items[i] = .{ .keyword = .{ .name = wasmTypeToKeyword(pt), .ns = null } };
    }
    const param_vec = try allocator.create(collections.PersistentVector);
    param_vec.* = .{ .items = param_items };

    // Build :results vector
    const result_items = try allocator.alloc(Value, ei.result_types.len);
    for (ei.result_types, 0..) |rt, i| {
        result_items[i] = .{ .keyword = .{ .name = wasmTypeToKeyword(rt), .ns = null } };
    }
    const result_vec = try allocator.create(collections.PersistentVector);
    result_vec.* = .{ .items = result_items };

    // Build {:params [...] :results [...]}
    const sig_entries = try allocator.alloc(Value, 4);
    sig_entries[0] = .{ .keyword = .{ .name = "params", .ns = null } };
    sig_entries[1] = .{ .vector = param_vec };
    sig_entries[2] = .{ .keyword = .{ .name = "results", .ns = null } };
    sig_entries[3] = .{ .vector = result_vec };

    const sig_map = try allocator.create(collections.PersistentArrayMap);
    sig_map.* = .{ .entries = sig_entries };
    return Value{ .map = sig_map };
}

fn wasmTypeToKeyword(wt: WasmValType) []const u8 {
    return switch (wt) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
    };
}

pub const builtins: []const BuiltinDef = &[_]BuiltinDef{
    .{
        .name = "load",
        .func = wasmLoadFn,
        .doc = "Loads a WebAssembly module from file path. Optional opts map: {:imports {\"module\" {\"func\" clj-fn}}} for host function injection.",
        .arglists = "([path] [path opts])",
    },
    .{
        .name = "load-wasi",
        .func = wasmLoadWasiFn,
        .doc = "Loads a WASI WebAssembly module with wasi_snapshot_preview1 imports. Required for TinyGo and Rust wasm32-wasi modules.",
        .arglists = "([path])",
    },
    .{
        .name = "fn",
        .func = wasmFnFn,
        .doc = "Creates a callable Wasm function. 2-arg auto-resolves signature from binary. 3-arg cross-validates explicit sig against binary.",
        .arglists = "([module name] [module name sig])",
    },
    .{
        .name = "exports",
        .func = wasmExportsFn,
        .doc = "Returns a map of exported function names to their type signatures {:params [...] :results [...]}.",
        .arglists = "([module])",
    },
    .{
        .name = "memory-read",
        .func = wasmMemoryReadFn,
        .doc = "Reads bytes from a WasmModule's linear memory. Returns a string of the raw bytes.",
        .arglists = "([module offset length])",
    },
    .{
        .name = "memory-write",
        .func = wasmMemoryWriteFn,
        .doc = "Writes bytes from a string to a WasmModule's linear memory.",
        .arglists = "([module offset data])",
    },
};

// === Tests ===

const testing = std.testing;

test "parseWasmType" {
    try testing.expectEqual(WasmValType.i32, parseWasmType("i32").?);
    try testing.expectEqual(WasmValType.f64, parseWasmType("f64").?);
    try testing.expect(parseWasmType("unknown") == null);
}
