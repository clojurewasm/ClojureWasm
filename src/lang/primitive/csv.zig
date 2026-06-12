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
const list_collection = @import("../../runtime/collection/list.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const print_mod = @import("../../runtime/print.zig");
const sequence = @import("sequence.zig");

/// Shared option surface (JVM data.csv): `:separator` / `:quote` are char
/// options on both read and write; `:newline` (`:lf` default | `:cr+lf`) is
/// write-only. Parsed from the trailing kv args.
const CsvOpts = struct {
    separator: u8 = ',',
    quote: u8 = '"',
    crlf: bool = false,
};

fn parseOpts(kvs: []const Value, fn_name: []const u8, loc: SourceLocation) !CsvOpts {
    var o: CsvOpts = .{};
    if (kvs.len % 2 != 0)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = fn_name, .expected = 2, .got = kvs.len });
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) {
        if (kvs[i].tag() != .keyword) continue;
        const name = keyword_mod.asKeyword(kvs[i]).name;
        const v = kvs[i + 1];
        if (std.mem.eql(u8, name, "separator") and v.tag() == .char) {
            o.separator = @intCast(v.asChar());
        } else if (std.mem.eql(u8, name, "quote") and v.tag() == .char) {
            o.quote = @intCast(v.asChar());
        } else if (std.mem.eql(u8, name, "newline") and v.tag() == .keyword) {
            o.crlf = std.mem.eql(u8, keyword_mod.asKeyword(v).name, "cr+lf");
        }
    }
    return o;
}

pub fn readCsvFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "read-csv", .expected = 1, .got = args.len });
    const arg = args[0];
    if (arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-csv",
            .actual = @tagName(arg.tag()),
        });
    }
    const opts = try parseOpts(args[1..], "read-csv", loc);
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
            if (c == opts.quote) {
                if (i + 1 < source.len and source[i + 1] == opts.quote) {
                    try field_buf.append(aalloc, opts.quote);
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
            if (c == opts.quote) {
                in_quotes = true;
                i += 1;
                continue;
            }
            if (c == opts.separator) {
                try current_row.append(aalloc, try aalloc.dupe(u8, field_buf.items));
                field_buf.clearRetainingCapacity();
                i += 1;
                continue;
            }
            switch (c) {
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

    // Materialise rows as a LIST of row-VECTORS — clj's read-csv is a (lazy)
    // seq of vectors, so the realized shape prints `(["a" "b"] …)`, not
    // `[["a" "b"] …]`. Built back-to-front by cons.
    var out = try list_collection.emptyList(rt);
    var ri = rows.items.len;
    while (ri > 0) {
        ri -= 1;
        var row_vec = vector_collection.empty();
        for (rows.items[ri]) |cell| {
            const s = try string_collection.alloc(rt, cell);
            row_vec = try vector_collection.conj(rt, row_vec, s);
        }
        out = try list_collection.consHeap(rt, row_vec, out);
    }
    return out;
}

/// `(-write-csv-str data & options)` — serialise rows to a CSV string. The
/// public JVM-shape `write-csv` (csv.clj) writes this string to its Writer
/// arg. Rows and cells walk via the generic seq protocol (vector / list /
/// lazy all accepted, like JVM data.csv); a non-string cell writes its
/// str-form (`(write-csv w [[1 2]])` → "1,2").
pub fn writeCsvFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "-write-csv-str", .expected = 1, .got = args.len });
    const opts = try parseOpts(args[1..], "-write-csv-str", loc);

    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    errdefer aw.deinit();
    const nl: []const u8 = if (opts.crlf) "\r\n" else "\n";

    // `sequence.seqFn` (the core `seq`) coerces ANY seqable — vector / list /
    // lazy — into the walkable seq; `lazy_seq.seq/first/rest` alone pass a
    // vector through with nil first/rest (Layer-0 accessors don't convert).
    var rows = try sequence.seqFn(rt, env, &.{args[0]}, loc);
    while (rows.tag() != .nil) {
        const row = try lazy_seq.first(rt, env, rows);
        var cells = try sequence.seqFn(rt, env, &.{row}, loc);
        var first = true;
        while (cells.tag() != .nil) {
            if (!first) try aw.writer.writeByte(opts.separator);
            first = false;
            const cell = try lazy_seq.first(rt, env, cells);
            if (cell.tag() == .string) {
                try writeCsvField(&aw.writer, string_collection.asString(cell), opts);
            } else {
                var cw: std.Io.Writer.Allocating = .init(rt.gpa);
                defer cw.deinit();
                try print_mod.writeStrValue(rt, env, &cw.writer, cell);
                try writeCsvField(&aw.writer, cw.writer.buffered(), opts);
            }
            cells = try lazy_seq.seq(rt, env, try lazy_seq.rest(rt, env, cells));
        }
        try aw.writer.writeAll(nl);
        rows = try lazy_seq.seq(rt, env, try lazy_seq.rest(rt, env, rows));
    }

    const owned = try aw.toOwnedSlice();
    defer rt.gpa.free(owned);
    return try string_collection.alloc(rt, owned);
}

fn writeCsvField(w: *std.Io.Writer, s: []const u8, opts: CsvOpts) !void {
    // Quote the field iff it contains the separator, the quote char, CR, or LF.
    var needs_quote = false;
    for (s) |c| {
        if (c == opts.separator or c == opts.quote or c == '\r' or c == '\n') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        try w.writeAll(s);
        return;
    }
    try w.writeByte(opts.quote);
    for (s) |c| {
        if (c == opts.quote) {
            try w.writeByte(opts.quote);
            try w.writeByte(opts.quote);
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte(opts.quote);
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "read-csv", .f = &readCsvFn },
    // The public JVM-shape `write-csv` (writer-first, returns nil) wraps this
    // in csv.clj; the impl serialises to a string.
    .{ .name = "-write-csv-str", .f = &writeCsvFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.data.csv");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
