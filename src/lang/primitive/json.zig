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
const ratio_mod = @import("../../runtime/numeric/ratio.zig");
const keyword_mod = @import("../../runtime/keyword.zig");

/// JVM data.json write defaults: every escape is ON (`:escape-unicode` /
/// `:escape-slash` / `:escape-js-separators` all true). The `.clj` wrapper
/// passes the user's option map through as the optional 2nd impl arg.
const WriteOpts = struct {
    escape_unicode: bool = true,
    escape_slash: bool = true,
    escape_js_separators: bool = true,
};

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
    // GC: read-str fabricates an unpublished result tree (vectors/maps/strings)
    // via recursive jsonToCw + bulk fromSlice/fromLiteralPairs buffers that are
    // unrooted across nested allocs. Since D-519 (alloc-boundary auto-collect)
    // a mid-parse collect would sweep an in-progress buffer → a 0-element /
    // corrupt result (the json_parse bench's intermittent 0-count; deterministic
    // under CLJW_GC_TORTURE_ALLOC). The whole parse is ONE fabrication region:
    // the tree is unpublished until return, and std.json already holds the parsed
    // value in `arena`, so deferring collection is memory-bounded by the doc.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
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
            // PERF: bulk-build via fromSlice instead of empty + N×conj (which
            // allocated N throwaway intermediate vectors per JSON array). Mirrors
            // O-040 (op_vector_literal). The buffer is unrooted across the build,
            // so the whole parse runs inside readStrFn's fabrication region (no
            // mid-build collect can sweep it — see readStrFn). [refs: O-041]
            const n = arr.items.len;
            if (n == 0) break :blk vector_collection.empty();
            const buf = try rt.gc.infra.alloc(Value, n);
            defer rt.gc.infra.free(buf);
            for (arr.items, 0..) |item, i| {
                buf[i] = try jsonToCw(rt, item, loc);
            }
            break :blk try vector_collection.fromSlice(rt, buf);
        },
        .object => |obj| blk: {
            // PERF: bulk-build small maps via fromLiteralPairs (one alloc) instead
            // of empty + N×assoc (N intermediate array-maps). Mirrors O-026. JSON
            // keys are unique strings (simple keys), so the dedup keyEq is pure.
            // Larger maps fall back to the assoc fold. [refs: O-041]
            const n = obj.count();
            if (n == 0) break :blk map_collection.empty();
            const buf = try rt.gc.infra.alloc(Value, n * 2);
            defer rt.gc.infra.free(buf);
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 2) {
                buf[i] = try string_collection.alloc(rt, entry.key_ptr.*);
                buf[i + 1] = try jsonToCw(rt, entry.value_ptr.*, loc);
            }
            if (n <= map_collection.ARRAY_MAP_THRESHOLD and map_collection.allSimpleKeys(buf)) {
                break :blk try map_collection.fromLiteralPairs(rt, buf);
            }
            var out = map_collection.empty();
            var j: usize = 0;
            while (j < buf.len) : (j += 2) {
                out = map_collection.assoc(rt, out, buf[j], buf[j + 1]) catch |err| switch (err) {
                    error.AssocOnNonMap => unreachable,
                    else => |e| return e,
                };
            }
            break :blk out;
        },
    };
}

/// Read one `:escape-*` boolean from the wrapper's option map (absent → the
/// JVM default true).
fn boolOpt(m: Value, kw_name: []const u8) bool {
    if (m.tag() != .array_map and m.tag() != .hash_map) return true;
    var ctx: struct { name: []const u8, out: bool = true } = .{ .name = kw_name };
    map_collection.forEachEntry(m, &ctx, struct {
        fn f(c: *@TypeOf(ctx), k: Value, v: Value) anyerror!void {
            if (k.tag() == .keyword and std.mem.eql(u8, keyword_mod.asKeyword(k).name, c.name))
                c.out = v.isTruthy();
        }
    }.f) catch {};
    return ctx.out;
}

pub fn writeStrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "write-str", .expected = 1, .got = args.len });
    }
    const opts: WriteOpts = if (args.len == 2) .{
        .escape_unicode = boolOpt(args[1], "escape-unicode"),
        .escape_slash = boolOpt(args[1], "escape-slash"),
        .escape_js_separators = boolOpt(args[1], "escape-js-separators"),
    } else .{};
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    errdefer aw.deinit();
    cwToJson(args[0], &aw.writer, opts) catch |err| switch (err) {
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
/// writer + opts + a running first-flag for comma separation.
const MapEmitCtx = struct { w: *std.Io.Writer, opts: WriteOpts, first: bool };

fn emitJsonEntry(ctx: *MapEmitCtx, k: Value, val: Value) anyerror!void {
    if (!ctx.first) try ctx.w.writeAll(",");
    ctx.first = false;
    // Coerce non-string keys to their string form (JSON keys must be strings).
    switch (k.tag()) {
        .string => try writeJsonString(ctx.w, string_collection.asString(k), ctx.opts),
        .keyword => try writeJsonString(ctx.w, keyword_mod.asKeyword(k).name, ctx.opts),
        else => return JsonWriteError.UnsupportedJsonTag,
    }
    try ctx.w.writeAll(":");
    try cwToJson(val, ctx.w, ctx.opts);
}

fn cwToJson(v: Value, w: *std.Io.Writer, opts: WriteOpts) anyerror!void {
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
        // JVM data.json writes a Ratio as its double value (1/2 → 0.5).
        .ratio => {
            const f = switch (ratio_mod.parts(v)) {
                .small => |s| @as(f64, @floatFromInt(s.n)) / @as(f64, @floatFromInt(s.d)),
                .big => |b| b.n.m.toFloat(f64, .nearest_even)[0] / b.d.m.toFloat(f64, .nearest_even)[0],
            };
            try print.printFloat(w, f);
        },
        .string => try writeJsonString(w, string_collection.asString(v), opts),
        // Keywords serialise as their name string (JVM data.json
        // default: `:keyword-fn` keyword? → str).
        .keyword => try writeJsonString(w, keyword_mod.asKeyword(v).name, opts),
        .vector => {
            try w.writeAll("[");
            const n = vector_collection.count(v);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try w.writeAll(",");
                try cwToJson(vector_collection.nth(v, i), w, opts);
            }
            try w.writeAll("]");
        },
        // Both map representations (≤8 = array_map, >8 = hash_map/HAMT) walk via
        // the shared `map.forEachEntry`; the old code only handled `.array_map`,
        // so `write-str` errored on any map past the 8-entry promotion threshold.
        .array_map, .hash_map => {
            try w.writeAll("{");
            var ctx = MapEmitCtx{ .w = w, .opts = opts, .first = true };
            try map_collection.forEachEntry(v, &ctx, emitJsonEntry);
            try w.writeAll("}");
        },
        .sorted_map => {
            try w.writeAll("{");
            var ctx = MapEmitCtx{ .w = w, .opts = opts, .first = true };
            try sorted_collection.forEachEntry(v, &ctx, emitJsonEntry);
            try w.writeAll("}");
        },
        else => return JsonWriteError.UnsupportedJsonTag,
    }
}

/// One `\uXXXX` escape (lowercase hex, the JVM data.json form).
fn writeUEscape(w: *std.Io.Writer, unit: u16) JsonWriteError!void {
    try w.print("\\u{x:0>4}", .{unit});
}

/// Re-encode one codepoint as UTF-8 (the unescaped output path).
fn writeCp(w: *std.Io.Writer, cp: u21) JsonWriteError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return JsonWriteError.WriteFailed;
    try w.writeAll(buf[0..n]);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8, opts: WriteOpts) JsonWriteError!void {
    try w.writeAll("\"");
    // Codepoint walk (not bytes): `:escape-unicode` emits UTF-16 units —
    // an astral codepoint becomes a SURROGATE PAIR (U+1F600 →
    // backslash-uD83D backslash-uDE00), exactly as the JVM writes it.
    var it = std.unicode.Utf8View.init(s) catch {
        // Invalid UTF-8 — emit bytes raw (a cw string is normally valid).
        try w.writeAll(s);
        try w.writeAll("\"");
        return;
    };
    var cps = it.iterator();
    while (cps.nextCodepoint()) |cp| {
        switch (cp) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            '/' => try w.writeAll(if (opts.escape_slash) "\\/" else "/"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writeUEscape(w, @intCast(cp)),
            // JS string separators: escaped even under `:escape-unicode false`
            // unless `:escape-js-separators false` (the JVM option split).
            0x2028, 0x2029 => if (opts.escape_unicode or opts.escape_js_separators)
                try writeUEscape(w, @intCast(cp))
            else
                try writeCp(w, cp),
            else => {
                if (cp > 0x7E and opts.escape_unicode) {
                    if (cp <= 0xFFFF) {
                        try writeUEscape(w, @intCast(cp));
                    } else {
                        const v20: u21 = cp - 0x10000;
                        try writeUEscape(w, @intCast(0xD800 + (v20 >> 10)));
                        try writeUEscape(w, @intCast(0xDC00 + (v20 & 0x3FF)));
                    }
                } else {
                    try writeCp(w, cp);
                }
            },
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
