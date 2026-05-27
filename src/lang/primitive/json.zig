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
//! matching JVM `clojure.data.json/read-str`'s default. The 2-arity
//! `(read-str s opts)` form with `:key-fn` is a follow-up.
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
            if (i < std.math.minInt(i48) or i > std.math.maxInt(i48)) {
                break :blk error_catalog.raise(.feature_not_supported, loc, .{
                    .name = "JSON integer outside i48 range (BigInt path pending)",
                });
            }
            break :blk Value.initInteger(i);
        },
        .float => |f| Value.initFloat(f),
        .number_string => error_catalog.raise(.feature_not_supported, loc, .{
            .name = "JSON arbitrary-precision number (BigInt path pending)",
        }),
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
                    error.HashMapNotImplemented, error.HashMapPromotionNotImplemented => return error_catalog.raise(.feature_not_supported, loc, .{
                        .name = "JSON object beyond ArrayMap capacity (HAMT pending D-045)",
                    }),
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

fn cwToJson(v: Value, w: *std.Io.Writer, loc: SourceLocation) JsonWriteError!void {
    _ = loc;
    switch (v.tag()) {
        .nil => try w.writeAll("null"),
        .boolean => try w.writeAll(if (v == Value.true_val) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        .float => try w.print("{d}", .{v.asFloat()}),
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
        .array_map => {
            try w.writeAll("{");
            const am = v.decodePtr(*const map_collection.ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                if (i > 0) try w.writeAll(",");
                const k = am.entries[2 * i];
                const val = am.entries[2 * i + 1];
                // Coerce non-string keys to their string form
                // (JSON keys must be strings).
                switch (k.tag()) {
                    .string => try writeJsonString(w, string_collection.asString(k)),
                    .keyword => {
                        const kw_mod = @import("../../runtime/keyword.zig");
                        try writeJsonString(w, kw_mod.asKeyword(k).name);
                    },
                    else => return JsonWriteError.UnsupportedJsonTag,
                }
                try w.writeAll(":");
                try cwToJson(val, w, .{});
            }
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
    .{ .name = "read-str", .f = &readStrFn },
    .{ .name = "write-str", .f = &writeStrFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.data.json");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
