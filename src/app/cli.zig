// SPDX-License-Identifier: EPL-2.0
//! CLI argv-dispatcher for `cljw`. Parses flags + positional args
//! into a `source_text` + `source_label` pair, then hands off to
//! `app/runner.zig::runSource`. Surface (Phase 3.1+, row 8.4):
//!   - With no arguments, prints `ClojureWasm` (smoke output).
//!   - `-e <expr>` / `--eval <expr>`: in-line source string.
//!   - `<file.clj>` (positional): file's contents.
//!   - `-` (positional): stdin (heredoc-friendly).
//!   - `--compare` (row 8.4): runs source through BOTH backends
//!     via `eval/evaluator.compare`; prints `OK` + the value when
//!     they agree, `MISMATCH` + both values when they diverge
//!     (exit 1 on mismatch). ADR-0005 full-bench remit.
//!   - `-h` / `--help`: usage message.
//!
//! Row 8.1 (D-031) extracted argv parsing from `src/main.zig` so
//! Phase 10 (nREPL) / Phase 12 (build-runner) can add their own
//! subcommands without piling more mode-dispatch onto `main.zig`.

const std = @import("std");

const runner = @import("runner.zig");
const repl = @import("repl.zig");
const nrepl = @import("nrepl.zig");

/// Top-level CLI dispatcher. Called from `src/main.zig::main` with
/// the Juicy-Main `std.process.Init` bundle. Parses argv, decides
/// whether to run source or just print the smoke output, and
/// delegates to `runner.runSource` for the actual eval loop.
pub fn dispatch(init: std.process.Init) !void {
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

    // Row 14.9 (ADR-0048): `cljw repl` subcommand — peek the first
    // positional and route to the REPL when it matches. The REPL
    // takes no further argv; trailing args are not allowed today
    // (Phase 14.14 polish bundle may add `--init` / `--port`).
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "repl")) {
            return repl.run(io, gpa, arena, stdout, stderr);
        }
        if (std.mem.eql(u8, first, "nrepl")) {
            // Row 14.10 (ADR-0048 nREPL chart). Optional `--port N`
            // (default 7888 per JVM nREPL convention).
            var port: u16 = 7888;
            while (args.next()) |a| {
                if (std.mem.eql(u8, a, "--port")) {
                    const p_str = args.next() orelse {
                        try stderr.print("nrepl: --port requires a value\n", .{});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    port = std.fmt.parseInt(u16, p_str, 10) catch {
                        try stderr.print("nrepl: invalid --port value '{s}'\n", .{p_str});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                } else {
                    try stderr.print("nrepl: unknown argument '{s}'\n", .{a});
                    try stderr.flush();
                    std.process.exit(1);
                }
            }
            return nrepl.run(io, gpa, arena, stdout, stderr, port);
        }
        // Not a recognised subcommand — fall through to legacy flag
        // parsing by re-routing `first` through the existing arm.
        try dispatchArgsRest(io, gpa, arena, stdout, stderr, first, &args);
        return;
    }

    // No argv at all → smoke output.
    try stdout.writeAll("ClojureWasm\n");
    try stdout.flush();
}

/// Legacy flag-parse loop for non-subcommand invocations. Lifted
/// from the inline body to keep `dispatch` thin once subcommand
/// routing arrived (row 14.9).
fn dispatchArgsRest(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    first_arg: []const u8,
    args: anytype,
) !void {
    var source_text: ?[]const u8 = null;
    var source_label: []const u8 = "<-e>";
    var compare_mode: bool = false;

    var current_arg: ?[]const u8 = first_arg;
    while (current_arg) |arg| : (current_arg = args.next()) {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\Usage: cljw [options] [<file.clj> | -]
                \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
                \\  <file.clj>         Read+evaluate the named source file.
                \\  -                  Read+evaluate from stdin (heredoc-friendly).
                \\  --compare          Run source through tree_walk AND vm backends;
                \\                     print OK + value on agreement, MISMATCH + both
                \\                     values (exit 1) on divergence.
                \\  -h, --help         Show this help.
                \\
            , .{});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--compare")) {
            compare_mode = true;
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

    if (compare_mode) {
        try runner.runSourceCompare(io, gpa, arena, stdout, stderr, source_text.?, source_label);
    } else {
        try runner.runSource(io, gpa, arena, stdout, stderr, source_text.?, source_label);
    }
}
