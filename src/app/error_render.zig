// SPDX-License-Identifier: EPL-2.0
//! Top-level error rendering for `cljw` CLI sessions. Pulls the
//! threadlocal `Info` populated by `runtime/error/catalog.zig::raise`
//! and formats it via `runtime/error/print.zig`; falls back to bare
//! `@errorName(err)` so an unwired catch site still produces some
//! output instead of swallowing the failure.
//!
//! Row 8.1 (D-031) extracted these four fns from `src/main.zig` so
//! `main.zig` shrinks to a thin entry-point dispatcher. The exit-code
//! mapping (per ADR-0019) lives in `kindToExitCode`; per-Kind
//! dispatch is intentional so future Kinds (`overflow_error`,
//! `permission_error`, ...) pick their exit codes without touching
//! the catch sites.

const std = @import("std");
const Writer = std.Io.Writer;

const error_mod = @import("../runtime/error/info.zig");
const error_print = @import("../runtime/error/print.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;

/// Render a caught error to stderr. Prefers the structured threadlocal
/// `Info` (when populated by `setErrorFmt`); falls back to bare
/// `@errorName(err)` so an unwired call site still produces *some*
/// output instead of swallowing the failure.
///
/// Row 14.13 (D-066): respects the `CLJW_ERROR_FORMAT` env var via
/// `currentFormat` which the CLI dispatcher sets from
/// `init.environ_map` at startup. Two formats:
/// - `text` (default): human-readable carat-pointer format.
/// - `edn`: structured EDN map for `cljw render-error` post-mortem
///   decoding + machine-driven tooling (CIDER / editors / log
///   aggregators). `CLJW_ERROR_LOG` file-append rides the same
///   D-066 follow-up; not in this cycle.
pub fn renderError(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) Writer.Error!void {
    if (error_mod.getLastError()) |info| {
        switch (currentFormat) {
            .text => try error_print.formatErrorWithContext(info, ctx, stderr, .{}),
            .edn => try formatErrorEdn(info, ctx, stderr),
        }
        appendToLogFile(info, ctx);
    } else {
        switch (currentFormat) {
            .text => try stderr.print("{s}: error: {s}\n", .{ ctx.file, @errorName(err) }),
            .edn => try stderr.print("{{:cljw/error true :file \"{s}\" :kind :unknown :message \"{s}\"}}\n", .{ ctx.file, @errorName(err) }),
        }
    }
    try stderr.flush();
}

/// Output format selector. The CLI dispatcher sets this from the
/// `CLJW_ERROR_FORMAT` env var at startup (via `init.environ_map`
/// since `std.posix.getenv` is gone in Zig 0.16). Process-wide
/// because error_render is reachable from every layer; a per-call
/// override would require threading a parameter through every
/// `catch |err| renderAndExit(...)` site.
pub const ErrorFormat = enum { text, edn };

pub var currentFormat: ErrorFormat = .text;

/// Append-only EDN log file path (from `CLJW_ERROR_LOG`). When non-
/// null, `renderError` writes the EDN event to this path IN ADDITION
/// to stderr — the structured render is always written even when
/// `CLJW_ERROR_FORMAT=text` (the file is unconditionally machine-
/// parseable). nil = stderr-only.
pub var logFilePath: ?[]const u8 = null;

/// Cached `Io` handle for log-file writes. Set by the CLI dispatcher
/// alongside `currentFormat` + `logFilePath` so the renderer can open
/// the file on demand. nil = log-file write disabled.
pub var logIo: ?std.Io = null;

/// Parse a CLJW_ERROR_FORMAT value into the enum; `text` on any
/// unrecognised value so a typo doesn't break the user's output.
pub fn parseFormat(value: []const u8) ErrorFormat {
    if (std.mem.eql(u8, value, "edn")) return .edn;
    return .text;
}

/// Append the EDN-rendered error event to `CLJW_ERROR_LOG` if set.
/// Best-effort: a failed log write is logged to stderr but does NOT
/// propagate (the primary stderr render must always succeed).
fn appendToLogFile(info: error_mod.Info, ctx: error_print.SourceContext) void {
    const path = logFilePath orelse return;
    const io = logIo orelse return;
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .read = false, .truncate = false, .lock = .exclusive }) catch return;
    defer file.close(io);
    // Render EDN into an arena-backed allocating writer, then
    // `writePositional` at the file's current length (= append).
    // Zig 0.16's `Io.File` has no `seekFromEnd`; `length(io)` +
    // positional write covers append without truncating older content.
    const offset = file.length(io) catch return;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    formatErrorEdn(info, ctx, &aw.writer) catch return;
    file.writePositionalAll(io, aw.written(), offset) catch return;
}

/// EDN structured error event. Mirrors the JVM Clojure
/// ExceptionInfo pattern: a single map carrying `:kind` /
/// `:phase` / `:file` / `:line` / `:column` / `:message` + the
/// `:cljw/error true` discriminator that lets `cljw render-error`
/// recognise the event in mixed log output.
fn formatErrorEdn(info: error_mod.Info, ctx: error_print.SourceContext, w: *Writer) Writer.Error!void {
    _ = ctx;
    try w.print(
        "{{:cljw/error true :kind :{s} :phase :{s} :file \"{s}\" :line {d} :column {d} :message \"",
        .{
            @tagName(info.kind),
            @tagName(info.phase),
            info.location.file,
            info.location.line,
            info.location.column,
        },
    );
    // EDN string escape — quotes and backslashes only at this fidelity.
    for (info.message) |c| {
        switch (c) {
            '"', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"}\n");
}

/// Map a `Kind` to the process exit code per ADR-0019. The catalog
/// `internal_error` Code is the sole exit-70 path; every other Kind
/// is a user-facing catalog error and exits 1.
pub fn kindToExitCode(kind: error_mod.Kind) u8 {
    return switch (kind) {
        .internal_error => 70,
        else => 1,
    };
}

/// Peek the threadlocal `Info` (without consuming it), pick the
/// matching exit code per ADR-0019, render the error, then exit.
/// Centralises the "catch site exits the process" pattern so future
/// Kinds need only update `kindToExitCode`.
pub fn renderAndExit(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) noreturn {
    const code: u8 = if (error_mod.peekLastError()) |info|
        kindToExitCode(info.kind)
    else
        1;
    renderError(stderr, ctx, err) catch {
        // stderr write failed (closed pipe?); proceed to exit anyway —
        // the alternative is swallowing the failure silently.
    };
    std.process.exit(code);
}

/// Registry-aware variant of `renderAndExit`. ADR-0035 D7: looks up
/// `info.location.file` in `rt.source_registry` for the per-file
/// source-line preview; falls back to `default_ctx` when the location
/// is unknown or not registered.
pub fn renderAndExitRegistry(
    stderr: *Writer,
    rt: *Runtime,
    default_ctx: error_print.SourceContext,
    err: anyerror,
) noreturn {
    const code: u8 = if (error_mod.peekLastError()) |info|
        kindToExitCode(info.kind)
    else
        1;
    if (error_mod.getLastError()) |info| {
        error_print.formatErrorWithRegistry(info, rt, default_ctx, stderr, .{}) catch {};
        stderr.flush() catch {};
    } else {
        stderr.print("{s}: error: {s}\n", .{ default_ctx.file, @errorName(err) }) catch {};
        stderr.flush() catch {};
    }
    std.process.exit(code);
}
