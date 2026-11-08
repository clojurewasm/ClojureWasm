// SPDX-License-Identifier: EPL-2.0
//! `(wasm/exports h)` — list a core module's exports in export-section order
//! (ADR-0203 decision 1). A function answers
//! `{:name "add" :kind :func :params [:i32 :i32] :results [:i32]}`; a memory,
//! global or table answers `{:name "memory" :kind :memory}`. The function
//! signature comes from `Loaded.exportSig`, the same runtime probe `wasm/call`
//! marshals through, so nothing here is declared by hand and a listed function
//! is callable at exactly the listed arity. Compiled ONLY under `-Dwasm`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/exports
const std = @import("std");
const zwasm = @import("zwasm");
const engine = @import("engine.zig");
const wasm_handle = @import("wasm_handle.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const keyword_mod = @import("../../keyword.zig");

/// `(wasm/exports handle)` — a vector of export maps, in export order.
pub fn wasmExportsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/exports", args, 1, loc);
    if (!wasm_handle.isHandle(args[0]))
        return error_catalog.raise(.wasm_handle_invalid, loc, .{ .fn_name = "wasm/exports" });
    const loaded = wasm_handle.unwrap(args[0]);

    const name_kw = try keyword_mod.intern(rt, null, "name");
    const kind_kw = try keyword_mod.intern(rt, null, "kind");
    const params_kw = try keyword_mod.intern(rt, null, "params");
    const results_kw = try keyword_mod.intern(rt, null, "results");

    // The partial `out` vector and each `m` live only in Zig locals until
    // return, so no collection may run while they are built.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();

    var out = vector_mod.empty();
    for (loaded.export_list.items) |item| {
        var m = map_mod.empty();
        m = try map_mod.assoc(rt, m, name_kw, try string_mod.alloc(rt, item.name));
        m = try map_mod.assoc(rt, m, kind_kw, try keyword_mod.intern(rt, null, kindName(item.kind)));
        if (item.kind == .func) {
            // A func export always has a signature; a miss would mean the
            // instance and the export section disagree, so the map simply
            // carries no signature rather than inventing one.
            if (loaded.exportSig(item.name)) |sig| {
                m = try map_mod.assoc(rt, m, params_kw, try typeVector(rt, sig.params));
                m = try map_mod.assoc(rt, m, results_kw, try typeVector(rt, sig.results));
            }
        }
        out = try vector_mod.conj(rt, out, m);
    }
    return out;
}

fn typeVector(rt: *Runtime, types: []const engine.ValType) anyerror!Value {
    var v = vector_mod.empty();
    for (types) |t| v = try vector_mod.conj(rt, v, try keyword_mod.intern(rt, null, valTypeName(t)));
    return v;
}

/// The `:kind` keyword name of an export.
pub fn kindName(kind: zwasm.ExternKind) []const u8 {
    return switch (kind) {
        .func => "func",
        .table => "table",
        .memory => "memory",
        .global => "global",
        // The binary format has no tag export; zwasm's enum shares the import side.
        .tag => "tag",
    };
}

/// The keyword name of a value type: `i32 i64 f32 f64 v128`, and for a
/// reference its abstract heap type's text-format shorthand (`funcref`,
/// `externref`, ...). A concrete typed reference `(ref $t)` names as `ref`.
pub fn valTypeName(t: engine.ValType) []const u8 {
    return switch (t) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
        .v128 => "v128",
        .ref => |r| switch (r.heap_type) {
            .concrete => "ref",
            .abstract => |a| switch (a) {
                .func => "funcref",
                .extern_ => "externref",
                .any => "anyref",
                .eq => "eqref",
                .i31 => "i31ref",
                .struct_ => "structref",
                .array => "arrayref",
                .none => "nullref",
                .noextern => "nullexternref",
                .nofunc => "nullfuncref",
                .exn => "exnref",
                .noexn => "nullexnref",
            },
        },
    };
}

test "valTypeName names scalars and the abstract references" {
    const VT = engine.ValType;
    try std.testing.expectEqualStrings("i32", valTypeName(.i32));
    try std.testing.expectEqualStrings("f64", valTypeName(.f64));
    try std.testing.expectEqualStrings("v128", valTypeName(.v128));
    try std.testing.expectEqualStrings("funcref", valTypeName(VT.funcref));
    try std.testing.expectEqualStrings("externref", valTypeName(VT.externref));
}

test "kindName names every export kind" {
    try std.testing.expectEqualStrings("func", kindName(.func));
    try std.testing.expectEqualStrings("memory", kindName(.memory));
    try std.testing.expectEqualStrings("global", kindName(.global));
    try std.testing.expectEqualStrings("table", kindName(.table));
}

// (module (func (export "add") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add) (memory (export "memory") 1))
const add_mem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
    0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01,
    0x00, 0x01, 0x07, 0x10, 0x02, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x06,
    0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x0a, 0x09, 0x01, 0x07,
    0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
};

test "the export list outlives the module bytes and pairs with exportSig" {
    const alloc = std.testing.allocator;
    inline for (.{ engine.EngineKind.interp, engine.EngineKind.jit }) |kind| {
        // `wasm/load` frees the file bytes right after `load`; mirror that.
        const bytes = try alloc.dupe(u8, &add_mem_wasm);
        const loaded = try engine.load(alloc, bytes, .{ .engine = kind });
        @memset(bytes, 0);
        alloc.free(bytes);
        defer {
            loaded.deinit();
            alloc.destroy(loaded);
        }
        const items = loaded.export_list.items;
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("add", items[0].name);
        try std.testing.expectEqualStrings("func", kindName(items[0].kind));
        try std.testing.expectEqualStrings("memory", items[1].name);
        try std.testing.expectEqualStrings("memory", kindName(items[1].kind));
        const sig = loaded.exportSig("add").?;
        try std.testing.expectEqual(@as(usize, 2), sig.params.len);
        try std.testing.expectEqualStrings("i32", valTypeName(sig.results[0]));
    }
}
