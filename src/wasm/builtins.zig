// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

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
const wit_parser = @import("wit_parser.zig");

/// (wasm/load path) or (wasm/load path opts) => WasmModule
/// Reads a .wasm file from disk and instantiates it.
/// opts: {:imports {"module" {"func" clj-fn}}, :wit "path.wit"} — host imports and WIT info.
pub fn wasmLoadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/load", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    // Read .wasm binary from disk
    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: file not found: {s}", .{path});
    defer file.close();

    const wasm_bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch
        return error.IOError;

    // Parse opts map if present
    var imports_val_opt: ?Value = null;
    var wit_path_opt: ?[]const u8 = null;
    if (args.len == 2) {
        const opts = args[1];
        const imports_key = Value.initKeyword(allocator, .{ .name = "imports", .ns = null });
        const wit_key = Value.initKeyword(allocator, .{ .name = "wit", .ns = null });
        imports_val_opt = switch (opts.tag()) {
            .map => opts.asMap().get(imports_key),
            .hash_map => opts.asHashMap().get(imports_key),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load opts must be a map, got {s}", .{@tagName(args[1].tag())}),
        };
        const wit_val = switch (opts.tag()) {
            .map => opts.asMap().get(wit_key),
            .hash_map => opts.asHashMap().get(wit_key),
            else => unreachable,
        };
        if (wit_val) |wv| {
            wit_path_opt = switch (wv.tag()) {
                .string => wv.asString(),
                else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load :wit must be a string path, got {s}", .{@tagName(wv.tag())}),
            };
        }
    }

    // Instantiate module
    const wasm_mod = if (imports_val_opt) |iv|
        WasmModule.loadWithImports(allocator, wasm_bytes, iv) catch
            return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to instantiate module with imports: {s}", .{path})
    else
        WasmModule.load(allocator, wasm_bytes) catch
            return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to instantiate module: {s}", .{path});

    // Parse and attach WIT info if :wit provided
    if (wit_path_opt) |wit_path| {
        const wit_file = cwd.openFile(wit_path, .{}) catch
            return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: WIT file not found: {s}", .{wit_path});
        defer wit_file.close();

        const wit_src = wit_file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch
            return error.IOError;

        const ifaces = wit_parser.parse(allocator, wit_src) catch
            return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load: failed to parse WIT file: {s}", .{wit_path});

        // Collect all funcs from all interfaces
        var total_funcs: usize = 0;
        for (ifaces) |iface| total_funcs += iface.funcs.len;

        if (total_funcs > 0) {
            const all_funcs = allocator.alloc(wit_parser.WitFunc, total_funcs) catch
                return error.OutOfMemory;
            var idx: usize = 0;
            for (ifaces) |iface| {
                for (iface.funcs) |f| {
                    all_funcs[idx] = f;
                    idx += 1;
                }
            }
            wasm_mod.setWitInfo(all_funcs);
        }
    }

    return Value.initWasmModule(wasm_mod);
}

/// (wasm/load-wasi path) => WasmModule
/// Reads a WASI .wasm file, registers WASI imports, and instantiates it.
/// Required for TinyGo, Rust wasm32-wasi, and other WASI-targeting compilers.
pub fn wasmLoadWasiFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/load-wasi", .{args.len});

    const path = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/load-wasi expects a string path, got {s}", .{@tagName(args[0].tag())}),
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load-wasi: file not found: {s}", .{path});
    defer file.close();

    const wasm_bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch
        return error.IOError;

    const wasm_mod = WasmModule.loadWasi(allocator, wasm_bytes) catch
        return err.setErrorFmt(.eval, .io_error, .{}, "wasm/load-wasi: failed to instantiate module: {s}", .{path});

    return Value.initWasmModule(wasm_mod);
}

/// (wasm/fn module name) => WasmFn        ;; auto-resolve from binary
/// (wasm/fn module name sig) => WasmFn     ;; explicit sig with cross-validation
pub fn wasmFnFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/fn", .{args.len});

    const wasm_mod = switch (args[0].tag()) {
        .wasm_module => args[0].asWasmModule(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a WasmModule as first arg, got {s}", .{@tagName(args[0].tag())}),
    };

    const name = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a string function name, got {s}", .{@tagName(args[1].tag())}),
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
        // Attach WIT info if available
        if (wasm_mod.getWitFunc(name)) |wf| {
            wfn.wit_params = wf.params;
            wfn.wit_result = wf.result;
        }
        return Value.initWasmFn(wfn);
    }

    // 3-arg: parse explicit signature
    const params_key = Value.initKeyword(allocator, .{ .name = "params", .ns = null });
    const results_key = Value.initKeyword(allocator, .{ .name = "results", .ns = null });

    const sig_map = args[2];
    const params_val = switch (sig_map.tag()) {
        .map => sig_map.asMap().get(params_key),
        .hash_map => sig_map.asHashMap().get(params_key),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn expects a map as third arg, got {s}", .{@tagName(args[2].tag())}),
    };
    const results_val = switch (sig_map.tag()) {
        .map => sig_map.asMap().get(results_key),
        .hash_map => sig_map.asHashMap().get(results_key),
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

    return Value.initWasmFn(wfn);
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
    const items = switch (v.tag()) {
        .vector => v.asVector().items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn :{s} must be a vector", .{field_name}),
    };

    const types = try allocator.alloc(WasmValType, items.len);
    for (items, 0..) |item, i| {
        const kw_name = switch (item.tag()) {
            .keyword => item.asKeyword().name,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/fn :{s} elements must be keywords, got {s}", .{ field_name, @tagName(item.tag()) }),
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

    const wasm_mod = switch (args[0].tag()) {
        .wasm_module => args[0].asWasmModule(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-read expects a WasmModule, got {s}", .{@tagName(args[0].tag())}),
    };
    const offset: u32 = switch (args[1].tag()) {
        .integer => blk: {
            const n = args[1].asInteger();
            break :blk if (n >= 0) @intCast(n) else return error.IndexError;
        },
        else => return error.TypeError,
    };
    const length: u32 = switch (args[2].tag()) {
        .integer => blk: {
            const n = args[2].asInteger();
            break :blk if (n >= 0) @intCast(n) else return error.IndexError;
        },
        else => return error.TypeError,
    };

    const bytes = wasm_mod.memoryRead(allocator, offset, length) catch
        return err.setErrorFmt(.eval, .index_error, .{}, "wasm/memory-read: out of bounds (offset={d}, length={d})", .{ offset, length });
    return Value.initString(allocator, bytes);
}

/// (wasm/memory-write module offset data) => nil
/// Write bytes from a string to the module's linear memory.
pub fn wasmMemoryWriteFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/memory-write", .{args.len});

    const wasm_mod = switch (args[0].tag()) {
        .wasm_module => args[0].asWasmModule(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-write expects a WasmModule, got {s}", .{@tagName(args[0].tag())}),
    };
    const offset: u32 = switch (args[1].tag()) {
        .integer => blk: {
            const n = args[1].asInteger();
            break :blk if (n >= 0) @intCast(n) else return error.IndexError;
        },
        else => return error.TypeError,
    };
    const data = switch (args[2].tag()) {
        .string => args[2].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/memory-write expects a string, got {s}", .{@tagName(args[2].tag())}),
    };

    wasm_mod.memoryWrite(offset, data) catch
        return err.setErrorFmt(.eval, .index_error, .{}, "wasm/memory-write: out of bounds (offset={d}, length={d})", .{ offset, data.len });
    return Value.nil_val;
}

const collections = @import("../common/collections.zig");
const ExportInfo = wasm_types.ExportInfo;

/// (wasm/exports module) => {"name" {:params [...] :results [...]}}
/// Returns a map of exported function names to their type signatures.
pub fn wasmExportsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/exports", .{args.len});

    const wasm_mod = switch (args[0].tag()) {
        .wasm_module => args[0].asWasmModule(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/exports expects a WasmModule, got {s}", .{@tagName(args[0].tag())}),
    };

    const export_fns = wasm_mod.export_fns;
    // Build outer map entries: [name1, sig1, name2, sig2, ...]
    const outer_entries = try allocator.alloc(Value, export_fns.len * 2);
    for (export_fns, 0..) |ei, i| {
        outer_entries[i * 2] = Value.initString(allocator, ei.name);
        outer_entries[i * 2 + 1] = try exportInfoToSigMap(allocator, ei);
    }

    const outer_map = try allocator.create(collections.PersistentArrayMap);
    outer_map.* = .{ .entries = outer_entries };
    return Value.initMap(outer_map);
}

/// Convert an ExportInfo into a Clojure map {:params [:i32 ...] :results [:i32 ...]}.
fn exportInfoToSigMap(allocator: Allocator, ei: ExportInfo) !Value {
    // Build :params vector
    const param_items = try allocator.alloc(Value, ei.param_types.len);
    for (ei.param_types, 0..) |pt, i| {
        param_items[i] = Value.initKeyword(allocator, .{ .name = wasmTypeToKeyword(pt), .ns = null });
    }
    const param_vec = try allocator.create(collections.PersistentVector);
    param_vec.* = .{ .items = param_items };

    // Build :results vector
    const result_items = try allocator.alloc(Value, ei.result_types.len);
    for (ei.result_types, 0..) |rt, i| {
        result_items[i] = Value.initKeyword(allocator, .{ .name = wasmTypeToKeyword(rt), .ns = null });
    }
    const result_vec = try allocator.create(collections.PersistentVector);
    result_vec.* = .{ .items = result_items };

    // Build {:params [...] :results [...]}
    const sig_entries = try allocator.alloc(Value, 4);
    sig_entries[0] = Value.initKeyword(allocator, .{ .name = "params", .ns = null });
    sig_entries[1] = Value.initVector(param_vec);
    sig_entries[2] = Value.initKeyword(allocator, .{ .name = "results", .ns = null });
    sig_entries[3] = Value.initVector(result_vec);

    const sig_map = try allocator.create(collections.PersistentArrayMap);
    sig_map.* = .{ .entries = sig_entries };
    return Value.initMap(sig_map);
}

fn wasmTypeToKeyword(wt: WasmValType) []const u8 {
    return switch (wt) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
    };
}

/// (wasm/describe module) => {"name" {:params [{:name "x" :type :string}] :results :i32}}
/// Returns WIT-level type info. Requires :wit option on wasm/load.
pub fn wasmDescribeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1)
        return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to wasm/describe", .{args.len});

    const wasm_mod = switch (args[0].tag()) {
        .wasm_module => args[0].asWasmModule(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "wasm/describe expects a WasmModule, got {s}", .{@tagName(args[0].tag())}),
    };

    const wit_funcs = wasm_mod.wit_funcs;
    if (wit_funcs.len == 0) {
        // No WIT info — return empty map
        const empty_entries = try allocator.alloc(Value, 0);
        const empty_map = try allocator.create(collections.PersistentArrayMap);
        empty_map.* = .{ .entries = empty_entries };
        return Value.initMap(empty_map);
    }

    const outer_entries = try allocator.alloc(Value, wit_funcs.len * 2);
    for (wit_funcs, 0..) |wf, i| {
        outer_entries[i * 2] = Value.initString(allocator, wf.name);
        outer_entries[i * 2 + 1] = try witFuncToDescMap(allocator, wf);
    }

    const outer_map = try allocator.create(collections.PersistentArrayMap);
    outer_map.* = .{ .entries = outer_entries };
    return Value.initMap(outer_map);
}

/// Convert a WitFunc to a Clojure describe map.
fn witFuncToDescMap(allocator: Allocator, wf: wit_parser.WitFunc) !Value {
    // Build :params vector of {:name "x" :type :string} maps
    const param_items = try allocator.alloc(Value, wf.params.len);
    for (wf.params, 0..) |p, i| {
        const pmap_entries = try allocator.alloc(Value, 4);
        pmap_entries[0] = Value.initKeyword(allocator, .{ .name = "name", .ns = null });
        pmap_entries[1] = Value.initString(allocator, p.name);
        pmap_entries[2] = Value.initKeyword(allocator, .{ .name = "type", .ns = null });
        pmap_entries[3] = Value.initKeyword(allocator, .{ .name = witTypeToKeyword(p.type_), .ns = null });
        const pmap = try allocator.create(collections.PersistentArrayMap);
        pmap.* = .{ .entries = pmap_entries };
        param_items[i] = Value.initMap(pmap);
    }
    const param_vec = try allocator.create(collections.PersistentVector);
    param_vec.* = .{ .items = param_items };

    // Build result keyword (or nil for void functions)
    const result_val: Value = if (wf.result) |r|
        Value.initKeyword(allocator, .{ .name = witTypeToKeyword(r), .ns = null })
    else
        Value.nil_val;

    // Build {:params [...] :results :type}
    const desc_entries = try allocator.alloc(Value, 4);
    desc_entries[0] = Value.initKeyword(allocator, .{ .name = "params", .ns = null });
    desc_entries[1] = Value.initVector(param_vec);
    desc_entries[2] = Value.initKeyword(allocator, .{ .name = "results", .ns = null });
    desc_entries[3] = result_val;

    const desc_map = try allocator.create(collections.PersistentArrayMap);
    desc_map.* = .{ .entries = desc_entries };
    return Value.initMap(desc_map);
}

fn witTypeToKeyword(wt: wit_parser.WitType) []const u8 {
    return switch (wt) {
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .s8 => "s8",
        .s16 => "s16",
        .s32 => "s32",
        .s64 => "s64",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .char => "char",
        .string => "string",
        .other => "other",
    };
}

pub const builtins: []const BuiltinDef = &[_]BuiltinDef{
    .{
        .name = "load",
        .func = wasmLoadFn,
        .doc = "Loads a WebAssembly module from file path. Opts: {:imports {\"mod\" {\"fn\" clj-fn}}, :wit \"path.wit\"}.",
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
    .{
        .name = "describe",
        .func = wasmDescribeFn,
        .doc = "Returns WIT-level type info for a module's exports. Requires :wit option on wasm/load.",
        .arglists = "([module])",
    },
};

// === Tests ===

const testing = std.testing;

test "parseWasmType" {
    try testing.expectEqual(WasmValType.i32, parseWasmType("i32").?);
    try testing.expectEqual(WasmValType.f64, parseWasmType("f64").?);
    try testing.expect(parseWasmType("unknown") == null);
}
