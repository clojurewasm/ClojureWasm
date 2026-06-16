// SPDX-License-Identifier: EPL-2.0
//! Minimal interactive REPL for `cljw repl` — F144 re-introduction
//! per ADR-0015 amendment 2 + ADR-0048 (state machine domain ADR).
//!
//! The REPL is a **line-buffered prompt loop**: read a
//! line from stdin, parse / analyse / eval, print the result,
//! re-prompt. Per-form errors are caught + rendered and the loop
//! continues — only EOF on stdin terminates. Arrow-key history +
//! cursor editing (true line-editor) remain future polish (D-116).
//!
//! State chart (ADR-0048):
//!
//!     ┌──────┐  prompt  ┌──────────┐  line received  ┌────────────┐
//!     │ idle │ ───────▶ │ reading  │ ───────────────▶ │ evaluating │
//!     └──────┘          └──────────┘                  └────────────┘
//!         ▲                  │                              │
//!         │ result printed   │ EOF on stdin                 │ value | error
//!         │                  ▼                              ▼
//!     ┌──────────┐         (exit)                     ┌──────────┐
//!     │ printing │ ◀────────────────────────────────  │  result  │
//!     └──────────┘                                    └──────────┘
//!
//! The line-buffered loop collapses `reading` into a single
//! `stdin.takeDelimiterExclusive('\n')` call. The nREPL and build
//! pipeline charts (also ADR-0048) carry richer states; only the
//! REPL chart is exercised here.

const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const Value = @import("../runtime/value/value.zig").Value;
const bootstrap = @import("../lang/bootstrap.zig");
const require_resolver = @import("../lang/require_resolver.zig");
const error_print = @import("../runtime/error/print.zig");
const print = @import("../runtime/print.zig");

const error_render = @import("error_render.zig");
const LineEditor = @import("repl/line_editor.zig").LineEditor;

/// Run the REPL until stdin EOF. `arena` is per-process here — each
/// form's analysis/eval allocates against it, and we never reset; a
/// long-running REPL session is a known memory bottleneck the
/// Phase B mark-sweep activation addresses.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    /// Filesystem classpath the REPL's `(require …)` searches, so a REPL
    /// prompt resolves user libs off disk exactly as a file/`-e` run does
    /// (D-322). Mirrors `runner.runSource`.
    load_paths: []const []const u8,
    /// Deploy-mode FS jail root (`CLJW_FS_ROOT`), or null for an unconfined
    /// local REPL (ADR-0123 / SE-6/7).
    fs_jail_root: ?[]const u8,
) !void {
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    rt.stdout = stdout; // println/print/prn share the REPL's stdout writer (D-096)

    var env = try Env.init(&rt);
    defer env.deinit();

    driver.installVTable(&rt);

    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    // Full bootstrap prefix (embedded resolver + primitives + macros +
    // data-readers + *ns* var). A bare registerAll+registerInto drifts from
    // setupCorePrefix and leaves *ns* unresolved when test.clj loads (ADR-0083).
    try bootstrap.setupCorePrefix(&rt, &env, &macro_table);

    const bootstrap_ctx = error_print.SourceContext{ .file = bootstrap.SOURCE_LABEL, .text = bootstrap.CORE_SOURCE };
    // ADR-0056 Cycle 2c + Cycle 3 (D-452 Part B): restore the WHOLE eager
    // bootstrap (core + the 23 non-core libs) from the embedded AOT envelope
    // (prefix already done above) — no .clj re-parse on startup.
    bootstrap.loadCoreAot(arena, &rt, &env, @import("bootstrap_cache").data) catch |err| {
        error_render.renderAndExitRegistry(stderr, &rt, bootstrap_ctx, err);
    };

    // ADR-0084 / D-322: enable filesystem `require` for user libs at the REPL.
    // setupCore* installs the embedded-only resolver; swap to the embedded-FIRST
    // chain + the classpath so `(require '[my.lib])` loads off `load_paths` —
    // identical to runner.runSource, so REPL and script `require` are uniform.
    rt.load_paths = load_paths;
    rt.fs_jail_root = fs_jail_root;
    require_resolver.installChained(&rt);

    try stdout.writeAll("ClojureWasm REPL — :exit / Ctrl-D quits.\n");

    // An interactive TTY gets the raw-mode line editor (history + cursor
    // editing + multi-line); a piped / redirected stdin (tcgetattr fails)
    // falls back to the plain buffered line read so heredoc / pipe input
    // still runs and exits cleanly on EOF.
    const interactive = if (std.posix.tcgetattr(std.Io.File.stdin().handle)) |_| true else |_| false;
    if (interactive) {
        var editor = LineEditor.init(gpa, io, stdout, &env);
        defer editor.deinit();
        try runInteractive(&rt, &env, &macro_table, arena, stdout, stderr, &editor);
    } else {
        try runPiped(io, &rt, &env, &macro_table, arena, stdout, stderr);
    }
}

/// Interactive loop driven by the raw-mode line editor.
fn runInteractive(
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    editor: *LineEditor,
) !void {
    var line_no: usize = 0;
    while (true) : (line_no += 1) {
        const ns_name = if (env.current_ns) |ns| ns.name else "user";
        editor.setNsPrompt(ns_name);

        const line = editor.readInput() orelse return; // null = EOF

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":exit") or std.mem.eql(u8, trimmed, ":quit")) {
            try stdout.writeAll("bye\n");
            try stdout.flush();
            return;
        }

        const label = try std.fmt.allocPrint(arena, "<repl:{d}>", .{line_no + 1});
        // `line` is a slice into the editor's internal buffer; dupe into the
        // arena so the per-form ctx outlives the next readInput.
        const line_owned = try arena.dupe(u8, line);
        const ctx = error_print.SourceContext{ .file = label, .text = line_owned };

        evalOneLine(rt, env, macro_table, arena, stdout, stderr, ctx, line_owned) catch |err| {
            error_render.renderError(stderr, ctx, err) catch {};
            try stderr.flush();
        };
    }
}

/// Plain buffered loop for non-TTY stdin (pipe / heredoc / redirect).
fn runPiped(
    io: std.Io,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    var line_no: usize = 0;

    while (true) : (line_no += 1) {
        const ns_name = if (env.current_ns) |ns| ns.name else "user";
        try stdout.print("{s}=> ", .{ns_name});
        try stdout.flush();

        const line_opt = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => {
                try stdout.writeAll("\n");
                try stdout.flush();
                return;
            },
            error.StreamTooLong => {
                try stderr.print("repl: input line too long (>{d} bytes); discarding\n", .{stdin_buf.len});
                try stderr.flush();
                continue;
            },
        };
        const line = line_opt orelse {
            try stdout.writeAll("\n");
            try stdout.flush();
            return;
        };

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":exit") or std.mem.eql(u8, trimmed, ":quit")) {
            try stdout.writeAll("bye\n");
            try stdout.flush();
            return;
        }

        const label = try std.fmt.allocPrint(arena, "<repl:{d}>", .{line_no + 1});
        const line_owned = try arena.dupe(u8, line);
        const ctx = error_print.SourceContext{ .file = label, .text = line_owned };

        evalOneLine(rt, env, macro_table, arena, stdout, stderr, ctx, line_owned) catch |err| {
            error_render.renderError(stderr, ctx, err) catch {};
            try stderr.flush();
        };
    }
}

fn evalOneLine(
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    ctx: error_print.SourceContext,
    source: []const u8,
) !void {
    _ = stderr;
    _ = ctx;
    var reader = Reader.init(arena, source);
    while (true) {
        const form_opt = try reader.read();
        const form = form_opt orelse return;
        const node = try analyzeForm(arena, rt, env, null, form, macro_table);
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        const result = try driver.evalForm(rt, env, &locals, arena, node);
        try print.printResult(rt, env, stdout, result);
        try stdout.writeByte('\n');
        try stdout.flush();
    }
}
