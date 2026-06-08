// SPDX-License-Identifier: EPL-2.0
//! Top-level error rendering for `cljw` CLI sessions. Pulls the
//! threadlocal `Info` populated by `runtime/error/catalog.zig::raise`
//! and formats it via `runtime/error/print.zig`; falls back to bare
//! `@errorName(err)` so an unwired catch site still produces some
//! output instead of swallowing the failure.
//!
//! These four fns were extracted from `src/main.zig` (D-031) so
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
const print_value = @import("../runtime/print.zig").printValue;
const map_collection = @import("../runtime/collection/map.zig");
const dispatch = @import("../runtime/dispatch.zig");
const ex_info = @import("../runtime/collection/ex_info.zig");
const Value = @import("../runtime/value/value.zig").Value;

/// Render a caught error to stderr. Prefers the structured threadlocal
/// `Info` (when populated by `setErrorFmt`); falls back to bare
/// `@errorName(err)` so an unwired call site still produces *some*
/// output instead of swallowing the failure.
///
/// Respects the `CLJW_ERROR_FORMAT` env var (D-066) via `currentFormat`,
/// which the CLI dispatcher sets from `init.environ_map` at startup.
/// Two formats:
/// - `text` (default): human-readable carat-pointer format.
/// - `edn`: structured EDN map for `cljw render-error` post-mortem
///   decoding + machine-driven tooling (CIDER / editors / log
///   aggregators). When `CLJW_ERROR_LOG` is set, the rendered error
///   is also appended to that file via `appendToLogFile`.
pub fn renderError(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) Writer.Error!void {
    if (error_mod.getLastError()) |info| {
        switch (currentFormat) {
            .text => try error_print.formatErrorWithContext(info, ctx, stderr, .{}),
            .edn => try formatErrorEdn(info, ctx, stderr),
        }
        appendToLogFile(info, ctx);
    } else if (dispatch.last_thrown_exception) |thrown| {
        // A user `(throw v)` raises `error.ThrownValue`, bypassing the
        // catalog so the threadlocal `Info` is null. Synthesise one from
        // the thrown Value + the throw-time `*error-context*` snapshot
        // (ADR-0055 amendment 2 / D-144) so the event is structured, not
        // the degraded `:kind :unknown :message "ThrownValue"` fallback.
        const info = buildThrownInfo(thrown);
        // Consume the thrown state (mirrors `getLastError` clearing
        // `last_error`) so a later REPL form's bare-error path can't
        // re-render this now-stale throw. `info` already captured the
        // context Value, so clearing the threadlocals after is safe.
        dispatch.last_thrown_exception = null;
        dispatch.last_thrown_context = null;
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

/// Threadlocal scratch for rendering a non-ex-info thrown Value
/// (`(throw 42)`) into the synthetic `Info.message`. The slice points
/// here, so it stays valid for the single render-then-exit at the CLI
/// boundary. ex-info throws point `message` at the ExInfo's owned slice
/// instead and never touch this buffer.
threadlocal var thrown_msg_buf: [512]u8 = undefined;

/// Build a synthetic `Info` for a user-thrown Value. `origin = .thrown`
/// so `kindLabel` renders `:exception` and the catalog `Kind` enum stays
/// honest (ADR-0055 amendment 2). ex-info throws carry their message +
/// ex-data; any other thrown Value renders via `printValue` as the
/// message. Context is the throw-time `*error-context*` snapshot.
fn buildThrownInfo(thrown: Value) error_mod.Info {
    var info = error_mod.Info{
        // Unread when origin == .thrown; the inert placeholder keeps the
        // non-optional field honest (exits 1 via the null-peek path, not
        // this kind).
        .kind = .value_error,
        .origin = .thrown,
        .phase = .eval,
        .message = "",
        .context = dispatch.last_thrown_context,
    };
    if (thrown.tag() == .ex_info) {
        info.message = ex_info.message(thrown);
        info.data = ex_info.data(thrown);
        // ADR-0120 Stage A: a synthesized/marshalled exception carries its
        // source location, so a thrown internal error (in-thread or across a
        // worker-thread boundary) renders WHERE it came from, not "unknown".
        info.location = ex_info.originLoc(thrown);
        // ADR-0120 §1 / D-336: and its call-stack trace, so the `Trace:` survives
        // a worker-thread boundary (future/agent) and an in-thread `(throw …)`.
        info.trace = ex_info.originTrace(thrown);
        return info;
    }
    var w: Writer = .fixed(&thrown_msg_buf);
    print_value(&w, thrown) catch {};
    info.message = w.buffered();
    return info;
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
    // ADR-0118 Decision E.1: mirror the text renderer's file fallback — when
    // the raise site left `info.location.file` as the "unknown" default (the
    // analyzer/eval set line:col but not file), fall back to the source label
    // so the EDN `:file` matches the text `<-e>` / `<stdin>` / filename instead
    // of leaking `"unknown"`.
    const file_label = if (info.location.file.len > 0 and !std.mem.eql(u8, info.location.file, "unknown"))
        info.location.file
    else
        ctx.file;
    try w.print(
        "{{:cljw/error true :kind :{s} :phase :{s} :file \"{s}\" :line {d} :column {d} :message \"",
        .{
            info.kindLabel(),
            @tagName(info.phase),
            file_label,
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
    try w.writeByte('"');
    // ex-data of a thrown ex-info (ADR-0055 am2) — rendered via the
    // canonical Value printer, same as the context entries below.
    if (info.data) |d| {
        try w.writeAll(" :data ");
        try print_value(w, d);
    }
    // Trace: in lockstep with the text renderer (ADR-0119 Stage 2 / ADR-0055):
    // `:trace [{:ns "..":fn "..":file "..":line N} …]`, innermost-first (the
    // push-order snapshot walked reversed). Same `file_label` fallback as :file.
    if (info.trace) |frames| {
        if (frames.len > 0) {
            try w.writeAll(" :trace [");
            var i: usize = frames.len;
            while (i > 0) {
                i -= 1;
                const fr = frames[i];
                if (i != frames.len - 1) try w.writeByte(' ');
                try w.print("{{:fn \"{s}\"", .{fr.fn_name orelse "fn"});
                if (fr.ns) |ns| try w.print(" :ns \"{s}\"", .{ns});
                const ffile = if (fr.file) |ff|
                    (if (ff.len > 0 and !std.mem.eql(u8, ff, "unknown")) ff else file_label)
                else
                    file_label;
                try w.print(" :file \"{s}\" :line {d}}}", .{ ffile, fr.line });
            }
            try w.writeByte(']');
        }
    }
    // Merge the snapshotted `cljw.error/*error-context*` entries as
    // top-level event fields (ADR-0055 D3). array_map only — context
    // maps are small (the >8-entry hash_map path mirrors printMap's
    // limitation; a large context is rare and never silently truncated
    // because count ≤ 8 stays array_map).
    if (info.context) |ctx_map| {
        if (ctx_map.tag() == .array_map) {
            const am = ctx_map.decodePtr(*const map_collection.ArrayMap);
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                try w.writeByte(' ');
                try print_value(w, am.entries[2 * i]);
                try w.writeByte(' ');
                try print_value(w, am.entries[2 * i + 1]);
            }
        }
    }
    try w.writeAll("}\n");
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
