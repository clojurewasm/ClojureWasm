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

/// (wasm/load path) => WasmModule
/// Reads a .wasm file from disk and instantiates it.
pub fn wasmLoadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
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

    // Load and instantiate
    const wasm_mod = WasmModule.load(allocator, wasm_bytes) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to instantiate module: {s}", .{path});

    return Value{ .wasm_module = wasm_mod };
}

/// (wasm/fn module name sig) => WasmFn
/// sig is a map: {:params [:i32 :i32] :results [:i32]}
pub fn wasmFnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/fn", .{args.len});

    const wasm_mod = switch (args[0]) {
        .wasm_module => |m| m,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a WasmModule as first arg, got {s}", .{@tagName(args[0])}),
    };

    const name = switch (args[1]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a string function name, got {s}", .{@tagName(args[1])}),
    };

    // Parse signature map {:params [...] :results [...]}
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

    // Parse :params vector of keyword type names
    const param_types = try parseTypeVec(allocator, params_val, "params");
    const result_types = try parseTypeVec(allocator, results_val, "results");

    // Create WasmFn on the heap
    const wfn = try allocator.create(WasmFn);
    wfn.* = .{
        .module = wasm_mod,
        .name = name,
        .param_types = param_types,
        .result_types = result_types,
    };

    return Value{ .wasm_fn = wfn };
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

pub const builtins: []const BuiltinDef = &[_]BuiltinDef{
    .{
        .name = "load",
        .func = wasmLoadFn,
        .doc = "Loads a WebAssembly module from file path. Returns a WasmModule value.",
        .arglists = "([path])",
    },
    .{
        .name = "fn",
        .func = wasmFnFn,
        .doc = "Creates a callable Wasm function from a module, export name, and type signature map {:params [...] :results [...]}.",
        .arglists = "([module name sig])",
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
