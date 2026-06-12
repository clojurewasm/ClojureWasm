// SPDX-License-Identifier: EPL-2.0
//! `clojure.data.json` Tier-A surface (§9.11 row 9.3).
//!
//! Pattern B1 Layer-2 primitives `clojure.data.json/read-str` +
//! `clojure.data.json/write-str` over Zig stdlib's
//! `std.json.parseFromSlice` + a hand-rolled writer that walks
//! cw Values.
//!
//! ## Type mapping
//!
//! | JSON          | cw Value       |
//! |---------------|----------------|
//! | null          | nil            |
//! | true / false  | true / false   |
//! | integer       | integer (i48)  |
//! | float         | float          |
//! | string        | string         |
//! | array         | vector         |
//! | object        | array_map      |
//!
//! Object keys are coerced to cw strings (NOT keywords) by default,
//! matching JVM `clojure.data.json/read-str`'s default. The `:key-fn` /
//! `:value-fn` options land in the json.clj wrapper over these raw impls
//! (D-401); `:bigdec` / `:eof-error?` (parse-level) remain a follow-up here.
//!
//! **Location note (D-095)**: this Zig primitive lives under
//! `src/lang/primitive/` per D-095 (Zig 0.16 module-path constraint).
//! The matching `.clj` source is at `src/lang/clj/clojure/data/json.clj`.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const sorted_collection = @import("../../runtime/collection/sorted.zig");
const print = @import("../../runtime/print.zig");
const big_int_mod = @import("../../runtime/numeric/big_int.zig");

pub fn readStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("read-str", args, 1, loc);
    const arg = args[0];
    if (arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-str",
            .actual = @tagName(arg.tag()),
        });
    }
    const source = string_collection.asString(arg);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), source, .{}) catch {
        return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "JSON parse error in clojure.data.json/read-str",
        });
    };
    return jsonToCw(rt, parsed.value, loc);
}

fn jsonToCw(rt: *Runtime, jv: std.json.Value, loc: SourceLocation) anyerror!Value {
    return switch (jv) {
        .null => Value.nil_val,
        .bool => |b| if (b) Value.true_val else Value.false_val,
        .integer => |i| blk: {
            // D-182: a JSON integer beyond i48 (but within i64) is a Long
            // (JVM data.json parses integers as Long) — heap-boxed `.long`
            // (D-165): value-exact, prints WITHOUT `N`, class Long. Integers
            // beyond i64 arrive as `.number_string` (still deferred).
            if (i < std.math.minInt(i48) or i > std.math.maxInt(i48)) {
                break :blk try big_int_mod.allocFromI64(rt, i, .long);
            }
            break :blk Value.initInteger(i);
        },
        .float => |f| Value.initFloat(f),
        .number_string => |s| blk: {
            // std.json hands back a number_string when the value does not fit
            // i64. JVM data.json (default opts): a decimal → Double, an integer
            // beyond Long → BigInteger. So a `.`/`e`/`E` mantissa parses to f64,
            // otherwise the digit string lifts to a BigInt via the D-047-safe
            // base-10 parser (correct past 2^64 on every platform).
            if (std.mem.findAny(u8, s, ".eE") != null) {
                break :blk Value.initFloat(std.fmt.parseFloat(f64, s) catch
                    return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "read-str", .text = s }));
            }
            var m = big_int_mod.parseBase10(rt, s) catch
                return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "read-str", .text = s });
            defer m.deinit();
            // A number_string integer is one too large for the i64 `.integer`
            // arm above → genuinely > i64 → a BigInt (clj data.json, D-165).
            break :blk try big_int_mod.allocFromManaged(rt, &m, .bigint);
        },
        .string => |s| try string_collection.alloc(rt, s),
        .array => |arr| blk: {
            var out = vector_collection.empty();
            for (arr.items) |item| {
                const v = try jsonToCw(rt, item, loc);
                out = try vector_collection.conj(rt, out, v);
            }
            break :blk out;
        },
        .object => |obj| blk: {
            var out = map_collection.empty();
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try string_collection.alloc(rt, entry.key_ptr.*);
                const v = try jsonToCw(rt, entry.value_ptr.*, loc);
                out = map_collection.assoc(rt, out, k, v) catch |err| switch (err) {
                    error.AssocOnNonMap => unreachable,
                    else => |e| return e,
                };
            }
            break :blk out;
        },
    };
}

pub fn writeStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("write-str", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    errdefer aw.deinit();
    cwToJson(args[0], &aw.writer, loc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "JSON write error in clojure.data.json/write-str",
        }),
    };
    const owned = try aw.toOwnedSlice();
    defer rt.gpa.free(owned);
    return try string_collection.alloc(rt, owned);
}

const JsonWriteError = error{
    OutOfMemory,
    UnsupportedJsonTag,
    WriteFailed,
};

/// Per-map-entry emitter for `forEachEntry` (array_map + hash_map). Holds the
/// writer + a running first-flag for comma separation.
const MapEmitCtx = struct { w: *std.Io.Writer, first: bool };

fn emitJsonEntry(ctx: *MapEmitCtx, k: Value, val: Value) anyerror!void {
    if (!ctx.first) try ctx.w.writeAll(",");
    ctx.first = false;
    // Coerce non-string keys to their string form (JSON keys must be strings).
    switch (k.tag()) {
        .string => try writeJsonString(ctx.w, string_collection.asString(k)),
        .keyword => {
            const kw_mod = @import("../../runtime/keyword.zig");
            try writeJsonString(ctx.w, kw_mod.asKeyword(k).name);
        },
        else => return JsonWriteError.UnsupportedJsonTag,
    }
    try ctx.w.writeAll(":");
    try cwToJson(val, ctx.w, .{});
}

fn cwToJson(v: Value, w: *std.Io.Writer, loc: SourceLocation) anyerror!void {
    _ = loc;
    switch (v.tag()) {
        .nil => try w.writeAll("null"),
        .boolean => try w.writeAll(if (v == Value.true_val) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        // JVM data.json writes a number via Double.toString (scientific
        // notation outside the decimal window) — share cljw's single float
        // formatter rather than Zig's `{d}` (D-171, sibling of D-166).
        .float => try print.printFloat(w, v.asFloat()),
        // JVM data.json writes a BigInt via `(str x)` → plain digits, NO
        // `N` suffix. `Managed.format` (`{f}`) renders just the digits
        // (printBigInt adds the `N` for pr-str; JSON must not). (D-182)
        .big_int => try w.print("{f}", .{big_int_mod.asManaged(v)}),
        .string => try writeJsonString(w, string_collection.asString(v)),
        .keyword => {
            // Keywords serialise as their name string (JVM data.json
            // default: `:keyword-fn` keyword? → str).
            const kw_mod = @import("../../runtime/keyword.zig");
            try writeJsonString(w, kw_mod.asKeyword(v).name);
        },
        .vector => {
            try w.writeAll("[");
            const n = vector_collection.count(v);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try w.writeAll(",");
                try cwToJson(vector_collection.nth(v, i), w, .{});
            }
            try w.writeAll("]");
        },
        // Both map representations (≤8 = array_map, >8 = hash_map/HAMT) walk via
        // the shared `map.forEachEntry`; the old code only handled `.array_map`,
        // so `write-str` errored on any map past the 8-entry promotion threshold.
        .array_map, .hash_map => {
            try w.writeAll("{");
            var ctx = MapEmitCtx{ .w = w, .first = true };
            try map_collection.forEachEntry(v, &ctx, emitJsonEntry);
            try w.writeAll("}");
        },
        .sorted_map => {
            try w.writeAll("{");
            var ctx = MapEmitCtx{ .w = w, .first = true };
            try sorted_collection.forEachEntry(v, &ctx, emitJsonEntry);
            try w.writeAll("}");
        },
        else => return JsonWriteError.UnsupportedJsonTag,
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) JsonWriteError!void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    // Raw 1-arity parsers; the public `read-str`/`write-str` (clojure.data.json
    // ns, json.clj) wrap these to add the `:key-fn`/`:value-fn` options (D-401).
    .{ .name = "-read-str-impl", .f = &readStrFn },
    .{ .name = "-write-str-impl", .f = &writeStrFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.data.json");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
