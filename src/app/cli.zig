// SPDX-License-Identifier: EPL-2.0
//! CLI argv-dispatcher for `cljw`. Parses flags + positional args
//! into a `source_text` + `source_label` pair, then hands off to
//! `app/runner.zig::runSource`. Surface:
//!   - With no arguments, starts the REPL (upstream Clojure alignment).
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
const eval_budget = @import("../runtime/concurrency/eval_budget.zig");
const process_env = @import("../runtime/process_env.zig");
const file_io = @import("../runtime/file_io.zig");
const deps_parse = @import("deps/parse.zig");
const deps_resolve = @import("deps/resolve.zig");
const deps_run_mode = @import("deps/run_mode.zig");
const error_print = @import("../runtime/error/print.zig");
const build_options = @import("build_options");
const startup_profile = @import("../runtime/startup_profile.zig");

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
    // D-386: alloc-driven torture — `CLJW_GC_TORTURE_ALLOC=N` forces a collect
    // every N `gc.alloc` calls (mid-op rooting validation). Independent of the
    // safepoint mode above; both armed together by `gc_torture.arm()`.
    if (init.environ_map.get("CLJW_GC_TORTURE_ALLOC")) |raw|
        gc_torture.configureAlloc(std.fmt.parseInt(u32, raw, 10) catch 1);

    // Publish the process env for the runtime surface (`System/getenv`).
    // `init.environ_map` is already a `*Environ.Map` owned by `init`
    // (process-lifetime), so the borrow is safe.
    process_env.publish(init.environ_map);

    // ADR-0125: in-process eval budget arming (isolation dims (a)+(b)).
    // CLJW_EVAL_MAX_STEPS bounds back-edge crossings; CLJW_EVAL_DEADLINE_MS
    // bounds wall-clock ms; CLJW_EVAL_MAX_HEAP_MB bounds live heap. Any subset
    // (unmetered otherwise). An invalid value is ignored (that axis stays unset).
    // Applied to the Runtime at eval start by `runner.runSource`.
    eval_budget.configureFromEnv(
        if (init.environ_map.get("CLJW_EVAL_MAX_STEPS")) |raw| (std.fmt.parseInt(u64, raw, 10) catch null) else null,
        if (init.environ_map.get("CLJW_EVAL_DEADLINE_MS")) |raw| (std.fmt.parseInt(i64, raw, 10) catch null) else null,
        if (init.environ_map.get("CLJW_EVAL_MAX_HEAP_MB")) |raw| (if (std.fmt.parseInt(usize, raw, 10) catch null) |mb| mb * 1024 * 1024 else null) else null,
    );

    // Self-contained artifact check (ADR-0034 / D-100(b) + am4): if this binary
    // carries an embedded bytecode payload trailer, run it and exit. For a
    // `-m` (main-mode) artifact the binary's own runtime argv reaches `-main`
    // (`./out 8080`), so collect argv[1..] and pass it through; a script-mode
    // artifact ignores it. A plain `cljw` has no trailer → no-op, normal
    // dispatch proceeds.
    var embedded_args: std.ArrayList([]const u8) = .empty;
    {
        var ait = init.minimal.args.iterate();
        _ = ait.skip(); // argv[0]
        while (ait.next()) |a| try embedded_args.append(arena, a);
    }
    var cli_prof = startup_profile.Profiler.start(io);
    if (try builder.tryRunEmbedded(io, gpa, arena, stdout, embedded_args.items)) return;
    cli_prof.mark("tryRunEmbedded(self-exe read)");

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]

    // Env-derived run config, hoisted so every dispatch path (REPL entries +
    // dispatchArgsRest) shares one source (F-011). `git_cache_base` =
    // $CLJW_HOME, else ~/.cljw, else null (a HOME-less env; git-fetch raises a
    // clear error if a git dep needs it).
    const cljw_path = init.environ_map.get("CLJW_PATH");
    const fs_jail_root = init.environ_map.get("CLJW_FS_ROOT");
    const git_cache_base: ?[]const u8 = init.environ_map.get("CLJW_HOME") orelse
        if (init.environ_map.get("HOME")) |h| try std.fmt.allocPrint(arena, "{s}/.cljw", .{h}) else null;

    // `cljw repl` subcommand (ADR-0048) — peek the first positional
    // and route to the REPL when it matches. The REPL takes no further
    // argv; trailing args are not allowed today (a future `--init` /
    // `--port` would relax this).
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "repl")) {
            const load_paths = try resolveDefaultClasspath(io, arena, stderr, cljw_path, git_cache_base);
            return repl.run(io, gpa, arena, stdout, stderr, load_paths, fs_jail_root);
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
            // D-100(b) + ADR-0034 am3/am4: `cljw build <in.clj> -o <out>` (script
            // mode) OR `cljw build -m <ns> [args…] -o <out>` (main mode, am4 —
            // embed the require closure + invoke `(<ns>/-main args)` at RUN, not
            // build), both with `[-cp <dirs>] [-A:alias…]`. Classpath resolution
            // mirrors the run path (A3-D4): `-cp` wins, else $CLJW_PATH, else ".".
            var in_path: ?[]const u8 = null;
            var out_path: ?[]const u8 = null;
            var build_cp: ?[]const u8 = null;
            var main_ns: ?[]const u8 = null;
            var build_aliases: std.ArrayList([]const u8) = .empty;
            var main_args: std.ArrayList([]const u8) = .empty;
            while (args.next()) |a| {
                if (std.mem.eql(u8, a, "-o")) {
                    out_path = args.next() orelse {
                        try stderr.writeAll("build: -o requires a path\n");
                        try stderr.flush();
                        std.process.exit(1);
                    };
                } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--main")) {
                    main_ns = args.next() orelse {
                        try stderr.writeAll("build: -m requires a namespace\n");
                        try stderr.flush();
                        std.process.exit(1);
                    };
                } else if (std.mem.eql(u8, a, "-cp") or std.mem.eql(u8, a, "--classpath")) {
                    build_cp = args.next() orelse {
                        try stderr.writeAll("build: -cp requires an argument\n");
                        try stderr.flush();
                        std.process.exit(1);
                    };
                } else if (std.mem.startsWith(u8, a, "-A")) {
                    var it = std.mem.splitScalar(u8, a[2..], ':');
                    while (it.next()) |name| {
                        if (name.len > 0) try build_aliases.append(arena, name);
                    }
                } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
                    try stderr.print("build: unknown option '{s}'\n", .{a});
                    try stderr.flush();
                    std.process.exit(1);
                } else if (main_ns != null) {
                    // A bare token after `-m <ns>` is a `-main` arg (baked default).
                    try main_args.append(arena, a);
                } else if (in_path == null) {
                    in_path = a;
                } else {
                    try stderr.print("build: unexpected argument '{s}'\n", .{a});
                    try stderr.flush();
                    std.process.exit(1);
                }
            }
            const out = out_path orelse {
                try stderr.writeAll("build: missing -o <out>\n");
                try stderr.flush();
                std.process.exit(1);
            };
            if (main_ns != null and in_path != null) {
                try stderr.writeAll("build: -m <ns> and a source file are mutually exclusive\n");
                try stderr.flush();
                std.process.exit(1);
            }
            const cp_spec = build_cp orelse cljw_path orelse ".";
            const base_paths = try splitClasspath(arena, cp_spec);
            const deps = try loadDepsEdn(io, arena, stderr, base_paths, build_aliases.items, git_cache_base);
            // ADR-0034 am4 A4-D4: with no explicit `-m`, a selected alias's
            // deps.edn `:main-opts ["-m" <ns> args…]` drives the build entry
            // (mirrors `cljw -M:alias`). Build accepts only the `-m` form (not
            // `-e`/file). An explicit CLI `-m` wins (this only fills the gap).
            if (main_ns == null) {
                const mo = deps_run_mode.lastAliasMainOpts(deps.cfg, build_aliases.items);
                if (mo.len >= 2 and (std.mem.eql(u8, mo[0], "-m") or std.mem.eql(u8, mo[0], "--main"))) {
                    main_ns = mo[1];
                    try main_args.appendSlice(arena, mo[2..]);
                }
            }
            if (main_ns == null and in_path == null) {
                try stderr.writeAll("build: missing <in.clj>, -m <ns>, or a deps.edn alias :main-opts\n");
                try stderr.flush();
                std.process.exit(1);
            }
            if (main_ns) |mns| {
                builder.buildMainFile(io, gpa, arena, mns, main_args.items, out, deps.load_paths) catch |err| {
                    try stderr.print("build failed: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
            } else {
                builder.buildFile(io, gpa, arena, in_path.?, out, deps.load_paths) catch |err| {
                    try stderr.print("build failed: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
            return;
        }
        // Not a recognised subcommand — fall through to legacy flag
        // parsing by re-routing `first` through the existing arm.
        try dispatchArgsRest(io, gpa, arena, stdout, stderr, first, &args, cljw_path, git_cache_base, fs_jail_root);
        return;
    }

    // No argv at all → start a classpath-aware REPL (upstream Clojure alignment,
    // ADR-0117 D-322): honour $CLJW_PATH (else cwd) + ./deps.edn so a REPL
    // `(require '[my.lib])` resolves user libs off disk. `repl.run` reads stdin
    // via takeDelimiter until EOF, so a piped/closed stdin exits cleanly; an
    // interactive TTY gets the prompt loop.
    const load_paths = try resolveDefaultClasspath(io, arena, stderr, cljw_path, git_cache_base);
    return repl.run(io, gpa, arena, stdout, stderr, load_paths, fs_jail_root);
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
    /// Deploy-mode FS jail root (`CLJW_FS_ROOT`), threaded to `runSource`
    /// (ADR-0123 / SE-6/7). null = unconfined local CLI.
    fs_jail_root: ?[]const u8,
) !void {
    var source_text: ?[]const u8 = null;
    var source_label: []const u8 = "<-e>";
    // upstream Clojure alignment (ADR-0117): only `-e` echoes each top-level result;
    // a bare `<file.clj>` AND stdin (`-`) run as scripts, printing only what
    // the program prints. Set false in the file-open + stdin branches below.
    var print_results: bool = true;
    var compare_mode: bool = false;
    var classpath_arg: ?[]const u8 = null;
    var alias_names: std.ArrayList([]const u8) = .empty;
    // `-M`/`-X` (or a bare top-level `-m`) switch from classpath-only to a
    // run mode (D-309). Once detected, every remaining token is a verbatim
    // run-arg (clojure.main / exec grammar), so the cljw flag loop stops.
    var run_mode: ?deps_run_mode.Mode = null;
    var run_args: std.ArrayList([]const u8) = .empty;

    var current_arg: ?[]const u8 = first_arg;
    while (current_arg) |arg| : (current_arg = args.next()) {
        if (std.mem.eql(u8, arg, "--version")) {
            // Bake the optimize mode into the banner (@import("builtin").mode is
            // comptime-known) so build mode is readable at a glance instead of
            // guessed from binary size — and so the gate can assert ReleaseSafe
            // semantically (D-385 silent Debug-binary perf cliff).
            // The NON-default backend is named so scripts (check_vm_parity's
            // backend-aware e2e cases) can detect a tree_walk binary; the vm
            // default keeps the exact historical banner.
            try stdout.print("ClojureWasm v{s} ({s}{s}{s})\n", .{ build_options.version, @tagName(@import("builtin").mode), if (build_options.wasm) ", wasm" else "", if (build_options.backend == .tree_walk) ", tree_walk" else "" });
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\ClojureWasm v{s}
                \\Usage: cljw [options] [<file.clj> | -]
                \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
                \\  <file.clj>         Run the named source file as a script (no result echo).
                \\  -                  Run stdin as a script (no result echo; heredoc-friendly).
                \\  -cp, --classpath <dirs>  Colon-separated dirs `require` searches
                \\                     for `.clj`/`.cljc` libs (else $CLJW_PATH, else ".").
                \\  -A:a1:a2           Select deps.edn aliases (their :extra-paths /
                \\                     :extra-deps join the classpath).
                \\  -M[:a] [main-opts] Run mode: the alias :main-opts + your args via
                \\                     the clojure.main grammar (-m <ns> | <file> | -e).
                \\  -m <ns> [args]     Shorthand for -M -m: require <ns>, call (<ns>/-main args).
                \\  -X[:a] [ns/fn] [:k v]  Run mode: call :exec-fn with the :exec-args
                \\                     map merged under CLI :key value (EDN-typed).
                \\  --compare          Run source through tree_walk AND vm backends;
                \\                     print OK + value on agreement, MISMATCH + both
                \\                     values (exit 1) on divergence.
                \\  --version          Print the version (ClojureWasm v<version> (<build-mode>[, wasm])) and exit.
                \\  -h, --help         Show this help.
                \\
                \\Subcommands:
                \\  repl               Start a terminal REPL.
                \\  nrepl [--port N]   Start an nREPL server (default port 7888) for
                \\                     CIDER and other editors.
                \\  build <in.clj> -o <out> [-cp <dirs>] [-A:alias…]
                \\                     Compile a script (with the runtime) into one
                \\                     self-contained native binary. Main-mode variant:
                \\                     build -m <ns> [args…] -o <out>.
                \\
            , .{build_options.version});
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
        } else if (std.mem.startsWith(u8, arg, "-M") or std.mem.startsWith(u8, arg, "-X")) {
            // `-M:dev:test foo bar` / `-X:build ns/fn :k v` — the aliases ride
            // the flag token (colon-separated, like `-A`); every following token
            // is a verbatim run-arg, so stop the cljw flag scan and drain.
            run_mode = if (arg[1] == 'M') .main else .exec;
            var it = std.mem.splitScalar(u8, arg[2..], ':');
            while (it.next()) |name| {
                if (name.len > 0) try alias_names.append(arena, name);
            }
            while (args.next()) |a| try run_args.append(arena, a);
            break;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--main")) {
            // Bare top-level `-m my.ns a b` (no `-M`) — cljw runs the main
            // grammar directly (in-process; clj routes this through `-M`). The
            // `-m` token leads the run-args so the same grammar parser handles it.
            run_mode = .main;
            try run_args.append(arena, "-m");
            while (args.next()) |a| try run_args.append(arena, a);
            break;
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
            print_results = false;
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
            print_results = false;
        }
    }

    // ADR-0084 classpath: `-cp` wins, else `CLJW_PATH`, else cwd. Colon-split
    // into the filesystem-require search roots (`src:test` is the common shape).
    const cp_spec = classpath_arg orelse cljw_path_env orelse ".";
    const base_paths = try splitClasspath(arena, cp_spec);
    // Stage 1.2: a `./deps.edn` in cwd contributes its `:paths` + `:local/root`
    // deps to the FRONT of the classpath (project sources win over the cwd
    // default). Absent file → base unchanged; `:mvn/version` → parse raises.
    // The parsed `cfg` also feeds the `-M`/`-X` run modes (alias :main-opts /
    // :exec-fn / :exec-args).
    const deps = try loadDepsEdn(io, arena, stderr, base_paths, alias_names.items, git_cache_base);

    // D-309: a `-M`/`-X` (or bare `-m`) run mode supersedes the `-e`/file path —
    // it runs a `-main` / `:exec-fn` instead of printing eval results.
    if (run_mode) |mode| {
        try deps_run_mode.run(io, gpa, arena, stdout, stderr, mode, deps.cfg, alias_names.items, run_args.items, deps.load_paths, fs_jail_root);
        return;
    }

    if (source_text == null) {
        // Flags (e.g. `-cp DIR`) but no source / run-mode ⇒ start a
        // classpath-aware REPL honouring those flags (D-322; clj parity:
        // `clj -cp src` opens a REPL that can require off `src`). `deps.load_paths`
        // is already resolved above, so this hands the same classpath the
        // `-e`/file path would use straight to the REPL.
        return repl.run(io, gpa, arena, stdout, stderr, deps.load_paths, fs_jail_root);
    }

    if (compare_mode) {
        try runner.runSourceCompare(io, gpa, arena, stdout, stderr, source_text.?, source_label);
    } else {
        try runner.runSource(io, gpa, arena, stdout, stderr, source_text.?, source_label, deps.load_paths, print_results, fs_jail_root);
    }
}

/// The resolved deps.edn: the classpath (`:paths` + `:local/root` / `:git/url`
/// deps prepended to the cwd base) plus the parsed `cfg` (so the `-M`/`-X` run
/// modes can read alias `:main-opts` / `:exec-fn` / `:exec-args`). No deps.edn
/// → `base` unchanged + an empty `cfg`.
const DepsLoad = struct {
    load_paths: []const []const u8,
    cfg: deps_parse.DepsConfig,
};

/// Read + resolve `./deps.edn` (Stage 1.2). Its resolved `:paths` + source deps
/// go to the FRONT of `base`. A deps.edn error (failed git fetch, malformed edn)
/// is a user-facing config error rendered against deps.edn + exit. A `:mvn`
/// dep is skipped + summary-warned (ADR-0101 amendment), not an error.
fn loadDepsEdn(io: std.Io, arena: std.mem.Allocator, stderr: *std.Io.Writer, base: []const []const u8, alias_names: []const []const u8, git_cache_base: ?[]const u8) !DepsLoad {
    const src = file_io.readAll(io, arena, "deps.edn") catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.BadPathName => return .{ .load_paths = base, .cfg = .{} },
        else => return e,
    };
    const ctx = error_print.SourceContext{ .file = "deps.edn", .text = src };
    const cfg = deps_parse.parseDepsEdn(arena, src) catch |e| error_render.renderAndExit(stderr, ctx, e);
    var skipped: std.ArrayList([]const u8) = .empty;
    const dep_paths = deps_resolve.resolveClasspath(io, arena, ".", cfg, alias_names, git_cache_base, &skipped) catch |e|
        error_render.renderAndExit(stderr, ctx, e);
    if (skipped.items.len > 0) {
        stderr.print("note: deps.edn skipped {d} Maven dep(s) (source-only; cljw resolves :git/url + :local/root): ", .{skipped.items.len}) catch {};
        for (skipped.items, 0..) |lib, i| stderr.print("{s}{s}", .{ if (i == 0) "" else ", ", lib }) catch {};
        stderr.print(" — each is satisfied only if its namespace is cw-bundled or laid by another source dep.\n", .{}) catch {};
        stderr.flush() catch {};
    }
    if (dep_paths.len == 0) return .{ .load_paths = base, .cfg = cfg };
    var merged: std.ArrayList([]const u8) = .empty;
    try merged.appendSlice(arena, dep_paths);
    try merged.appendSlice(arena, base);
    return .{ .load_paths = try merged.toOwnedSlice(arena), .cfg = cfg };
}

/// The default classpath for a no-`-cp` REPL entry (the `repl` subcommand + the
/// bare no-args fallback): `$CLJW_PATH` (else cwd ".") split into roots, with a
/// `./deps.edn` `:paths`/source-deps prepended. Mirrors `dispatchArgsRest`'s
/// resolution minus the `-cp` flag + `-A` aliases, so the classpath-resolution
/// behaviour lives in one place rather than duplicated per REPL entry (F-011).
fn resolveDefaultClasspath(io: std.Io, arena: std.mem.Allocator, stderr: *std.Io.Writer, cljw_path_env: ?[]const u8, git_cache_base: ?[]const u8) ![]const []const u8 {
    const base_paths = try splitClasspath(arena, cljw_path_env orelse ".");
    const deps = try loadDepsEdn(io, arena, stderr, base_paths, &.{}, git_cache_base);
    return deps.load_paths;
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
