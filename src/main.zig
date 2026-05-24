//! `cljw` entry point.
//!
//! Phase-3.1 surface:
//!   - With no arguments, prints `ClojureWasm` (smoke output).
//!   - `-e <expr>` / `--eval <expr>`: read+analyse+eval+print of a CLI string.
//!   - `<file.clj>` (positional): same loop over a file's contents.
//!   - `-` (positional): same loop over stdin (heredoc-friendly).
//!
//! Errors print to stderr with a non-zero exit; the loop never panics
//! on malformed input. When `runtime/error.zig` has populated a
//! threadlocal `Info`, the catch sites render via
//! `error_print.formatErrorWithContext` (file:line:col + caret +
//! message); otherwise they fall back to `@errorName(err)`.
//!
//! ### Exit codes (ADR-0019)
//!
//!   0   success
//!   1   user-facing catalog error (syntax / type / arity / etc.)
//!   70  internal_error (cw runtime bug; user should file an issue)
//!   130 SIGINT (handled by the OS signal, not this catch chain)
//!
//! The mapping lives in `kindToExitCode`; per-Kind dispatch is
//! intentional so future Kinds (`overflow_error`, `permission_error`,
//! ...) can pick their exit code without touching call sites.

const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("eval/reader.zig").Reader;
const analyzeForm = @import("eval/analyzer.zig").analyze;
const macro_dispatch = @import("eval/macro_dispatch.zig");
const driver = @import("eval/driver.zig");
const Runtime = @import("runtime/runtime.zig").Runtime;
const Env = @import("runtime/env.zig").Env;
const Value = @import("runtime/value/value.zig").Value;
const primitive = @import("lang/primitive.zig");
const macro_transforms = @import("lang/macro_transforms.zig");
const bootstrap = @import("lang/bootstrap.zig");
const error_mod = @import("runtime/error/info.zig");
const error_print = @import("runtime/error/print.zig");
const print = @import("runtime/print.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]

    var source_text: ?[]const u8 = null;
    var source_label: []const u8 = "<-e>";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\Usage: cljw [options] [<file.clj> | -]
                \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
                \\  <file.clj>         Read+evaluate the named source file.
                \\  -                  Read+evaluate from stdin (heredoc-friendly).
                \\  -h, --help         Show this help.
                \\
            , .{});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            const expr = args.next() orelse {
                try stderr.print("Error: -e / --eval requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            };
            source_text = expr;
            source_label = "<-e>";
        } else if (std.mem.eql(u8, arg, "-")) {
            const stdin_file = std.Io.File.stdin();
            var stdin_buf: [4096]u8 = undefined;
            var stdin_reader = stdin_file.readerStreaming(io, &stdin_buf);
            source_text = stdin_reader.interface.allocRemaining(arena, .unlimited) catch |err| {
                try stderr.print("Error reading stdin: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            source_label = "<stdin>";
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try stderr.print("Unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        } else {
            const file = std.Io.Dir.cwd().openFile(io, arg, .{}) catch |err| {
                try stderr.print("Error opening {s}: {s}\n", .{ arg, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            defer file.close(io);
            var file_buf: [4096]u8 = undefined;
            var file_reader = file.reader(io, &file_buf);
            source_text = file_reader.interface.allocRemaining(arena, .unlimited) catch |err| {
                try stderr.print("Error reading {s}: {s}\n", .{ arg, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            source_label = arg;
        }
    }

    if (source_text == null) {
        try stdout.writeAll("ClojureWasm\n");
        try stdout.flush();
        return;
    }

    const ctx = error_print.SourceContext{ .file = source_label, .text = source_text.? };

    // --- Runtime + Env + backend setup ---
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();

    var env = try Env.init(&rt);
    defer env.deinit();

    driver.installVTable(&rt);
    try primitive.registerAll(&env);

    // Bootstrap macros (Phase 3.7): intern `let` / `when` / `cond` /
    // `->` / `->>` / `and` / `or` / `if-let` / `when-let` as macro
    // Vars and populate the analyzer's MacroTable. Lives long enough
    // for the entire eval loop; no per-form re-construction.
    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);

    // Stage-1 prologue (Phase 3.13): read+analyse+eval the embedded
    // `clj/clojure/core.clj`. Errors here use the synthetic
    // `<bootstrap>` source label and are routed through the same
    // catch path as user input — a broken prologue surfaces as a
    // diagnostic, not a panic.
    const bootstrap_ctx = error_print.SourceContext{ .file = bootstrap.SOURCE_LABEL, .text = bootstrap.CORE_SOURCE };
    bootstrap.loadCore(arena, &rt, &env, &macro_table) catch |err| {
        renderAndExit(stderr, bootstrap_ctx, err);
    };

    // --- Read - Analyse - Eval - Print loop ---
    var reader = Reader.init(arena, source_text.?);
    while (true) {
        const form_opt = reader.read() catch |err| {
            renderAndExit(stderr, ctx, err);
        };
        const form = form_opt orelse break;

        const node = analyzeForm(arena, &rt, &env, null, form, &macro_table) catch |err| {
            renderAndExit(stderr, ctx, err);
        };

        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        const result = driver.evalForm(&rt, &env, &locals, arena, node) catch |err| {
            renderAndExit(stderr, ctx, err);
        };

        try print.printValue(stdout, result);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

/// Render a caught error to stderr. Prefers the structured threadlocal
/// `Info` (when populated by `setErrorFmt`); falls back to bare
/// `@errorName(err)` so an unwired call site still produces *some*
/// output instead of swallowing the failure.
fn renderError(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) Writer.Error!void {
    if (error_mod.getLastError()) |info| {
        try error_print.formatErrorWithContext(info, ctx, stderr, .{});
    } else {
        try stderr.print("{s}: error: {s}\n", .{ ctx.file, @errorName(err) });
    }
    try stderr.flush();
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
fn renderAndExit(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) noreturn {
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

test "smoke: main module loads" {
    try std.testing.expect(true);
}

test "kindToExitCode maps internal_error → 70 and others → 1 (ADR-0019)" {
    try std.testing.expectEqual(@as(u8, 70), kindToExitCode(.internal_error));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.type_error));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.syntax_error));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.arity_error));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.name_error));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.not_implemented));
    try std.testing.expectEqual(@as(u8, 1), kindToExitCode(.out_of_memory));
}

test "build_options exposes phase_at_least_N comptime bools (ADR-0023)" {
    const build_options = @import("build_options");
    try std.testing.expect(@TypeOf(build_options.phase_at_least_5) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_7) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_11) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_14) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_15) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_17) == bool);
    try std.testing.expect(build_options.phase_at_least_5 == false);
    try std.testing.expect(build_options.phase_at_least_7 == false);
    try std.testing.expect(build_options.phase_at_least_11 == false);
    try std.testing.expect(build_options.phase_at_least_14 == false);
    try std.testing.expect(build_options.phase_at_least_15 == false);
    try std.testing.expect(build_options.phase_at_least_17 == false);
}

// Pull in tests from the source tree. As more files appear under
// src/, add them here so the unified `zig build test` discovers them.
test {
    _ = @import("runtime/value/value.zig");
    _ = @import("runtime/error/info.zig");
    _ = @import("runtime/error/catalog.zig");
    _ = @import("runtime/error/print.zig");
    _ = @import("runtime/gc/arena.zig");
    _ = @import("runtime/gc/tag_ops.zig");
    _ = @import("runtime/gc/gc_heap.zig");
    _ = @import("runtime/gc/mark_sweep.zig");
    _ = @import("runtime/gc/free_pool.zig");
    _ = @import("runtime/gc/root_set.zig");
    _ = @import("runtime/value/heap_tag.zig");
    _ = @import("runtime/value/heap_header.zig");
    _ = @import("runtime/value/nan_box.zig");
    _ = @import("runtime/collection/ex_info.zig");
    _ = @import("runtime/collection/list.zig");
    _ = @import("runtime/collection/string.zig");
    _ = @import("runtime/collection/vector.zig");
    _ = @import("runtime/collection/map.zig");
    _ = @import("runtime/collection/set.zig");
    _ = @import("runtime/collection/chunked_cons.zig");
    _ = @import("runtime/hash.zig");
    _ = @import("runtime/keyword.zig");
    _ = @import("runtime/print.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/dispatch.zig");
    _ = @import("runtime/env.zig");
    _ = @import("runtime/io/interface.zig");
    _ = @import("runtime/type_descriptor.zig");
    _ = @import("runtime/protocol.zig");
    _ = @import("runtime/dispatch/method_table.zig");
    _ = @import("runtime/host/_host_api.zig");
    _ = @import("runtime/numeric/big_int.zig");
    _ = @import("runtime/lazy_seq.zig");
    _ = @import("eval/form.zig");
    _ = @import("eval/tokenizer.zig");
    _ = @import("eval/reader.zig");
    _ = @import("eval/node.zig");
    _ = @import("eval/analyzer.zig");
    _ = @import("eval/macro_dispatch.zig");
    _ = @import("eval/backend/tree_walk.zig");
    _ = @import("eval/backend/vm.zig");
    _ = @import("eval/driver.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("lang/diff_test.zig");
    _ = @import("eval/backend/vm/opcode.zig");
    _ = @import("eval/backend/vm/compiler.zig");
    _ = @import("lang/primitive/math.zig");
    _ = @import("lang/primitive/core.zig");
    _ = @import("lang/primitive/error.zig");
    _ = @import("lang/primitive.zig");
    _ = @import("lang/macro_transforms.zig");
    _ = @import("lang/bootstrap.zig");
}
