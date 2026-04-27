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
//! Phase 3.1 wires this into `src/main.zig`'s three catch sites
//! (Read / Analyse / Eval). Subsequent tasks 3.2–3.4 thread real
//! `SourceLocation` values through the Reader, Analyzer, and TreeWalk
//! so the line/caret actually pinpoints the offending sub-expression.

const std = @import("std");
const Writer = std.Io.Writer;
const error_mod = @import("error.zig");

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
    /// Reserved for future ANSI color output. Phase 3.1 always renders plain.
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

    // Header
    try w.print("{s}:{d}:{d}: {s} [{s}]\n", .{
        file_label,
        info.location.line,
        info.location.column,
        @tagName(info.kind),
        @tagName(info.phase),
    });

    // Source line + caret (only when line is known)
    if (info.location.line != 0) {
        if (extractLine(ctx.text, info.location.line)) |line| {
            try w.print("  {s}\n  ", .{line});
            // Caret indent: column is 0-based char position. Pad with
            // ASCII spaces, then emit a single '^'. (Multi-byte
            // alignment under proportional fonts is out of scope; for
            // ASCII source this is correct.)
            var i: u16 = 0;
            while (i < info.location.column) : (i += 1) try w.writeByte(' ');
            try w.writeByte('^');
            try w.writeByte('\n');
        }
    }

    // Message
    try w.print("{s}\n", .{info.message});
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
        \\<-e>:1:5: type_error [eval]
        \\  (+ 1 :foo)
        \\       ^
        \\+: expected number, got keyword
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
        \\<-e>:0:0: name_error [analysis]
        \\x: unable to resolve symbol
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
        \\script.clj:2:0: syntax_error [parse]
        \\  )
        \\  ^
        \\unexpected ')'
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
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "real.clj:1:0:"));
}
