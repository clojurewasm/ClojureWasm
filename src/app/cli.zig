// SPDX-License-Identifier: EPL-2.0
//! CLI argv-dispatcher for `cljw`. Parses flags + positional args
//! into a `source_text` + `source_label` pair, then hands off to
//! `app/runner.zig::runSource`. Surface:
//!   - With no arguments, prints `ClojureWasm` (smoke output).
//!   - `-e <expr>` / `--eval <expr>`: in-line source string.
//!   - `<file.clj>` (positional): file's contents.
//!   - `-` (positional): stdin (heredoc-friendly).
//!   - `--compare`: runs source through BOTH backends
//!     via `eval/evaluator.compare`; prints `OK` + the value when
//!     they agree, `MISMATCH` + both values when they diverge
//!     (exit 1 on mismatch). ADR-0005 full-bench remit.
//!   - `-h` / `--help`: usage message.
//!
//! Argv parsing lives here (extracted from `src/main.zig`, D-031) so
//! the `repl` / `nrepl` / `build` subcommands dispatched below can
//! own their own argument handling without piling more mode-dispatch
//! onto `main.zig`.

const std = @import("std");

const runner = @import("runner.zig");
const repl = @import("repl.zig");
const nrepl = @import("nrepl.zig");
const builder = @import("builder.zig");
const render_error_mod = @import("render_error.zig");
const error_render = @import("error_render.zig");
const gc_torture = @import("../runtime/gc/gc_torture.zig");
const file_io = @import("../runtime/file_io.zig");
const deps_parse = @import("deps/parse.zig");
const deps_resolve = @import("deps/resolve.zig");
const error_print = @import("../runtime/error/print.zig");

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

    // D-066: pick up CLJW_ERROR_FORMAT + CLJW_ERROR_LOG
    // once at startup. Process-wide (per error_render.currentFormat
    // / .logFilePath / .logIo) so every catch site renders + appends
    // consistently without a parameter ripple.
    if (init.environ_map.get("CLJW_ERROR_FORMAT")) |fmt|
        error_render.currentFormat = error_render.parseFormat(fmt);
    if (init.environ_map.get("CLJW_ERROR_LOG")) |path| {
        error_render.logFilePath = path;
        error_render.logIo = io;
    }
    // D-250: GC torture validation mode. `CLJW_GC_TORTURE=N` forces a collect
    // every N VM back-edge polls (N>=1); a bare/invalid value defaults to 1.
    // Inert when unset. Test/validation only — not production auto-collect.
    if (init.environ_map.get("CLJW_GC_TORTURE")) |raw|
        gc_torture.configure(std.fmt.parseInt(u32, raw, 10) catch 1);

    // Self-contained artifact check (ADR-0034 / D-100(b)): if this binary
    // carries an embedded bytecode payload trailer, run it and exit —
    // argv is ignored for a built artifact at v0.1.0. A plain `cljw` has
    // no trailer, so this is a no-op and normal dispatch proceeds.
    if (try builder.tryRunEmbedded(io, gpa, arena)) return;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]

    // `cljw repl` subcommand (ADR-0048) — peek the first positional
    // and route to the REPL when it matches. The REPL takes no further
    // argv; trailing args are not allowed today (a future `--init` /
    // `--port` would relax this).
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "repl")) {
            return repl.run(io, gpa, arena, stdout, stderr);
        }
        if (std.mem.eql(u8, first, "render-error")) {
            // D-100(c): decode CLJW_ERROR_LOG EDN events.
            try render_error_mod.run(io, arena, stdout, stderr, &args);
            return;
        }
        if (std.mem.eql(u8, first, "nrepl")) {
            // nREPL server (ADR-0048). Optional `--port N`
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
        if (std.mem.eql(u8, first, "build")) {
            // D-100(b): `cljw build <in.clj> -o <out>` — compile
            // the source into a self-contained binary (ADR-0034 am1/am2).
            const in_path = args.next() orelse {
                try stderr.writeAll("build: missing <in.clj>\n");
                try stderr.flush();
                std.process.exit(1);
            };
            const flag = args.next() orelse {
                try stderr.writeAll("build: missing -o <out>\n");
                try stderr.flush();
                std.process.exit(1);
            };
            if (!std.mem.eql(u8, flag, "-o")) {
                try stderr.print("build: expected -o, got '{s}'\n", .{flag});
                try stderr.flush();
                std.process.exit(1);
            }
            const out_path = args.next() orelse {
                try stderr.writeAll("build: -o requires a path\n");
                try stderr.flush();
                std.process.exit(1);
            };
            builder.buildFile(io, gpa, arena, in_path, out_path) catch |err| {
                try stderr.print("build failed: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            return;
        }
        // Not a recognised subcommand — fall through to legacy flag
        // parsing by re-routing `first` through the existing arm.
        // deps.edn `:git/url` cache base: $CLJW_HOME, else ~/.cljw, else null
        // (a HOME-less env; git-fetch raises a clear error if a git dep needs it).
        const git_cache_base: ?[]const u8 = init.environ_map.get("CLJW_HOME") orelse
            if (init.environ_map.get("HOME")) |h| try std.fmt.allocPrint(arena, "{s}/.cljw", .{h}) else null;
        try dispatchArgsRest(io, gpa, arena, stdout, stderr, first, &args, init.environ_map.get("CLJW_PATH"), git_cache_base);
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
    cljw_path_env: ?[]const u8,
    git_cache_base: ?[]const u8,
) !void {
    var source_text: ?[]const u8 = null;
    var source_label: []const u8 = "<-e>";
    var compare_mode: bool = false;
    var classpath_arg: ?[]const u8 = null;
    var alias_names: std.ArrayList([]const u8) = .empty;

    var current_arg: ?[]const u8 = first_arg;
    while (current_arg) |arg| : (current_arg = args.next()) {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\Usage: cljw [options] [<file.clj> | -]
                \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
                \\  <file.clj>         Read+evaluate the named source file.
                \\  -                  Read+evaluate from stdin (heredoc-friendly).
                \\  -cp, --classpath <dirs>  Colon-separated dirs `require` searches
                \\                     for `.clj`/`.cljc` libs (else $CLJW_PATH, else ".").
                \\  -A:a1:a2           Select deps.edn aliases (their :extra-paths /
                \\                     :extra-deps join the classpath).
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
        } else if (std.mem.eql(u8, arg, "-cp") or std.mem.eql(u8, arg, "--classpath")) {
            classpath_arg = args.next() orelse {
                try stderr.print("Error: -cp / --classpath requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-A")) {
            // `-A:dev:test` selects deps.edn aliases (`:dev`, `:test`). The
            // names ride one token after `-A`, colon-separated (clojure CLI).
            var it = std.mem.splitScalar(u8, arg[2..], ':');
            while (it.next()) |name| {
                if (name.len > 0) try alias_names.append(arena, name);
            }
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

    // ADR-0084 classpath: `-cp` wins, else `CLJW_PATH`, else cwd. Colon-split
    // into the filesystem-require search roots (`src:test` is the common shape).
    const cp_spec = classpath_arg orelse cljw_path_env orelse ".";
    const base_paths = try splitClasspath(arena, cp_spec);
    // Stage 1.2: a `./deps.edn` in cwd contributes its `:paths` + `:local/root`
    // deps to the FRONT of the classpath (project sources win over the cwd
    // default). Absent file → base unchanged; `:mvn/version` → parse raises.
    const load_paths = try prependDepsEdn(io, arena, stderr, base_paths, alias_names.items, git_cache_base);

    if (compare_mode) {
        try runner.runSourceCompare(io, gpa, arena, stdout, stderr, source_text.?, source_label);
    } else {
        try runner.runSource(io, gpa, arena, stdout, stderr, source_text.?, source_label, load_paths);
    }
}

/// Merge `./deps.edn` (Stage 1.2) into the classpath: its resolved `:paths` +
/// `:local/root` deps go to the FRONT of `base`. No deps.edn (or an empty
/// resolution) → `base` unchanged. A `:mvn/version` dep propagates the parse
/// error (source-only policy). Reuses the `deps/` parse + resolve modules.
fn prependDepsEdn(io: std.Io, arena: std.mem.Allocator, stderr: *std.Io.Writer, base: []const []const u8, alias_names: []const []const u8, git_cache_base: ?[]const u8) ![]const []const u8 {
    const src = file_io.readAll(io, arena, "deps.edn") catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.BadPathName => return base,
        else => return e,
    };
    // A deps.edn error (rejected :mvn/version, a failed git fetch) is a
    // user-facing config error: render it against deps.edn + exit, not a trace.
    const dep_paths = resolveFromSource(io, arena, src, alias_names, git_cache_base) catch |e| {
        const ctx = error_print.SourceContext{ .file = "deps.edn", .text = src };
        error_render.renderAndExit(stderr, ctx, e);
    };
    if (dep_paths.len == 0) return base;
    var merged: std.ArrayList([]const u8) = .empty;
    try merged.appendSlice(arena, dep_paths);
    try merged.appendSlice(arena, base);
    return merged.toOwnedSlice(arena);
}

/// Parse + resolve a deps.edn source into its classpath. Split out so the
/// caller can render any error against the deps.edn source context.
fn resolveFromSource(io: std.Io, arena: std.mem.Allocator, src: []const u8, alias_names: []const []const u8, git_cache_base: ?[]const u8) ![]const []const u8 {
    const cfg = try deps_parse.parseDepsEdn(arena, src);
    return deps_resolve.resolveClasspath(io, arena, ".", cfg, alias_names, git_cache_base);
}

/// Split a colon-separated classpath string into its directory roots, allocated
/// in `arena`. Empty segments are dropped; an all-empty spec yields `["."]`.
fn splitClasspath(arena: std.mem.Allocator, spec: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |seg| {
        if (seg.len > 0) try list.append(arena, seg);
    }
    if (list.items.len == 0) try list.append(arena, ".");
    return list.toOwnedSlice(arena);
}
