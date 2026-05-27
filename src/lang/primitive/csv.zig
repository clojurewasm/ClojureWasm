// SPDX-License-Identifier: EPL-2.0
//! `clojure.data.csv` Tier-A surface (§9.11 row 9.4). RFC 4180 dialect.
//!
//! ## Surface
//!
//! - `(read-csv s)` → vector of vectors of strings (one outer row
//!   per CSV record; one inner cell per comma-separated field).
//!   cw v1 returns an eager vector; JVM `clojure.data.csv/read-csv`
//!   returns a lazy seq over a Reader. Eager-vs-lazy tracked as a
//!   follow-up debt row.
//! - `(write-csv data)` → string. cw v1 returns the CSV text
//!   directly; JVM takes a Writer + writes there. The string-return
//!   shape is cw-specific (parallel to `clojure.data.json/write-str`).
//!
//! ## RFC 4180 dialect rules implemented
//!
//! - `,` separates fields.
//! - `\n` or `\r\n` separates records (CRLF + LF both accepted).
//! - A field may be quoted with `"`. Quoted fields may contain `,`,
//!   `\n`, and escaped `""` (= literal `"`).
//! - Unquoted fields trim no whitespace (raw substring).
//!
//! **Location note (D-095)**: lives at `src/lang/primitive/` per
//! the same Zig-0.16 module-path constraint as edn/json.

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

pub fn readCsvFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("read-csv", args, 1, loc);
    const arg = args[0];
    if (arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-csv",
            .actual = @tagName(arg.tag()),
        });
    }
    const source = string_collection.asString(arg);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var rows = std.ArrayList([]const []const u8).empty;
    var current_row = std.ArrayList([]const u8).empty;
    var field_buf = std.ArrayList(u8).empty;

    var i: usize = 0;
    var in_quotes = false;
    while (i < source.len) {
        const c = source[i];
        if (in_quotes) {
            if (c == '"') {
                if (i + 1 < source.len and source[i + 1] == '"') {
                    try field_buf.append(aalloc, '"');
                    i += 2;
                } else {
                    in_quotes = false;
                    i += 1;
                }
            } else {
                try field_buf.append(aalloc, c);
                i += 1;
            }
        } else {
            switch (c) {
                '"' => {
                    in_quotes = true;
                    i += 1;
                },
                ',' => {
                    try current_row.append(aalloc, try aalloc.dupe(u8, field_buf.items));
                    field_buf.clearRetainingCapacity();
                    i += 1;
                },
                '\r' => {
                    // CRLF — consume the LF too if present
                    if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
                    try current_row.append(aalloc, try aalloc.dupe(u8, field_buf.items));
                    field_buf.clearRetainingCapacity();
                    try rows.append(aalloc, try aalloc.dupe([]const u8, current_row.items));
                    current_row.clearRetainingCapacity();
                    i += 1;
                },
                '\n' => {
                    try current_row.append(aalloc, try aalloc.dupe(u8, field_buf.items));
                    field_buf.clearRetainingCapacity();
                    try rows.append(aalloc, try aalloc.dupe([]const u8, current_row.items));
                    current_row.clearRetainingCapacity();
                    i += 1;
                },
                else => {
                    try field_buf.append(aalloc, c);
                    i += 1;
                },
            }
        }
    }
    // Final field / row (no trailing newline).
    if (field_buf.items.len > 0 or current_row.items.len > 0) {
        try current_row.append(aalloc, try aalloc.dupe(u8, field_buf.items));
        try rows.append(aalloc, try aalloc.dupe([]const u8, current_row.items));
    }

    // Materialise rows into cw vector<vector<string>>.
    var out = vector_collection.empty();
    for (rows.items) |row| {
        var row_vec = vector_collection.empty();
        for (row) |cell| {
            const s = try string_collection.alloc(rt, cell);
            row_vec = try vector_collection.conj(rt, row_vec, s);
        }
        out = try vector_collection.conj(rt, out, row_vec);
    }
    return out;
}

pub fn writeCsvFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("write-csv", args, 1, loc);
    const data = args[0];
    if (data.tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "write-csv",
            .expected = "vector of vector-of-strings",
            .actual = @tagName(data.tag()),
        });
    }

    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    errdefer aw.deinit();

    const n_rows = vector_collection.count(data);
    var ri: u32 = 0;
    while (ri < n_rows) : (ri += 1) {
        const row = vector_collection.nth(data, ri);
        if (row.tag() != .vector) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "write-csv",
                .expected = "inner row must be a vector",
                .actual = @tagName(row.tag()),
            });
        }
        const n_cells = vector_collection.count(row);
        var ci: u32 = 0;
        while (ci < n_cells) : (ci += 1) {
            if (ci > 0) try aw.writer.writeAll(",");
            const cell = vector_collection.nth(row, ci);
            if (cell.tag() != .string) {
                return error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "write-csv",
                    .expected = "cell must be a string",
                    .actual = @tagName(cell.tag()),
                });
            }
            try writeCsvField(&aw.writer, string_collection.asString(cell));
        }
        try aw.writer.writeAll("\n");
    }

    const owned = try aw.toOwnedSlice();
    defer rt.gpa.free(owned);
    return try string_collection.alloc(rt, owned);
}

fn writeCsvField(w: *std.Io.Writer, s: []const u8) !void {
    // Quote the field iff it contains comma, double-quote, CR, or LF.
    var needs_quote = false;
    for (s) |c| {
        if (c == ',' or c == '"' or c == '\r' or c == '\n') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        try w.writeAll(s);
        return;
    }
    try w.writeAll("\"");
    for (s) |c| {
        if (c == '"') {
            try w.writeAll("\"\"");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeAll("\"");
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "read-csv", .f = &readCsvFn },
    .{ .name = "write-csv", .f = &writeCsvFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.data.csv");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
