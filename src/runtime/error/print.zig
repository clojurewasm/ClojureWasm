//! Source-context error rendering.
//!
//! Given an `error.Info` payload + the original source text, render a
//! human-readable diagnostic of the form:
//!
//!     <file>:<line>:<col>: <kind> [<phase>]
//!       <source line>
//!       <caret>
//!     <message>
//!
//! When `info.location.line == 0` (location unknown), the source line
//! and caret are skipped — the renderer falls back to header + message.
//!
//! This is wired into `src/main.zig`'s three catch sites
//! (Read / Analyse / Eval). Real `SourceLocation` values flow
//! through the Reader, Analyzer, and TreeWalk so the line/caret
//! pinpoints the offending sub-expression.

const std = @import("std");
const Writer = std.Io.Writer;
const error_mod = @import("info.zig");
const runtime_mod = @import("../runtime.zig");

/// Source context passed to the renderer. The caller (typically
/// `main.zig`) knows the filename label and the full source text.
pub const SourceContext = struct {
    /// Display label for the source: a real path, `<-e>`, `<stdin>`, …
    file: []const u8,
    /// Full source text. Used to extract the offending line.
    text: []const u8,
};

/// Render options.
pub const Options = struct {
    /// Reserved for future ANSI color output; the renderer always
    /// renders plain today (the flag is not yet consulted).
    enable_ansi: bool = false,
};

/// Extract a 1-based `line_num` from `source`. Returns `null` when the
/// line number is 0 or beyond the last line. The returned slice does
/// **not** include the trailing `\n`.
pub fn extractLine(source: []const u8, line_num: u32) ?[]const u8 {
    if (line_num == 0) return null;
    var current_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (current_line == line_num) return source[line_start..i];
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line == line_num and line_start < source.len) return source[line_start..];
    return null;
}

/// Render `info` using `rt.source_registry` for source-line preview
/// when `info.location.file` matches a registered label; otherwise
/// fall back to `default_ctx.text`. ADR-0035 D7 / D-058 closure.
/// Bootstrap-time errors land at the right file's bytes; user-input
/// errors keep using their caller-supplied SourceContext.
pub fn formatErrorWithRegistry(
    info: error_mod.Info,
    rt: *runtime_mod.Runtime,
    default_ctx: SourceContext,
    w: *Writer,
    opts: Options,
) Writer.Error!void {
    const file = info.location.file;
    const ctx = if (file.len > 0 and !std.mem.eql(u8, file, "unknown"))
        (rt.lookupSource(file) orelse default_ctx)
    else
        default_ctx;
    try formatErrorWithContext(info, ctx, w, opts);
}

/// Render `info` (with optional source context) to `w`. Always returns
/// `void` on success — the caller is responsible for flushing.
pub fn formatErrorWithContext(
    info: error_mod.Info,
    ctx: SourceContext,
    w: *Writer,
    opts: Options,
) Writer.Error!void {
    _ = opts; // ANSI reserved
    const file_label = if (info.location.file.len > 0 and !std.mem.eql(u8, info.location.file, "unknown"))
        info.location.file
    else
        ctx.file;

    // Header: "<Natural Kind> at <file>:<line>:<col>" (ADR-0118 Decision C —
    // v0-style natural label, cljw-native, no JVM class; the `[phase]` bracket
    // moves to the EDN `:phase` only). The location is omitted when unknown.
    try writeNaturalKind(w, info.kindLabel());
    if (info.location.line != 0) {
        try w.print(" at {s}:{d}:{d}\n", .{ file_label, info.location.line, info.location.column });
    } else {
        try w.writeByte('\n');
    }

    // Message, indented under the header.
    try w.print("  {s}\n", .{info.message});

    // Numbered ±2-line source window with an inline `^--- <message>` caret on
    // the error line (only when the position is known and the line is present).
    if (info.location.line != 0 and extractLine(ctx.text, info.location.line) != null) {
        try w.writeByte('\n');
        const err_line = info.location.line;
        const start: u32 = if (err_line > 2) err_line - 2 else 1;
        const end: u32 = err_line + 2;
        const max_digits = countDigits(end);
        const gutter_width = 2 + max_digits + 3; // "  " + line-number + " | "
        var n: u32 = start;
        while (n <= end) : (n += 1) {
            const line = extractLine(ctx.text, n) orelse continue;
            try w.writeAll("  ");
            try writePaddedNum(w, n, max_digits);
            try w.print(" | {s}\n", .{line});
            if (n == err_line) {
                var pad: usize = 0;
                const indent = gutter_width + @as(usize, info.location.column);
                while (pad < indent) : (pad += 1) try w.writeByte(' ');
                try w.print("^--- {s}\n", .{info.message});
            }
        }
    }
}

/// Write `label` (an `info.kindLabel()` snake value like `arithmetic_error`)
/// as a natural header label (`Arithmetic error`): first char uppercased,
/// underscores rendered as spaces. The EDN path keeps the raw keyword.
/// Shared with the post-mortem `render-error` decoder (`app/render_error.zig`)
/// so live stderr and decoded-log output stay in lockstep.
pub fn writeNaturalKind(w: *Writer, label: []const u8) Writer.Error!void {
    for (label, 0..) |c, idx| {
        if (idx == 0) {
            try w.writeByte(std.ascii.toUpper(c));
        } else if (c == '_') {
            try w.writeByte(' ');
        } else {
            try w.writeByte(c);
        }
    }
}

/// Base-10 digit count of `n` (≥ 1 always; `n == 0` returns 1).
fn countDigits(n: u32) usize {
    var x = n;
    var d: usize = 1;
    while (x >= 10) : (x /= 10) d += 1;
    return d;
}

/// Right-align `n` in a field of `width` digits, space-padded.
fn writePaddedNum(w: *Writer, n: u32, width: usize) Writer.Error!void {
    var pad = width - countDigits(n);
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{d}", .{n});
}

// --- tests ---

const testing = std.testing;

test "extractLine: single-line source" {
    const src = "abc";
    try testing.expectEqualStrings("abc", extractLine(src, 1).?);
    try testing.expect(extractLine(src, 0) == null);
    try testing.expect(extractLine(src, 2) == null);
}

test "extractLine: multi-line source" {
    const src = "first\nsecond\nthird";
    try testing.expectEqualStrings("first", extractLine(src, 1).?);
    try testing.expectEqualStrings("second", extractLine(src, 2).?);
    try testing.expectEqualStrings("third", extractLine(src, 3).?);
    try testing.expect(extractLine(src, 4) == null);
}

test "extractLine: trailing newline" {
    const src = "a\nb\n";
    try testing.expectEqualStrings("a", extractLine(src, 1).?);
    try testing.expectEqualStrings("b", extractLine(src, 2).?);
    // Empty line after the final \n is not counted.
    try testing.expect(extractLine(src, 3) == null);
}

test "extractLine: empty source" {
    try testing.expect(extractLine("", 1) == null);
}

test "formatErrorWithContext: with line + caret" {
    const info = error_mod.Info{
        .kind = .type_error,
        .phase = .eval,
        .message = "+: expected number, got keyword",
        .location = .{ .file = "<-e>", .line = 1, .column = 5 },
    };
    const ctx = SourceContext{ .file = "<-e>", .text = "(+ 1 :foo)" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithContext(info, ctx, &w, .{});
    try testing.expectEqualStrings(
        \\Type error at <-e>:1:5
        \\  +: expected number, got keyword
        \\
        \\  1 | (+ 1 :foo)
        \\           ^--- +: expected number, got keyword
        \\
    , w.buffered());
}

test "formatErrorWithContext: unknown location skips source line" {
    const info = error_mod.Info{
        .kind = .name_error,
        .phase = .analysis,
        .message = "x: unable to resolve symbol",
        .location = .{ .file = "unknown", .line = 0, .column = 0 },
    };
    const ctx = SourceContext{ .file = "<-e>", .text = "x" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithContext(info, ctx, &w, .{});
    try testing.expectEqualStrings(
        \\Name error
        \\  x: unable to resolve symbol
        \\
    , w.buffered());
}

test "formatErrorWithContext: location with line on multi-line input" {
    const info = error_mod.Info{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "unexpected ')'",
        .location = .{ .file = "script.clj", .line = 2, .column = 0 },
    };
    const ctx = SourceContext{ .file = "script.clj", .text = "(+ 1 2)\n)\n(+ 3 4)" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithContext(info, ctx, &w, .{});
    try testing.expectEqualStrings(
        \\Syntax error at script.clj:2:0
        \\  unexpected ')'
        \\
        \\  1 | (+ 1 2)
        \\  2 | )
        \\      ^--- unexpected ')'
        \\  3 | (+ 3 4)
        \\
    , w.buffered());
}

test "formatErrorWithContext: prefers info.location.file when set" {
    const info = error_mod.Info{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "bad token",
        .location = .{ .file = "real.clj", .line = 1, .column = 0 },
    };
    const ctx = SourceContext{ .file = "<-e>", .text = "abc" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithContext(info, ctx, &w, .{});
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "Syntax error at real.clj:1:0"));
}

test "formatErrorWithRegistry uses registry entry when info.location.file matches" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = runtime_mod.Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    // Register two different files; only `<clojure.set>` should be
    // consulted when info.location.file matches it.
    try rt.registerSource("<bootstrap>", "(in-ns 'clojure.core)\n(def x 1)\n");
    try rt.registerSource("<clojure.set>", "(in-ns 'clojure.set)\n(def union :stub)\n");

    const info = error_mod.Info{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "demo",
        .location = .{ .file = "<clojure.set>", .line = 2, .column = 0 },
    };
    const fallback = SourceContext{ .file = "<-e>", .text = "wrong-source" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithRegistry(info, &rt, fallback, &w, .{});
    // Source-line preview must use the per-file registry entry, not
    // the fallback `<-e>` ctx text.
    try testing.expect(std.mem.find(u8, w.buffered(), "(def union :stub)") != null);
    try testing.expect(std.mem.find(u8, w.buffered(), "wrong-source") == null);
}

test "formatErrorWithRegistry falls back to default_ctx when label is unknown" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = runtime_mod.Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const info = error_mod.Info{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "demo",
        .location = .{ .file = "<-e>", .line = 1, .column = 0 },
    };
    const fallback = SourceContext{ .file = "<-e>", .text = "(+ 1 2)" };

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatErrorWithRegistry(info, &rt, fallback, &w, .{});
    // No registry entry — must use fallback's text.
    try testing.expect(std.mem.find(u8, w.buffered(), "(+ 1 2)") != null);
}
