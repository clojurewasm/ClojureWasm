// SPDX-License-Identifier: EPL-2.0
//! `cljw render-error <path>` — post-mortem decoder for EDN error
//! events produced by `CLJW_ERROR_LOG` (per `docs/spec/error_format.md`).
//!
//! Reads the file line-by-line, parses each `{:cljw/error true ...}`
//! map, and pretty-prints a human-readable rendering. Lines that
//! don't start with the `:cljw/error true` discriminator are
//! silently passed through (so a log file mixing cljw events with
//! other tool output still renders cleanly).
//!
//! Row 14.11 D-100(c) — initial minimal landing. TTY-aware colour
//! highlighting + multi-event aggregation (groups by file/line) ride
//! the v0.1.0 polish bundle (D-100c follow-up).
//!
//! Decoder strategy: hand-rolled scan for the keyword fields rather
//! than a full EDN parser. The format is single-line per event and
//! the field set is fixed at v0.1.0 (per docs/spec/error_format.md);
//! a full EDN parser is overkill here and would tempt over-flexible
//! decoding that defeats the v0.1.0 stability lock.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    args: anytype,
) !void {
    const path = args.next() orelse {
        try stderr.print("render-error: expected a log file path argument\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        try stderr.print("render-error: cannot open {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer file.close(io);

    var rbuf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &rbuf);
    var line_count: u32 = 0;
    var event_count: u32 = 0;

    while (true) {
        const line_opt = file_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return err,
            error.StreamTooLong => {
                try stderr.print("render-error: line too long (>{d} bytes); skipping\n", .{rbuf.len});
                continue;
            },
        };
        const line = line_opt orelse break;
        line_count += 1;

        // Discriminator check: only render lines that are cljw error
        // events; pass everything else through unchanged so mixed logs
        // are readable.
        if (!std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "{:cljw/error true")) {
            try stdout.print("{s}\n", .{line});
            continue;
        }

        const owned_line = try arena.dupe(u8, line);
        renderOne(stdout, owned_line) catch |err| {
            try stderr.print("render-error: failed to render line {d}: {s}\n", .{ line_count, @errorName(err) });
        };
        event_count += 1;
    }

    try stdout.flush();
    try stderr.print("render-error: {d} event(s) rendered from {d} line(s)\n", .{ event_count, line_count });
    try stderr.flush();
}

fn renderOne(stdout: *Writer, line: []const u8) !void {
    const kind = scanField(line, ":kind :") orelse "unknown";
    const phase = scanField(line, ":phase :") orelse "unknown";
    const file = scanString(line, ":file \"") orelse "unknown";
    const lineno = scanInt(line, ":line ") orelse 0;
    const column = scanInt(line, ":column ") orelse 0;
    const message = scanString(line, ":message \"") orelse "";

    // Human-readable rendering: `<file>:<line>:<column>: <kind> [<phase>]\n  <message>\n`.
    // Mirrors the in-process renderer at runtime/error/print.zig so
    // post-mortem output reads identically to live stderr output.
    try stdout.print("{s}:{d}:{d}: {s} [{s}]\n  {s}\n", .{
        file,
        lineno,
        column,
        kind,
        phase,
        message,
    });
}

/// Scan for `prefix` then the keyword/symbol token (up to whitespace
/// or `}`). Returns null if `prefix` is not found.
fn scanField(line: []const u8, prefix: []const u8) ?[]const u8 {
    const idx = std.mem.find(u8, line, prefix) orelse return null;
    const start = idx + prefix.len;
    var end = start;
    while (end < line.len and !isFieldDelim(line[end])) : (end += 1) {}
    if (end == start) return null;
    return line[start..end];
}

/// Scan for `prefix` then a quoted string (with `\"` escapes
/// honoured but not unescaped — the renderer takes the literal
/// EDN representation since `message` is already EDN-escaped on
/// the emit side).
fn scanString(line: []const u8, prefix: []const u8) ?[]const u8 {
    const idx = std.mem.find(u8, line, prefix) orelse return null;
    const start = idx + prefix.len;
    var end = start;
    while (end < line.len) : (end += 1) {
        if (line[end] == '"' and (end == 0 or line[end - 1] != '\\')) break;
    }
    if (end >= line.len) return null;
    return line[start..end];
}

/// Scan for `prefix` then a non-negative decimal integer.
fn scanInt(line: []const u8, prefix: []const u8) ?u32 {
    const idx = std.mem.find(u8, line, prefix) orelse return null;
    const start = idx + prefix.len;
    var end = start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u32, line[start..end], 10) catch null;
}

fn isFieldDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '}' or c == ',';
}

// --- tests ---

const testing = std.testing;

test "scanField extracts a keyword value" {
    const line = "{:cljw/error true :kind :name_error :phase :analysis}";
    try testing.expectEqualStrings("name_error", scanField(line, ":kind :").?);
    try testing.expectEqualStrings("analysis", scanField(line, ":phase :").?);
}

test "scanString extracts a quoted message" {
    const line = "{:cljw/error true :message \"Unable to resolve symbol: 'foo'\"}";
    try testing.expectEqualStrings("Unable to resolve symbol: 'foo'", scanString(line, ":message \"").?);
}

test "scanInt extracts a decimal field" {
    const line = "{:cljw/error true :line 42 :column 7}";
    try testing.expectEqual(@as(u32, 42), scanInt(line, ":line ").?);
    try testing.expectEqual(@as(u32, 7), scanInt(line, ":column ").?);
}

test "scanField returns null when prefix is missing" {
    const line = "{:cljw/error true :kind :foo}";
    try testing.expect(scanField(line, ":bar :") == null);
}
