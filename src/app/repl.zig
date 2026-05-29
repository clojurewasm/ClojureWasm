// SPDX-License-Identifier: EPL-2.0
//! Minimal interactive REPL for `cljw repl` — F144 re-introduction
//! per ADR-0015 amendment 2 + ADR-0048 (state machine domain ADR).
//!
//! The Phase-14 landing is a **line-buffered prompt loop**: read a
//! line from stdin, parse / analyse / eval, print the result,
//! re-prompt. Per-form errors are caught + rendered and the loop
//! continues — only EOF on stdin terminates. Arrow-key history +
//! cursor editing (true line-editor) ride D-116 as polish.
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
//! The Phase 14 line-buffered loop collapses `reading` into a single
//! `stdin.takeDelimiterExclusive('\n')` call. Phase 14.10 (nREPL)
//! and Phase 14.11 (build pipeline) introduce richer states per
//! ADR-0048; only the REPL chart is exercised here.

const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const Value = @import("../runtime/value/value.zig").Value;
const primitive = @import("../lang/primitive.zig");
const macro_transforms = @import("../lang/macro_transforms.zig");
const bootstrap = @import("../lang/bootstrap.zig");
const error_print = @import("../runtime/error/print.zig");
const print = @import("../runtime/print.zig");

const error_render = @import("error_render.zig");

/// Run the REPL until stdin EOF. `arena` is per-process here — each
/// form's analysis/eval allocates against it, and we never reset; a
/// long-running REPL session is a known memory bottleneck the
/// Phase-15 mark-sweep activation addresses.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
) !void {
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    rt.stdout = stdout; // println/print/prn share the REPL's stdout writer (D-096)

    var env = try Env.init(&rt);
    defer env.deinit();

    driver.installVTable(&rt);
    bootstrap.installEmbeddedResolver(&rt);
    try primitive.registerAll(&env);

    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);

    const bootstrap_ctx = error_print.SourceContext{ .file = bootstrap.SOURCE_LABEL, .text = bootstrap.CORE_SOURCE };
    bootstrap.loadCore(arena, &rt, &env, &macro_table) catch |err| {
        error_render.renderAndExitRegistry(stderr, &rt, bootstrap_ctx, err);
    };

    try stdout.writeAll("ClojureWasm REPL — :exit / Ctrl-D quits.\n");

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    var line_no: usize = 0;

    while (true) : (line_no += 1) {
        // Prompt: <current-ns>=>
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

        // :exit / :quit shortcut so users don't need a Ctrl-D to leave.
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":exit") or std.mem.eql(u8, trimmed, ":quit")) {
            try stdout.writeAll("bye\n");
            try stdout.flush();
            return;
        }

        // Per-line source label so errors attribute to the line number.
        const label = try std.fmt.allocPrint(arena, "<repl:{d}>", .{line_no + 1});
        // The line bytes belong to stdin_reader's internal buffer; dupe
        // into the arena so the per-form ctx outlives the read.
        const line_owned = try arena.dupe(u8, line);
        const ctx = error_print.SourceContext{ .file = label, .text = line_owned };

        evalOneLine(&rt, &env, &macro_table, arena, stdout, stderr, ctx, line_owned) catch |err| {
            // Render and recover; never exit on a per-line error.
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
