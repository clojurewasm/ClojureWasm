// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! ClojureWasm CLI entry point.
//!
//! Usage:
//!   cljw -e "expr"           Evaluate expression and print result
//!   cljw file.clj            Evaluate file and print last result
//!   cljw                     Start interactive REPL
//!   cljw build file.clj -o app  Build single binary with embedded code

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("runtime/env.zig").Env;
const registry = @import("builtins/registry.zig");
const bootstrap = @import("runtime/bootstrap.zig");
const bootstrap_cache = @import("bootstrap_cache");
const Value = @import("runtime/value.zig").Value;
const collections = @import("runtime/collections.zig");
const nrepl = @import("repl/nrepl.zig");
const line_editor = @import("repl/line_editor.zig");
const err = @import("runtime/error.zig");
const gc_mod = @import("runtime/gc.zig");
const vm_mod = @import("vm/vm.zig");
const keyword_intern = @import("runtime/keyword_intern.zig");
const ns_ops = @import("builtins/ns_ops.zig");
const http_server = @import("builtins/http_server.zig");
const lifecycle = @import("runtime/lifecycle.zig");
const Reader = @import("reader/reader.zig").Reader;
const FormData = @import("reader/form.zig").FormData;
const Form = @import("reader/form.zig").Form;
const wasm_builtins = @import("wasm/builtins.zig");
const deps_mod = @import("deps.zig");

/// Magic trailer bytes appended to built binaries.
const embed_magic = "CLJW";
/// Trailer size: u64 payload_size (8) + magic (4) = 12 bytes.
const embed_trailer_size = 12;

fn printHelp() void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(
        \\ClojureWasm v0.1.0
        \\
        \\Usage:
        \\  cljw [options] [file.clj]
        \\  cljw -A:alias              REPL with alias
        \\  cljw -M:alias [-m ns]      Main mode with alias
        \\  cljw -X:alias fn [:k v]    Exec mode
        \\  cljw -P                    Resolve deps only
        \\  cljw build <file> [-o out] Build standalone binary
        \\  cljw test [files...]       Run tests
        \\
        \\deps.edn flags:
        \\  -A:alias[:alias...]  Apply alias(es) for REPL
        \\  -M:alias[:alias...]  Apply alias(es) for main execution
        \\  -X:alias[:alias...]  Apply alias(es) for exec function
        \\  -P                   Resolve dependencies only (git clone)
        \\  -m <ns>              Namespace to run -main (with -M)
        \\  -Spath               Print load paths
        \\  -Sdeps <edn>         Extra deps (EDN map)
        \\  -Srepro              Exclude user config
        \\  -Sforce              Ignore cache
        \\  -Sverbose            Debug output
        \\
        \\Options:
        \\  -e <expr>            Evaluate expression and print result
        \\  --tree-walk          Use TreeWalk interpreter instead of VM
        \\  --dump-bytecode      Dump compiled bytecode (VM only)
        \\  --nrepl-server       Start nREPL server
        \\  --port=<N>           nREPL server port (default: auto)
        \\  --version            Print version and exit
        \\  -h, --help           Show this help
        \\
        \\Examples:
        \\  cljw                       Start interactive REPL
        \\  cljw -e '(+ 1 2)'         Evaluate expression
        \\  cljw hello.clj             Run a Clojure file
        \\  cljw -A:dev                REPL with :dev alias
        \\  cljw -M:dev -m my-app.core Run -main with :dev alias
        \\  cljw -X:build my.ns/task   Exec function with :build alias
        \\  cljw -P                    Fetch git dependencies
        \\  cljw build app.clj -o app  Build standalone binary
        \\
    ) catch {};
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two allocators:
    //   allocator (GPA)   — for infrastructure (Env, Namespace, Var, HashMaps)
    //   alloc (GC)        — for Values (Fn, collections, strings, reader/analyzer)
    var gc = gc_mod.MarkSweepGc.init(allocator);
    defer gc.deinit();
    defer vm_mod.dumpOpcodeProfile(); // 37.1: dump opcode profile at exit
    defer gc.dumpAllocProfile(); // 37.1: dump allocation profile at exit
    const alloc = gc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Initialize keyword intern table (uses GPA for permanent keyword strings)
    keyword_intern.init(allocator);
    defer keyword_intern.deinit();

    // Initialize load path infrastructure for require/load
    ns_ops.init(allocator);
    defer ns_ops.deinit();

    // Install signal handlers for graceful shutdown (SIGINT/SIGTERM/SIGPIPE)
    lifecycle.installSignalHandlers();

    // Check for embedded payload (built binary via `cljw build`).
    // If this binary has a CLJW trailer, run the embedded payload and exit.
    // Payload may be raw .clj source or compiled bytecode (detected by CLJC magic).
    if (readEmbeddedSource(allocator)) |payload| {
        defer allocator.free(payload);
        if (isBytecodeModule(payload)) {
            runEmbeddedBytecode(alloc, allocator, &gc, payload);
        } else {
            // Parse --nrepl flag for built binaries.
            // Usage: ./myapp --nrepl [port] [other args...]
            var embed_nrepl_port: ?u16 = null;
            var filtered_buf: [256][:0]const u8 = undefined;
            var filtered_count: usize = 0;
            {
                var ai: usize = 1;
                while (ai < args.len) : (ai += 1) {
                    if (std.mem.eql(u8, args[ai], "--nrepl")) {
                        // Check if next arg is a port number
                        if (ai + 1 < args.len) {
                            if (std.fmt.parseInt(u16, args[ai + 1], 10)) |p| {
                                embed_nrepl_port = p;
                                ai += 1;
                                continue;
                            } else |_| {}
                        }
                        embed_nrepl_port = 0; // auto-assign
                    } else if (filtered_count < filtered_buf.len) {
                        filtered_buf[filtered_count] = args[ai];
                        filtered_count += 1;
                    }
                }
            }
            const filtered_args = filtered_buf[0..filtered_count];

            err.setSourceFile("<embedded>");
            err.setSourceText(payload);
            if (embed_nrepl_port) |port| {
                evalEmbeddedWithNrepl(alloc, allocator, &gc, payload, filtered_args, port);
            } else {
                evalEmbedded(alloc, allocator, &gc, payload, filtered_args);
            }
        }
        return;
    }

    // Handle `build` subcommand: cljw build <file> [-o <output>]
    if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) {
        handleBuildCommand(alloc, allocator, &gc, args[2..]);
        return;
    }

    // Handle `test` subcommand: cljw test [file.clj ...]
    if (args.len >= 2 and std.mem.eql(u8, args[1], "test")) {
        handleTestCommand(alloc, allocator, &gc, args[2..]);
        return;
    }

    // Parse flags
    const CliMode = enum { normal, alias_repl, main_mode, exec_mode, resolve_only, show_path };
    var mode: CliMode = .normal;
    var use_vm = true;
    var dump_bytecode = false;
    var expr: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var nrepl_mode = false;
    var nrepl_port: u16 = 0;
    var alias_str: ?[]const u8 = null; // raw alias string (e.g. ":dev:test")
    var main_ns_flag: ?[]const u8 = null; // -m namespace
    var exec_fn_arg: ?[]const u8 = null; // -X positional fn name
    var sdeps_str: ?[]const u8 = null; // -Sdeps extra deps EDN
    var s_verbose = false;
    var s_force = false;
    var s_repro = false;
    // Collect -X extra keyword args: :k v pairs after fn name
    var exec_extra_args: [32][]const u8 = undefined;
    var exec_extra_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
            _ = stdout.write("ClojureWasm v0.1.0\n") catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--tree-walk")) {
            use_vm = false;
        } else if (std.mem.eql(u8, arg, "--dump-bytecode")) {
            dump_bytecode = true;
        } else if (std.mem.eql(u8, arg, "--nrepl-server")) {
            nrepl_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            nrepl_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: -e requires an expression argument\n") catch {};
                std.process.exit(1);
            }
            expr = args[i];
        } else if (std.mem.eql(u8, arg, "-m")) {
            // -m namespace (for -M mode)
            i += 1;
            if (i >= args.len) {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: -m requires a namespace argument\n") catch {};
                std.process.exit(1);
            }
            main_ns_flag = args[i];
        } else if (std.mem.startsWith(u8, arg, "-A")) {
            mode = .alias_repl;
            alias_str = arg["-A".len..];
        } else if (std.mem.startsWith(u8, arg, "-M")) {
            mode = .main_mode;
            alias_str = arg["-M".len..];
        } else if (std.mem.startsWith(u8, arg, "-X")) {
            mode = .exec_mode;
            alias_str = arg["-X".len..];
            // Remaining positional args: [fn-name] [:key val ...]
            // fn-name: qualified symbol (no : or - prefix)
            // :key val: keyword arg pairs
            i += 1;
            if (i < args.len and !std.mem.startsWith(u8, args[i], "-") and !std.mem.startsWith(u8, args[i], ":")) {
                exec_fn_arg = args[i];
                i += 1;
            }
            // Collect :key val pairs
            while (i < args.len) : (i += 1) {
                if (std.mem.startsWith(u8, args[i], "-") and !std.mem.startsWith(u8, args[i], ":")) break;
                if (exec_extra_count < exec_extra_args.len) {
                    exec_extra_args[exec_extra_count] = args[i];
                    exec_extra_count += 1;
                }
            }
            // Back up one since the outer loop will increment
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, arg, "-P")) {
            mode = .resolve_only;
        } else if (std.mem.eql(u8, arg, "-Spath")) {
            mode = .show_path;
        } else if (std.mem.startsWith(u8, arg, "-Sdeps")) {
            // -Sdeps '{:deps {...}}' or -Sdeps='{...}'
            if (std.mem.indexOf(u8, arg, "=")) |eq_idx| {
                sdeps_str = arg[eq_idx + 1 ..];
            } else {
                i += 1;
                if (i < args.len) sdeps_str = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-Sverbose")) {
            s_verbose = true;
        } else if (std.mem.eql(u8, arg, "-Sforce")) {
            s_force = true;
        } else if (std.mem.eql(u8, arg, "-Srepro")) {
            s_repro = true;
        } else {
            file = arg;
        }
    }

    if (nrepl_mode) {
        if (file) |f| {
            startNreplWithFile(alloc, allocator, &gc, f, nrepl_port);
        } else {
            nrepl.startServer(allocator, nrepl_port) catch |e| {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: nREPL server failed: ") catch {};
                _ = stderr.write(@errorName(e)) catch {};
                _ = stderr.write("\n") catch {};
                std.process.exit(1);
            };
        }
        return;
    }

    // Load deps.edn (preferred) or cljw.edn config if present.
    // Uses arena for config parsing — freed when config is no longer needed.
    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();
    const config_alloc = config_arena.allocator();
    const file_dir = if (file) |f| std.fs.path.dirname(f) else null;
    var config_dir: ?[]const u8 = null;

    // Parse deps.edn into DepsConfig (for alias resolution) or fall back to ProjectConfig
    const deps_config_opt: ?deps_mod.DepsConfig = if (findDepsEdnFile(config_alloc, file_dir)) |cf| blk: {
        config_dir = cf.dir;
        break :blk deps_mod.parseDepsEdn(config_alloc, cf.content);
    } else null;

    // Merge extra -Sdeps if provided
    if (sdeps_str) |extra| {
        const extra_config = deps_mod.parseDepsEdn(config_alloc, extra);
        // Apply extra deps to config (simple path merge for now)
        for (extra_config.paths) |p| ns_ops.addLoadPath(p) catch {};
    }

    // Handle deps.edn modes (-A/-M/-X/-P/-Spath)
    if (mode != .normal) {
        const deps_config = deps_config_opt orelse {
            // deps.edn flags used but no deps.edn found
            if (mode != .resolve_only and mode != .show_path) {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: No deps.edn found. -A/-M/-X flags require deps.edn.\n") catch {};
                std.process.exit(1);
            }
            // -P with no deps.edn is a no-op, -Spath shows "."
            if (mode == .show_path) {
                const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
                _ = stdout.write(".\n") catch {};
            }
            return;
        };

        // Resolve aliases
        const alias_names = if (alias_str) |s|
            deps_mod.parseAliasString(config_alloc, s)
        else
            @as([]const []const u8, &.{});
        const resolved = deps_mod.resolveAliases(config_alloc, deps_config, alias_names);

        // Print warnings
        const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        for (resolved.warnings) |warning| {
            _ = stderr_file.write(warning) catch {};
            _ = stderr_file.write("\n") catch {};
        }

        if (s_verbose) {
            _ = stderr_file.write("Resolved aliases: ") catch {};
            if (alias_str) |s| _ = stderr_file.write(s) catch {};
            _ = stderr_file.write("\n") catch {};
        }

        // Apply resolved paths
        for (resolved.paths) |path| {
            if (config_dir) |dir| {
                var buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
                ns_ops.addLoadPath(full) catch {};
            } else {
                ns_ops.addLoadPath(path) catch {};
            }
        }

        // Apply resolved deps
        for (resolved.deps) |dep| {
            if (dep.local_root) |root| {
                resolveLocalDep(root, config_dir);
            } else if (dep.git_url != null and dep.git_sha != null) {
                resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, s_force);
            } else {
                // Try io.github/io.gitlab URL inference
                if (deps_mod.inferGitUrl(config_alloc, dep.name)) |inferred_url| {
                    if (dep.git_sha) |sha| {
                        resolveGitDep(inferred_url, sha, dep.git_tag, dep.deps_root, s_force);
                    }
                }
            }
        }

        // Apply wasm deps
        for (resolved.wasm_deps) |wd| {
            var wasm_buf: [4096]u8 = undefined;
            const wasm_resolved = if (config_dir) |dir|
                std.fmt.bufPrint(&wasm_buf, "{s}/{s}", .{ dir, wd.path }) catch continue
            else
                wd.path;
            wasm_builtins.registerWasmDep(wd.name, wasm_resolved);
        }

        switch (mode) {
            .resolve_only => {
                // -P: Dependencies resolved above. Done.
                const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
                _ = stdout.write("Dependencies resolved.\n") catch {};
                return;
            },
            .show_path => {
                // -Spath: Print all load paths
                const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
                for (resolved.paths, 0..) |path, pi| {
                    if (pi > 0) _ = stdout.write(":") catch {};
                    if (config_dir) |dir| {
                        var buf: [4096]u8 = undefined;
                        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
                        _ = stdout.write(full) catch {};
                    } else {
                        _ = stdout.write(path) catch {};
                    }
                }
                _ = stdout.write("\n") catch {};
                return;
            },
            .alias_repl => {
                // -A: REPL with aliases applied
                var env = Env.init(allocator);
                defer env.deinit();
                bootstrapFromCache(alloc, &env, &gc);
                if (file) |f| {
                    // -A:dev file.clj — run file with alias
                    const dir = std.fs.path.dirname(f) orelse ".";
                    ns_ops.addLoadPath(dir) catch {};
                    const max_file_size = 10 * 1024 * 1024;
                    const file_bytes = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
                        _ = stderr_file.write("Error: could not read file\n") catch {};
                        std.process.exit(1);
                    };
                    defer allocator.free(file_bytes);
                    err.setSourceFile(f);
                    err.setSourceText(file_bytes);
                    evalAndPrint(alloc, allocator, &gc, file_bytes, use_vm, dump_bytecode);
                } else {
                    runRepl(alloc, &env, &gc);
                }
                return;
            },
            .main_mode => {
                // -M: Main mode — run -main from namespace
                const ns = main_ns_flag orelse resolved.main_ns orelse blk: {
                    // Check :main-opts for "-m" "ns"
                    var mi: usize = 0;
                    while (mi + 1 < resolved.main_opts.len) : (mi += 1) {
                        if (std.mem.eql(u8, resolved.main_opts[mi], "-m")) {
                            break :blk resolved.main_opts[mi + 1];
                        }
                    }
                    // Fallback: run file if provided
                    if (file) |f| {
                        const dir = std.fs.path.dirname(f) orelse ".";
                        ns_ops.addLoadPath(dir) catch {};
                        const max_file_size = 10 * 1024 * 1024;
                        const file_bytes = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
                            _ = stderr_file.write("Error: could not read file\n") catch {};
                            std.process.exit(1);
                        };
                        defer allocator.free(file_bytes);
                        err.setSourceFile(f);
                        err.setSourceText(file_bytes);
                        evalAndPrint(alloc, allocator, &gc, file_bytes, use_vm, dump_bytecode);
                        return;
                    }
                    _ = stderr_file.write("Error: -M requires -m <namespace> or a file argument\n") catch {};
                    std.process.exit(1);
                };
                runMainNs(alloc, allocator, &gc, ns, use_vm);
                return;
            },
            .exec_mode => {
                // -X: Exec mode — invoke a function
                const fn_name = exec_fn_arg orelse resolved.exec_fn orelse {
                    _ = stderr_file.write("Error: -X requires a function name\n") catch {};
                    std.process.exit(1);
                };
                runExecFn(alloc, allocator, &gc, fn_name, exec_extra_args[0..exec_extra_count], resolved.exec_args, use_vm);
                return;
            },
            .normal => unreachable,
        }
    }

    // Standard mode (no deps.edn flags)
    const config = if (deps_config_opt) |dc| blk: {
        // deps.edn found but no -A/-M/-X flags — convert to ProjectConfig
        break :blk projectConfigFromDepsConfig(config_alloc, dc);
    } else if (findConfigFile(config_alloc, file_dir)) |cf| blk: {
        // Fallback to cljw.edn with deprecation warning
        const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr_file.write("WARNING: cljw.edn is deprecated. Use deps.edn instead.\n") catch {};
        config_dir = cf.dir;
        break :blk parseConfig(config_alloc, cf.content);
    } else ProjectConfig{};
    applyConfig(config, config_dir);

    if (s_verbose) {
        const stderr_out: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr_out.write("Verbose: standard mode (no alias flags)\n") catch {};
    }
    if (s_repro) {
        // -Srepro: exclude user config (no-op for now, CW has no user config dir yet)
    }
    // s_force is passed through to resolveGitDep() — bypasses cache

    if (expr) |e| {
        err.setSourceFile(null);
        err.setSourceText(e);
        evalAndPrint(alloc, allocator, &gc, e, use_vm, dump_bytecode);
    } else if (file) |f| {
        // Add entry file's directory and detect src/ for require resolution
        const dir = std.fs.path.dirname(f) orelse ".";
        ns_ops.addLoadPath(dir) catch {};
        ns_ops.detectAndAddSrcPath(dir) catch {};

        const max_file_size = 10 * 1024 * 1024; // 10MB
        const file_bytes = std.fs.cwd().readFileAlloc(allocator, f, max_file_size) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file (max 10MB)\n") catch {};
            std.process.exit(1);
        };
        defer allocator.free(file_bytes);

        err.setSourceFile(f);
        err.setSourceText(file_bytes);
        evalAndPrint(alloc, allocator, &gc, file_bytes, use_vm, dump_bytecode);
    } else if (config.main_ns) |main_ns| {
        // deps.edn :cljw/main or cljw.edn :main — load the main namespace
        runMainNs(alloc, allocator, &gc, main_ns, use_vm);
    } else {
        // No args, no file, no :main — start REPL
        var env = Env.init(allocator);
        defer env.deinit();
        bootstrapFromCache(alloc, &env, &gc);
        runRepl(alloc, &env, &gc);
    }
}

fn runRepl(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);

    // Use line editor if stdin is a TTY, otherwise fall back to simple reader
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        runReplSimple(allocator, env, gc);
        return;
    }

    _ = stdout.write("ClojureWasm v0.1.0\n") catch {};

    var editor = line_editor.LineEditor.init(allocator, env);
    defer editor.deinit();

    while (true) {
        // Update prompt to reflect current namespace
        const ns_name = if (env.current_ns) |ns| ns.name else "user";
        editor.setNsPrompt(ns_name);

        const source = editor.readInput() orelse {
            _ = stdout.write("\n") catch {};
            break;
        };

        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (trimmed.len == 0) continue;

        err.setSourceText(source);
        const result = bootstrap.evalString(allocator, env, source);

        if (result) |val| {
            var buf: [65536]u8 = undefined;
            const output = formatValue(&buf, val);
            if (is_tty) {
                // Colored output for result values
                var color_buf: [65536 + 32]u8 = undefined;
                const colored = colorizeValue(&color_buf, output, val);
                _ = stdout.write(colored) catch {};
            } else {
                _ = stdout.write(output) catch {};
            }
            _ = stdout.write("\n") catch {};
        } else |eval_err| {
            reportError(eval_err);
        }

        // GC safe point
        gc.collectIfNeeded(.{ .env = env });
    }
}

/// Simple REPL for non-TTY stdin (piped input).
fn runReplSimple(allocator: Allocator, env: *Env, gc: *gc_mod.MarkSweepGc) void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

    var line_buf: [65536]u8 = undefined;
    var input_buf: [65536]u8 = undefined;
    var input_len: usize = 0;
    var depth: i32 = 0;

    while (true) {
        const line_end = readLine(stdin, &line_buf) orelse {
            // EOF: evaluate remaining input if any
            if (input_len > 0) {
                const source = input_buf[0..input_len];
                err.setSourceText(source);
                const result = bootstrap.evalString(allocator, env, source);
                if (result) |val| {
                    var buf: [65536]u8 = undefined;
                    const output = formatValue(&buf, val);
                    _ = stdout.write(output) catch {};
                    _ = stdout.write("\n") catch {};
                } else |eval_err| {
                    reportError(eval_err);
                }
            }
            break;
        };

        const trimmed = std.mem.trim(u8, line_buf[0..line_end], " \t\r");
        if (trimmed.len == 0 and depth == 0) continue;

        if (input_len > 0) {
            input_buf[input_len] = '\n';
            input_len += 1;
        }
        if (input_len + trimmed.len > input_buf.len) {
            _ = stdout.write("Error: input too long\n") catch {};
            input_len = 0;
            depth = 0;
            continue;
        }
        @memcpy(input_buf[input_len .. input_len + trimmed.len], trimmed);
        input_len += trimmed.len;

        depth = countDelimiterDepth(input_buf[0..input_len]);
        if (depth > 0) continue;

        const source = input_buf[0..input_len];
        err.setSourceText(source);
        const result = bootstrap.evalString(allocator, env, source);

        if (result) |val| {
            var buf: [65536]u8 = undefined;
            const output = formatValue(&buf, val);
            _ = stdout.write(output) catch {};
            _ = stdout.write("\n") catch {};
        } else |eval_err| {
            reportError(eval_err);
        }

        gc.collectIfNeeded(.{ .env = env });
        input_len = 0;
        depth = 0;
    }
}

/// Read a line from file into buf. Returns line length, or null on EOF with no data.
fn readLine(file: std.fs.File, buf: []u8) ?usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = file.read(&byte) catch return null;
        if (n == 0) {
            // EOF
            if (pos > 0) return pos;
            return null;
        }
        if (byte[0] == '\n') {
            return pos;
        }
        buf[pos] = byte[0];
        pos += 1;
    }
    // Buffer full
    return pos;
}

/// Count nesting depth of delimiters in source.
/// Returns > 0 if more openers than closers, 0 if balanced, < 0 if over-closed.
fn countDelimiterDepth(source: []const u8) i32 {
    var d: i32 = 0;
    var in_string = false;
    var in_comment = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ';' => in_comment = true,
            '"' => in_string = true,
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            else => {},
        }
    }
    return d;
}

fn evalAndPrint(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, use_vm: bool, dump_bytecode: bool) void {
    // Env uses infra_alloc (GPA) for Namespace/Var/HashMap internals.
    // bootstrap and evaluation use gc_alloc (MarkSweepGc) for Values.
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Dump bytecode if requested (VM only, dump to stderr then exit)
    if (dump_bytecode) {
        if (!use_vm) {
            std.debug.print("Error: --dump-bytecode requires VM backend (not --tree-walk)\n", .{});
            std.process.exit(1);
        }
        bootstrap.dumpBytecodeVM(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        };
        return;
    }

    // Evaluate using selected backend
    const result = if (use_vm)
        bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        }
    else
        bootstrap.evalString(gc_alloc, &env, source) catch |e| {
            reportError(e);
            std.process.exit(1);
        };

    // Print result to stdout
    var buf: [65536]u8 = undefined;
    const output = formatValue(&buf, result);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(output) catch {};
    _ = stdout.write("\n") catch {};

    // Run shutdown hooks if shutdown was requested (e.g. SIGINT during run-server)
    if (lifecycle.isShutdownRequested()) {
        lifecycle.runShutdownHooks(gc_alloc, &env);
    }
}

/// Run a main namespace: require ns then invoke -main.
fn runMainNs(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, main_ns: []const u8, use_vm: bool) void {
    _ = use_vm;
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Require the namespace, then call -main
    var buf: [4096]u8 = undefined;
    const run_expr = std.fmt.bufPrint(&buf, "(do (require '{s}) ({s}/-main))", .{ main_ns, main_ns }) catch {
        std.debug.print("Error: namespace name too long\n", .{});
        std.process.exit(1);
    };
    _ = bootstrap.evalString(gc_alloc, &env, run_expr) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Run -X exec mode: require namespace, invoke function with args.
fn runExecFn(
    gc_alloc: Allocator,
    infra_alloc: Allocator,
    gc: *gc_mod.MarkSweepGc,
    fn_name: []const u8,
    cli_args: []const []const u8,
    alias_args: []const deps_mod.ExecArg,
    use_vm: bool,
) void {
    _ = use_vm;
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Parse fn_name: "ns/fn" → require ns, call ns/fn
    const slash_idx = std.mem.indexOf(u8, fn_name, "/");
    if (slash_idx) |idx| {
        const ns_part = fn_name[0..idx];
        // Require the namespace
        var req_buf: [4096]u8 = undefined;
        const require_expr = std.fmt.bufPrint(&req_buf, "(require '{s})", .{ns_part}) catch {
            _ = stderr.write("Error: namespace name too long\n") catch {};
            std.process.exit(1);
        };
        _ = bootstrap.evalString(gc_alloc, &env, require_expr) catch |e| {
            reportError(e);
            std.process.exit(1);
        };
    }

    // Build the invocation expression: (fn-name {:key "val" ...})
    var call_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&call_buf);
    const w = stream.writer();
    w.print("({s}", .{fn_name}) catch {};

    // Build args map from alias exec-args + CLI override args.
    // CLI args override alias args with the same key.
    const has_args = alias_args.len > 0 or cli_args.len > 0;
    if (has_args) {
        w.writeAll(" {") catch {};
        // Collect CLI keys for override checking
        var cli_keys: [16][]const u8 = undefined;
        var cli_key_count: usize = 0;
        {
            var ci: usize = 0;
            while (ci < cli_args.len) : (ci += 1) {
                const carg = cli_args[ci];
                if (carg.len > 1 and carg[0] == ':' and ci + 1 < cli_args.len) {
                    if (cli_key_count < cli_keys.len) {
                        cli_keys[cli_key_count] = carg[1..]; // strip leading ':'
                        cli_key_count += 1;
                    }
                    ci += 1; // skip value
                }
            }
        }
        // Alias args (skip if overridden by CLI)
        for (alias_args) |ea| {
            var overridden = false;
            for (cli_keys[0..cli_key_count]) |ck| {
                if (std.mem.eql(u8, ea.key, ck)) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                w.print(" :{s} \"{s}\"", .{ ea.key, ea.value }) catch {};
            }
        }
        // CLI args: :key val pairs
        var ci: usize = 0;
        while (ci < cli_args.len) : (ci += 1) {
            const carg = cli_args[ci];
            if (carg.len > 0 and carg[0] == ':' and ci + 1 < cli_args.len) {
                w.print(" {s} \"{s}\"", .{ carg, cli_args[ci + 1] }) catch {};
                ci += 1;
            }
        }
        w.writeAll("}") catch {};
    }
    w.writeAll(")") catch {};

    const call_expr = stream.getWritten();
    _ = bootstrap.evalString(gc_alloc, &env, call_expr) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Initialize env from pre-compiled bootstrap cache (D81).
/// Registers builtins (Zig function pointers), then restores Clojure-defined
/// Vars from the serialized env snapshot embedded at build time.
/// Protocol/ProtocolFn values are now serialized directly in the cache,
/// so no re-evaluation of protocols.clj/reducers.clj is needed.
fn bootstrapFromCache(gc_alloc: Allocator, env: *Env, gc: ?*gc_mod.MarkSweepGc) void {
    registry.registerBuiltins(env) catch {
        std.debug.print("Error: failed to register builtins\n", .{});
        std.process.exit(1);
    };
    bootstrap.restoreFromBootstrapCache(gc_alloc, env, bootstrap_cache.data) catch {
        std.debug.print("Error: failed to restore bootstrap cache\n", .{});
        std.process.exit(1);
    };
    markBootstrapLibs();

    // Enable GC after cache restore for subsequent evaluation.
    if (gc) |g| {
        g.threshold = @max(g.bytes_allocated * 2, g.threshold);
        env.gc = @ptrCast(g);
    }
}

/// Mark built-in namespaces as loaded so require skips them.
fn markBootstrapLibs() void {
    const libs = [_][]const u8{
        "clojure.core",
        "clojure.walk",
        "clojure.template",
        "clojure.test",
        "clojure.set",
        "clojure.data",
        "clojure.string",
        "clojure.edn",
        "clojure.repl",
        "clojure.java.shell",
        "clojure.pprint",
        "clojure.stacktrace",
        "clojure.zip",
        "clojure.core.protocols",
        "clojure.core.reducers",
    };
    for (libs) |name| {
        ns_ops.markLibLoaded(name) catch {};
    }
}

/// Handle `cljw test [file.clj ...]` subcommand.
/// If specific files are given, loads and runs tests from those files.
/// Otherwise, searches :test-paths (or "test/") for .clj files and runs all tests.
fn handleTestCommand(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, test_args: []const [:0]const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Bootstrap
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Load cljw.edn config
    var config_arena = std.heap.ArenaAllocator.init(infra_alloc);
    defer config_arena.deinit();
    const config_alloc = config_arena.allocator();
    var test_config_dir: ?[]const u8 = null;
    const config = if (findConfigFile(config_alloc, null)) |cf| blk: {
        test_config_dir = cf.dir;
        break :blk parseConfig(config_alloc, cf.content);
    } else ProjectConfig{};
    applyConfig(config, test_config_dir);

    // Arena for test file paths and source buffers (survives until function exit).
    var file_arena = std.heap.ArenaAllocator.init(infra_alloc);
    defer file_arena.deinit();
    const file_alloc = file_arena.allocator();

    // Collect test files
    var test_files: std.ArrayList([]const u8) = .empty;
    defer test_files.deinit(infra_alloc);

    if (test_args.len > 0) {
        // Specific files provided
        for (test_args) |arg| {
            test_files.append(infra_alloc, arg) catch {};
        }
    } else {
        // Search test directories for .clj files
        const search_paths = if (config.test_paths.len > 0) config.test_paths else &[_][]const u8{"test"};
        for (search_paths) |test_dir| {
            collectTestFiles(file_alloc, infra_alloc, test_dir, &test_files);
        }
    }

    if (test_files.items.len == 0) {
        _ = stderr.write("No test files found.\n") catch {};
        std.process.exit(1);
    }

    // Add test directories to load path
    for (test_files.items) |tf| {
        const dir = std.fs.path.dirname(tf) orelse ".";
        ns_ops.addLoadPath(dir) catch {};
    }
    const max_file_size = 10 * 1024 * 1024;
    var loaded: usize = 0;
    var total_failures = false;
    for (test_files.items) |tf| {
        const file_bytes = std.fs.cwd().readFileAlloc(file_alloc, tf, max_file_size) catch {
            _ = stderr.write("Error: could not read ") catch {};
            _ = stderr.write(tf) catch {};
            _ = stderr.write("\n") catch {};
            continue;
        };

        err.setSourceFile(tf);
        err.setSourceText(file_bytes);
        const result = bootstrap.evalStringVM(gc_alloc, &env, file_bytes) catch |e| {
            reportError(e);
            continue;
        };
        loaded += 1;

        // Each test file ends with (run-tests) which returns {:test N :pass N :fail N :error N}.
        // Check for failures in per-file results.
        if (result.tag() == .map) {
            if (checkTestFailures(result)) total_failures = true;
        }
    }

    if (loaded == 0) {
        _ = stderr.write("Error: no test files loaded successfully.\n") catch {};
        std.process.exit(1);
    }

    // Print newline after test output
    _ = stdout.write("\n") catch {};

    if (total_failures) {
        std.process.exit(1);
    }
}

/// Check if a test result map has failures (:fail > 0 or :error > 0).
fn checkTestFailures(result: Value) bool {
    if (result.tag() != .map) return false;
    const m = result.asMap();
    var ei: usize = 0;
    while (ei + 1 < m.entries.len) : (ei += 2) {
        const k = m.entries[ei];
        const v = m.entries[ei + 1];
        if (k.tag() == .keyword and v.tag() == .integer) {
            const kw = k.asKeyword();
            if (std.mem.eql(u8, kw.name, "fail") or std.mem.eql(u8, kw.name, "error")) {
                if (v.asInteger() > 0) return true;
            }
        }
    }
    return false;
}

/// Recursively collect .clj files from a directory.
/// str_alloc: arena for path strings (long-lived), list_alloc: for ArrayList backing.
fn collectTestFiles(str_alloc: Allocator, list_alloc: Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".clj")) {
            const full = std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            out.append(list_alloc, full) catch {};
        } else if (entry.kind == .directory) {
            const subdir = std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            collectTestFiles(str_alloc, list_alloc, subdir, out);
        }
    }
}

// === deps.edn support ===

/// Search for deps.edn starting from dir, walking up to root.
fn findDepsEdnFile(allocator: Allocator, start_dir: ?[]const u8) ?ConfigFile {
    // Try CWD first
    if (readFileFromDir(allocator, ".", "deps.edn")) |content| return .{ .content = content, .dir = null };

    // Walk up from start_dir
    var current = start_dir orelse return null;
    for (0..10) |_| {
        if (readFileFromDir(allocator, current, "deps.edn")) |content| return .{ .content = content, .dir = current };
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

fn readFileFromDir(allocator: Allocator, dir: []const u8, filename: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, filename }) catch return null;
    return std.fs.cwd().readFileAlloc(allocator, path, 10_000) catch null;
}

/// Convert deps.edn (parsed by deps_mod) to ProjectConfig for existing applyConfig.
/// Convert a DepsConfig (from deps.zig parser) to ProjectConfig for applyConfig.
fn projectConfigFromDepsConfig(allocator: Allocator, deps_config: deps_mod.DepsConfig) ProjectConfig {
    // Print warnings to stderr
    const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    for (deps_config.warnings) |warning| {
        _ = stderr_file.write(warning) catch {};
        _ = stderr_file.write("\n") catch {};
    }

    // Convert deps
    const dep_count = deps_config.deps.len;
    const deps = if (dep_count > 0) blk: {
        const d = allocator.alloc(Dep, dep_count) catch break :blk @as([]const Dep, &.{});
        for (deps_config.deps, 0..) |src_dep, idx| {
            d[idx] = .{
                .local_root = src_dep.local_root,
                .git_url = src_dep.git_url orelse inferGitUrlFromName(allocator, src_dep.name),
                .git_sha = src_dep.git_sha,
                .git_tag = src_dep.git_tag,
                .deps_root = src_dep.deps_root,
            };
        }
        break :blk @as([]const Dep, d[0..dep_count]);
    } else @as([]const Dep, &.{});

    // Convert wasm deps
    const wasm_count = deps_config.wasm_deps.len;
    const wasm_deps = if (wasm_count > 0) blk: {
        const w = allocator.alloc(WasmDep, wasm_count) catch break :blk @as([]const WasmDep, &.{});
        for (deps_config.wasm_deps, 0..) |src_wd, idx| {
            w[idx] = .{ .name = src_wd.name, .path = src_wd.path };
        }
        break :blk @as([]const WasmDep, w[0..wasm_count]);
    } else @as([]const WasmDep, &.{});

    return .{
        .paths = deps_config.paths,
        .test_paths = deps_config.test_paths,
        .main_ns = deps_config.main_ns,
        .deps = deps,
        .wasm_deps = wasm_deps,
    };
}

/// Try to infer git URL from io.github/io.gitlab lib name pattern.
fn inferGitUrlFromName(allocator: Allocator, name: []const u8) ?[]const u8 {
    return deps_mod.inferGitUrl(allocator, name);
}

// === cljw.edn config parsing ===

/// A single dependency declaration from cljw.edn / deps.edn :deps.
const Dep = struct {
    local_root: ?[]const u8 = null, // :local/root path
    git_url: ?[]const u8 = null, // :git/url
    git_sha: ?[]const u8 = null, // :git/sha
    git_tag: ?[]const u8 = null, // :git/tag (optional, for display + validation)
    deps_root: ?[]const u8 = null, // :deps/root (monorepo subdirectory)
};

/// A wasm module dependency: name → path.
const WasmDep = struct {
    name: []const u8,
    path: []const u8,
};

/// Parsed cljw.edn configuration.
const ProjectConfig = struct {
    paths: []const []const u8 = &.{},
    test_paths: []const []const u8 = &.{},
    main_ns: ?[]const u8 = null,
    deps: []const Dep = &.{},
    wasm_deps: []const WasmDep = &.{},
};

const ConfigFile = struct {
    content: []const u8,
    dir: ?[]const u8, // directory containing cljw.edn (null = CWD)
};

/// Search for cljw.edn starting from dir, walking up to root.
/// Returns file content and the directory where it was found.
fn findConfigFile(allocator: Allocator, start_dir: ?[]const u8) ?ConfigFile {
    // Try CWD first
    if (readConfigFromDir(allocator, ".")) |content| return .{ .content = content, .dir = null };

    // Walk up from start_dir
    var current = start_dir orelse return null;
    for (0..10) |_| {
        if (readConfigFromDir(allocator, current)) |content| return .{ .content = content, .dir = current };
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return null;
}

fn readConfigFromDir(allocator: Allocator, dir: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/cljw.edn", .{dir}) catch return null;
    return std.fs.cwd().readFileAlloc(allocator, path, 10_000) catch null;
}

/// Parse cljw.edn content using the Reader (no bootstrap needed).
fn parseConfig(allocator: Allocator, source: []const u8) ProjectConfig {
    var reader = Reader.init(allocator, source);
    const form = reader.read() catch return .{};
    const root = form orelse return .{};

    if (root.data != .map) return .{};
    const entries = root.data.map;

    var config = ProjectConfig{};
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const kw = entries[i].data.keyword.name;

        if (std.mem.eql(u8, kw, "paths")) {
            if (entries[i + 1].data == .vector) {
                const vec = entries[i + 1].data.vector;
                const paths = allocator.alloc([]const u8, vec.len) catch continue;
                var count: usize = 0;
                for (vec) |elem| {
                    if (elem.data == .string) {
                        paths[count] = elem.data.string;
                        count += 1;
                    }
                }
                config.paths = paths[0..count];
            }
        } else if (std.mem.eql(u8, kw, "test-paths")) {
            if (entries[i + 1].data == .vector) {
                const vec = entries[i + 1].data.vector;
                const paths = allocator.alloc([]const u8, vec.len) catch continue;
                var count: usize = 0;
                for (vec) |elem| {
                    if (elem.data == .string) {
                        paths[count] = elem.data.string;
                        count += 1;
                    }
                }
                config.test_paths = paths[0..count];
            }
        } else if (std.mem.eql(u8, kw, "deps")) {
            if (entries[i + 1].data == .map) {
                config.deps = parseDeps(allocator, entries[i + 1].data.map);
            }
        } else if (std.mem.eql(u8, kw, "wasm-deps")) {
            if (entries[i + 1].data == .map) {
                config.wasm_deps = parseWasmDeps(allocator, entries[i + 1].data.map);
            }
        } else if (std.mem.eql(u8, kw, "main")) {
            if (entries[i + 1].data == .symbol) {
                const sym = entries[i + 1].data.symbol;
                if (sym.ns) |ns| {
                    // Qualified: my-app/core → my-app.core
                    config.main_ns = std.fmt.allocPrint(allocator, "{s}.{s}", .{ ns, sym.name }) catch null;
                } else {
                    config.main_ns = sym.name;
                }
            }
        }
    }
    return config;
}

/// Parse :deps map → slice of Dep.
/// Formats: {:local/root "path"}, {:git/url "..." :git/sha "..."}
fn parseDeps(allocator: Allocator, dep_entries: []const Form) []const Dep {
    const count = dep_entries.len / 2;
    if (count == 0) return &.{};
    const deps = allocator.alloc(Dep, count) catch return &.{};
    var n: usize = 0;
    var di: usize = 0;
    while (di + 1 < dep_entries.len) : (di += 2) {
        // value must be a map
        if (dep_entries[di + 1].data != .map) continue;
        const val_map = dep_entries[di + 1].data.map;
        var dep = Dep{};
        var vi: usize = 0;
        while (vi + 1 < val_map.len) : (vi += 2) {
            if (val_map[vi].data == .keyword) {
                const dk = val_map[vi].data.keyword;
                const ns = dk.ns orelse continue;
                if (val_map[vi + 1].data == .string) {
                    const val_str = val_map[vi + 1].data.string;
                    if (std.mem.eql(u8, ns, "local") and std.mem.eql(u8, dk.name, "root")) {
                        dep.local_root = val_str;
                    } else if (std.mem.eql(u8, ns, "git") and std.mem.eql(u8, dk.name, "url")) {
                        dep.git_url = val_str;
                    } else if (std.mem.eql(u8, ns, "git") and std.mem.eql(u8, dk.name, "sha")) {
                        dep.git_sha = val_str;
                    }
                }
            }
        }
        if (dep.local_root != null or (dep.git_url != null and dep.git_sha != null)) {
            deps[n] = dep;
            n += 1;
        }
    }
    return deps[0..n];
}

/// Parse :wasm-deps map → slice of WasmDep. Format: {"name" {:local/root "path.wasm"}}
fn parseWasmDeps(allocator: Allocator, entries: []const Form) []const WasmDep {
    const count = entries.len / 2;
    if (count == 0) return &.{};
    const deps = allocator.alloc(WasmDep, count) catch return &.{};
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        // key must be a string (module name)
        if (entries[i].data != .string) continue;
        const name = entries[i].data.string;
        // value must be a map with :local/root
        if (entries[i + 1].data != .map) continue;
        const val_map = entries[i + 1].data.map;
        var vi: usize = 0;
        while (vi + 1 < val_map.len) : (vi += 2) {
            if (val_map[vi].data == .keyword) {
                const dk = val_map[vi].data.keyword;
                const ns = dk.ns orelse continue;
                if (std.mem.eql(u8, ns, "local") and std.mem.eql(u8, dk.name, "root")) {
                    if (val_map[vi + 1].data == .string) {
                        deps[n] = .{ .name = name, .path = val_map[vi + 1].data.string };
                        n += 1;
                        break;
                    }
                }
            }
        }
    }
    return deps[0..n];
}

/// Apply cljw.edn config: add paths and resolve deps.
fn applyConfig(config: ProjectConfig, config_dir: ?[]const u8) void {
    for (config.paths) |path| {
        if (config_dir) |dir| {
            // Resolve relative paths against config file directory
            var buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
            ns_ops.addLoadPath(full) catch {};
        } else {
            ns_ops.addLoadPath(path) catch {};
        }
    }
    // Resolve deps
    for (config.deps) |dep| {
        if (dep.local_root) |root| {
            resolveLocalDep(root, config_dir);
        } else if (dep.git_url != null and dep.git_sha != null) {
            resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, false);
        }
    }
    // Register wasm module deps
    for (config.wasm_deps) |wd| {
        var wasm_buf: [4096]u8 = undefined;
        const resolved = if (config_dir) |dir|
            std.fmt.bufPrint(&wasm_buf, "{s}/{s}", .{ dir, wd.path }) catch continue
        else
            wd.path;
        wasm_builtins.registerWasmDep(wd.name, resolved);
    }
}

/// Resolve a :local/root dependency: add its :paths to load paths and recurse.
fn resolveLocalDep(root: []const u8, config_dir: ?[]const u8) void {
    // Resolve relative path against config directory
    var path_buf: [4096]u8 = undefined;
    const dep_dir = if (config_dir) |dir|
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, root }) catch return
    else
        root;

    // Add default source path (dep_dir/src)
    var src_buf: [4096]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{dep_dir}) catch return;
    ns_ops.addLoadPath(src_path) catch {};

    // Try to read dep's cljw.edn for custom :paths
    var dep_config_buf: [4096]u8 = undefined;
    const dep_config_path = std.fmt.bufPrint(&dep_config_buf, "{s}/cljw.edn", .{dep_dir}) catch return;
    const dep_content = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        dep_config_path,
        10_000,
    ) catch return; // No cljw.edn — default "src" already added
    defer std.heap.page_allocator.free(dep_content);

    var reader = Reader.init(std.heap.page_allocator, dep_content);
    const form = reader.read() catch return;
    const root_form = form orelse return;
    if (root_form.data != .map) return;
    const map_entries = root_form.data.map;

    // Parse :paths and :deps from dep's cljw.edn
    var di: usize = 0;
    while (di + 1 < map_entries.len) : (di += 2) {
        if (map_entries[di].data != .keyword) {
            di = di; // no-op to satisfy loop
            continue;
        }
        const kw = map_entries[di].data.keyword;
        if (kw.ns == null and std.mem.eql(u8, kw.name, "paths")) {
            if (map_entries[di + 1].data == .vector) {
                for (map_entries[di + 1].data.vector) |elem| {
                    if (elem.data == .string) {
                        var sub_buf: [4096]u8 = undefined;
                        const full = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dep_dir, elem.data.string }) catch continue;
                        ns_ops.addLoadPath(full) catch {};
                    }
                }
            }
        } else if (kw.ns == null and std.mem.eql(u8, kw.name, "deps")) {
            if (map_entries[di + 1].data == .map) {
                // Recurse into transitive deps
                const sub_deps = parseDeps(std.heap.page_allocator, map_entries[di + 1].data.map);
                for (sub_deps) |sub_dep| {
                    if (sub_dep.local_root) |sub_root| {
                        resolveLocalDep(sub_root, dep_dir);
                    }
                }
            }
        }
    }
}

/// Resolve a :git/url + :git/sha dependency.
/// Cache: ~/.cljw/gitlibs/_repos/<hash>.git (bare) and ~/.cljw/gitlibs/<hash>/<sha>/
/// tag: optional :git/tag for validation (verify tag points to sha)
/// deps_root: optional :deps/root subdirectory within the git repo
/// force: -Sforce flag — bypass cache and re-fetch
fn resolveGitDep(url: []const u8, sha: []const u8, tag: ?[]const u8, deps_root: ?[]const u8, force: bool) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const alloc = std.heap.page_allocator;

    // Compute URL hash for cache key (simple djb2)
    var hash: u64 = 5381;
    for (url) |c| hash = hash *% 33 +% c;
    var hash_str: [20]u8 = undefined;
    const hash_slice = std.fmt.bufPrint(&hash_str, "{x}", .{hash}) catch return;

    // Get home directory
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);

    // Ensure cache directories exist
    var repo_dir_buf: [4096]u8 = undefined;
    const repo_dir = std.fmt.bufPrint(&repo_dir_buf, "{s}/.cljw/gitlibs/_repos/{s}.git", .{ home, hash_slice }) catch return;
    var lib_dir_buf: [4096]u8 = undefined;
    const lib_dir = std.fmt.bufPrint(&lib_dir_buf, "{s}/.cljw/gitlibs/{s}/{s}", .{ home, hash_slice, sha }) catch return;

    // Compute effective root (lib_dir or lib_dir/deps_root)
    var effective_dir_buf: [4096]u8 = undefined;
    const effective_dir = if (deps_root) |dr|
        std.fmt.bufPrint(&effective_dir_buf, "{s}/{s}", .{ lib_dir, dr }) catch return
    else
        lib_dir;

    // Check if already checked out (skip if force)
    var marker_buf: [4096]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "{s}/.cljw-resolved", .{lib_dir}) catch return;
    if (!force) {
        if (std.fs.cwd().access(marker, .{})) |_| {
            // Already resolved — just add paths
            resolveLocalDep(effective_dir, null);
            return;
        } else |_| {}
    }

    _ = stderr.write("Fetching ") catch {};
    _ = stderr.write(url) catch {};
    if (tag) |t| {
        _ = stderr.write(" (") catch {};
        _ = stderr.write(t) catch {};
        _ = stderr.write(")") catch {};
    }
    _ = stderr.write(" ...\n") catch {};

    // Clone or fetch bare repo
    const repo_exists = if (std.fs.cwd().access(repo_dir, .{})) |_| true else |_| false;
    if (!repo_exists) {
        // Create parent directories
        const repo_parent = std.fs.path.dirname(repo_dir) orelse return;
        std.fs.cwd().makePath(repo_parent) catch {};

        // Clone bare
        var clone = std.process.Child.init(
            &.{ "git", "clone", "--bare", "--quiet", url, repo_dir },
            alloc,
        );
        clone.stderr_behavior = .Inherit;
        clone.spawn() catch {
            _ = stderr.write("Error: git clone failed\n") catch {};
            return;
        };
        const clone_term = clone.wait() catch return;
        if (clone_term.Exited != 0) {
            _ = stderr.write("Error: git clone exited with error\n") catch {};
            return;
        }
    } else {
        // Fetch latest (always when force, otherwise only if not cached)
        var fetch = std.process.Child.init(
            &.{ "git", "--git-dir", repo_dir, "fetch", "--quiet", "origin" },
            alloc,
        );
        fetch.stderr_behavior = .Inherit;
        fetch.spawn() catch return;
        _ = fetch.wait() catch {};
    }

    // Validate :git/tag matches :git/sha (if tag provided)
    if (tag) |t| {
        if (!validateGitTag(alloc, repo_dir, t, sha)) return;
    }

    // If force, remove old extraction to re-extract
    if (force) {
        std.fs.cwd().deleteTree(lib_dir) catch {};
    }

    // Extract archive at the requested sha
    std.fs.cwd().makePath(lib_dir) catch {};

    var archive = std.process.Child.init(
        &.{ "git", "--git-dir", repo_dir, "archive", "--format=tar", sha },
        alloc,
    );
    archive.stdout_behavior = .Pipe;
    archive.stderr_behavior = .Inherit;
    archive.spawn() catch {
        _ = stderr.write("Error: git archive failed\n") catch {};
        return;
    };

    var tar = std.process.Child.init(
        &.{ "tar", "-x", "-C", lib_dir },
        alloc,
    );
    tar.stdin_behavior = .Pipe;
    tar.stderr_behavior = .Inherit;
    tar.spawn() catch {
        _ = archive.kill() catch {};
        _ = stderr.write("Error: tar failed\n") catch {};
        return;
    };

    // Pipe git archive stdout → tar stdin
    const archive_stdout = archive.stdout orelse return;
    const tar_stdin = tar.stdin orelse return;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = archive_stdout.read(&buf) catch break;
        if (n == 0) break;
        tar_stdin.writeAll(buf[0..n]) catch break;
    }
    tar.stdin = null; // close stdin

    const archive_term = archive.wait() catch return;
    const tar_term = tar.wait() catch return;

    if (archive_term.Exited != 0 or tar_term.Exited != 0) {
        _ = stderr.write("Error: failed to extract git archive for sha ") catch {};
        _ = stderr.write(sha) catch {};
        _ = stderr.write("\n") catch {};
        return;
    }

    // Write marker file
    if (std.fs.cwd().createFile(marker, .{})) |f| {
        f.close();
    } else |_| {}

    // Resolve paths from the extracted dep (using effective_dir for :deps/root)
    resolveLocalDep(effective_dir, null);
}

/// Validate that a git tag points to the expected SHA.
/// Returns true if valid, false if mismatch (prints error).
fn validateGitTag(alloc: Allocator, repo_dir: []const u8, tag_name: []const u8, expected_sha: []const u8) bool {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Use rev-parse to resolve tag to SHA (^{} dereferences annotated tags)
    var tag_ref_buf: [256]u8 = undefined;
    const tag_ref = std.fmt.bufPrint(&tag_ref_buf, "refs/tags/{s}^{{}}", .{tag_name}) catch return true;

    var rev_parse = std.process.Child.init(
        &.{ "git", "--git-dir", repo_dir, "rev-parse", tag_ref },
        alloc,
    );
    rev_parse.stdout_behavior = .Pipe;
    rev_parse.stderr_behavior = .Pipe;
    rev_parse.spawn() catch return true; // can't validate → proceed

    // Read stdout to get resolved SHA
    var out_buf: [256]u8 = undefined;
    const stdout_pipe = rev_parse.stdout orelse return true;
    const n = stdout_pipe.read(&out_buf) catch return true;
    const tag_sha_raw = out_buf[0..n];

    const term = rev_parse.wait() catch return true;
    if (term.Exited != 0) {
        // Tag doesn't exist in repo — warn but continue (sha is the authority)
        _ = stderr.write("WARNING: Git tag \"") catch {};
        _ = stderr.write(tag_name) catch {};
        _ = stderr.write("\" not found in repository. Using :git/sha directly.\n") catch {};
        return true;
    }

    // Trim trailing newline
    const tag_sha = std.mem.trimRight(u8, tag_sha_raw, "\n\r ");

    // Compare: expected_sha can be a prefix (short sha)
    if (tag_sha.len >= expected_sha.len and std.mem.eql(u8, tag_sha[0..expected_sha.len], expected_sha)) {
        return true; // match
    }

    // Full sha provided but doesn't match
    _ = stderr.write("ERROR: Git tag \"") catch {};
    _ = stderr.write(tag_name) catch {};
    _ = stderr.write("\" does not match :git/sha \"") catch {};
    _ = stderr.write(expected_sha) catch {};
    _ = stderr.write("\"\n  Tag points to: ") catch {};
    _ = stderr.write(tag_sha) catch {};
    _ = stderr.write("\n  Fix the :git/sha in deps.edn\n") catch {};
    return false;
}

// === Error reporting (babashka-style) ===

// ANSI color codes (empty strings when not a TTY)
const Ansi = struct {
    red: []const u8,
    bold: []const u8,
    dim: []const u8,
    cyan: []const u8,
    reset: []const u8,

    const color = Ansi{
        .red = "\x1b[31m",
        .bold = "\x1b[1m",
        .dim = "\x1b[2m",
        .cyan = "\x1b[36m",
        .reset = "\x1b[0m",
    };
    const plain = Ansi{
        .red = "",
        .bold = "",
        .dim = "",
        .cyan = "",
        .reset = "",
    };
};

fn reportError(eval_err: anyerror) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const c = if (std.posix.isatty(std.posix.STDERR_FILENO)) Ansi.color else Ansi.plain;

    if (err.getLastError()) |info| {
        // Header: "Type error at REPL:1:5" or "Type error"
        const kind_label = kindToLabel(info.kind);
        if (info.location.line > 0) {
            const file = info.location.file orelse "REPL";
            w.print("{s}{s}{s}{s} at {s}:{d}:{d}{s}\n", .{
                c.bold, c.red, kind_label, c.reset,
                file,   info.location.line, info.location.column, c.reset,
            }) catch {};
        } else {
            w.print("{s}{s}{s}{s}\n", .{ c.bold, c.red, kind_label, c.reset }) catch {};
        }
        // Message
        w.print("  {s}\n", .{info.message}) catch {};
        // Call stack trace
        const stack = err.getCallStack();
        if (stack.len > 0) {
            w.print("{s}Trace:{s}\n", .{ c.dim, c.reset }) catch {};
            var i: usize = stack.len;
            while (i > 0) {
                i -= 1;
                const f = stack[i];
                const ns_name = f.ns orelse "?";
                const fn_name = f.fn_name orelse "anonymous";
                if (f.file) |file| {
                    if (f.line > 0) {
                        w.print("{s}  {s}/{s} ({s}:{d}){s}\n", .{ c.dim, ns_name, fn_name, file, f.line, c.reset }) catch {};
                    } else {
                        w.print("{s}  {s}/{s} ({s}){s}\n", .{ c.dim, ns_name, fn_name, file, c.reset }) catch {};
                    }
                } else {
                    w.print("{s}  {s}/{s}{s}\n", .{ c.dim, ns_name, fn_name, c.reset }) catch {};
                }
            }
        }
        err.clearCallStack();
        // Source context
        if (info.location.line > 0) {
            showSourceContext(w, info.location, info.message, c);
        }
    } else {
        // No detailed error info — make fallback as helpful as possible
        w.print("{s}{s}Error{s}\n", .{ c.bold, c.red, c.reset }) catch {};
        w.print("  {s}\n", .{@errorName(eval_err)}) catch {};
        if (err.getSourceFile()) |file| {
            w.print("{s}  in {s}{s}\n", .{ c.dim, file, c.reset }) catch {};
        }
        // Show call stack if available
        const stack = err.getCallStack();
        if (stack.len > 0) {
            w.print("{s}Trace:{s}\n", .{ c.dim, c.reset }) catch {};
            var i: usize = stack.len;
            while (i > 0) {
                i -= 1;
                const f = stack[i];
                const ns_name = f.ns orelse "?";
                const fn_name = f.fn_name orelse "anonymous";
                w.print("{s}  {s}/{s}{s}\n", .{ c.dim, ns_name, fn_name, c.reset }) catch {};
            }
        }
        err.clearCallStack();
    }

    _ = stderr.write(stream.getWritten()) catch {};
}

fn kindToLabel(kind: err.Kind) []const u8 {
    return switch (kind) {
        .syntax_error => "Syntax error",
        .number_error => "Number format error",
        .string_error => "String format error",
        .name_error => "Name error",
        .arity_error => "Arity error",
        .value_error => "Value error",
        .type_error => "Type error",
        .arithmetic_error => "Arithmetic error",
        .index_error => "Index error",
        .io_error => "IO error",
        .internal_error => "Internal error",
        .out_of_memory => "Out of memory",
    };
}

fn showSourceContext(w: anytype, location: err.SourceLocation, message: []const u8, c: Ansi) void {
    const source = getSourceForLocation(location) orelse return;
    const error_line = location.line; // 1-based

    // Split source into lines (max 512 lines for display)
    var lines: [512][]const u8 = undefined;
    var line_count: u32 = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        if (line_count >= lines.len) break;
        lines[line_count] = line;
        line_count += 1;
    }

    if (error_line == 0 or error_line > line_count) return;

    // Display range: ±2 lines around error
    const context: u32 = 2;
    const start = if (error_line > context) error_line - context else 1;
    const end = @min(error_line + context, line_count);
    const max_digits = countDigits(end);

    w.writeByte('\n') catch {};
    var line_num: u32 = start;
    while (line_num <= end) : (line_num += 1) {
        const line_text = lines[line_num - 1];
        if (line_num == error_line) {
            w.print("{s}", .{c.dim}) catch {};
            writeLineNumber(w, line_num, max_digits);
            w.print(" | {s}{s}{s}\n", .{ c.reset, line_text, c.reset }) catch {};
            writeErrorPointer(w, max_digits, location.column, message, c);
        } else {
            w.print("{s}", .{c.dim}) catch {};
            writeLineNumber(w, line_num, max_digits);
            w.print(" | {s}{s}\n", .{ line_text, c.reset }) catch {};
        }
    }
    w.writeByte('\n') catch {};
}

fn writeLineNumber(w: anytype, line_num: u32, width: u32) void {
    const digits = countDigits(line_num);
    w.writeAll("  ") catch {};
    var pad: u32 = 0;
    while (pad + digits < width) : (pad += 1) {
        w.writeByte(' ') catch {};
    }
    w.print("{d}", .{line_num}) catch {};
}

fn writeErrorPointer(w: anytype, max_digits: u32, column: u32, message: []const u8, c: Ansi) void {
    // "  " + digits + " | " = 2 + max_digits + 3
    const prefix_len = 2 + max_digits + 3;
    var i: u32 = 0;
    while (i < prefix_len + column) : (i += 1) {
        w.writeByte(' ') catch {};
    }
    w.print("{s}^--- {s}{s}\n", .{ c.red, message, c.reset }) catch {};
}

fn countDigits(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

fn getSourceForLocation(location: err.SourceLocation) ?[]const u8 {
    // Try file path first
    if (location.file) |file_path| {
        if (readFileForError(file_path)) |content| {
            return content;
        }
    }
    // Fallback: cached source text (REPL / -e)
    return err.getSourceText();
}

threadlocal var file_read_buf: [64 * 1024]u8 = undefined;
fn readFileForError(path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const bytes_read = file.readAll(&file_read_buf) catch return null;
    return file_read_buf[0..bytes_read];
}

// === Value formatting ===

fn formatValue(buf: []u8, val: Value) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    writeValue(w, val);
    return stream.getWritten();
}

/// Wrap pre-formatted value text with ANSI color based on value type.
fn colorizeValue(buf: []u8, text: []const u8, val: Value) []const u8 {
    const color: []const u8 = switch (val.tag()) {
        .nil, .boolean => "\x1b[35m", // magenta
        .integer, .float => "\x1b[34m", // blue
        .string, .char, .regex => "\x1b[32m", // green
        .keyword => "\x1b[36m", // cyan
        .symbol => "\x1b[33m", // yellow
        else => "", // no color for collections, fns, etc.
    };
    if (color.len == 0) {
        // No coloring — return original text directly
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const reset = "\x1b[0m";
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    w.writeAll(color) catch {};
    w.writeAll(text) catch {};
    w.writeAll(reset) catch {};
    return stream.getWritten();
}

fn writeValue(w: anytype, val: Value) void {
    switch (val.tag()) {
        .nil => w.print("nil", .{}) catch {},
        .boolean => w.print("{}", .{val.asBoolean()}) catch {},
        .integer => w.print("{d}", .{val.asInteger()}) catch {},
        .float => w.print("{d}", .{val.asFloat()}) catch {},
        .string => w.print("\"{s}\"", .{val.asString()}) catch {},
        .keyword => {
            const k = val.asKeyword();
            if (k.ns) |ns| {
                w.print(":{s}/{s}", .{ ns, k.name }) catch {};
            } else {
                w.print(":{s}", .{k.name}) catch {};
            }
        },
        .symbol => {
            const s = val.asSymbol();
            if (s.ns) |ns| {
                w.print("{s}/{s}", .{ ns, s.name }) catch {};
            } else {
                w.print("{s}", .{s.name}) catch {};
            }
        },
        .list => {
            const lst = val.asList();
            w.print("(", .{}) catch {};
            for (lst.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print(")", .{}) catch {};
        },
        .vector => {
            const vec = val.asVector();
            w.print("[", .{}) catch {};
            for (vec.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("]", .{}) catch {};
        },
        .map => {
            const m = val.asMap();
            w.print("{{", .{}) catch {};
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, m.entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, m.entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .hash_map => {
            const hm = val.asHashMap();
            w.print("{{", .{}) catch {};
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = hm.toEntries(arena.allocator()) catch &[_]Value{};
            var i: usize = 0;
            while (i < entries.len) : (i += 2) {
                if (i > 0) w.print(", ", .{}) catch {};
                writeValue(w, entries[i]);
                w.print(" ", .{}) catch {};
                writeValue(w, entries[i + 1]);
            }
            w.print("}}", .{}) catch {};
        },
        .set => {
            const s = val.asSet();
            w.print("#{{", .{}) catch {};
            for (s.items, 0..) |item, i| {
                if (i > 0) w.print(" ", .{}) catch {};
                writeValue(w, item);
            }
            w.print("}}", .{}) catch {};
        },
        .fn_val => w.print("#<fn>", .{}) catch {},
        .builtin_fn => w.print("#<builtin>", .{}) catch {},
        .atom => {
            const a = val.asAtom();
            w.print("(atom ", .{}) catch {};
            writeValue(w, a.value);
            w.print(")", .{}) catch {};
        },
        .volatile_ref => {
            const v = val.asVolatile();
            w.print("#<volatile ", .{}) catch {};
            writeValue(w, v.value);
            w.print(">", .{}) catch {};
        },
        .regex => {
            const p = val.asRegex();
            w.print("#\"{s}\"", .{p.source}) catch {};
        },
        .char => {
            const c = val.asChar();
            var char_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &char_buf) catch 0;
            _ = w.write("\\") catch {};
            _ = w.write(char_buf[0..len]) catch {};
        },
        .protocol => w.print("#<protocol {s}>", .{val.asProtocol().name}) catch {},
        .protocol_fn => {
            const pf = val.asProtocolFn();
            w.print("#<protocol-fn {s}/{s}>", .{ pf.protocol.name, pf.method_name }) catch {};
        },
        .multi_fn => w.print("#<multifn {s}>", .{val.asMultiFn().name}) catch {},
        .lazy_seq => {
            const ls = val.asLazySeq();
            if (ls.realized) |r| {
                writeValue(w, r);
            } else {
                w.print("#<lazy-seq>", .{}) catch {};
            }
        },
        .cons => {
            const c = val.asCons();
            w.print("(", .{}) catch {};
            writeValue(w, c.first);
            w.print(" . ", .{}) catch {};
            writeValue(w, c.rest);
            w.print(")", .{}) catch {};
        },
        .var_ref => {
            const v = val.asVarRef();
            w.print("#'{s}/{s}", .{ v.ns_name, v.sym.name }) catch {};
        },
        .delay => {
            const d = val.asDelay();
            if (d.realized) {
                w.print("#delay[", .{}) catch {};
                if (d.getCached()) |v| writeValue(w, v) else w.print("nil", .{}) catch {};
                w.print("]", .{}) catch {};
            } else {
                w.print("#delay[pending]", .{}) catch {};
            }
        },
        .future => {
            const f = val.asFuture();
            const thread_pool = @import("runtime/thread_pool.zig");
            const result: *thread_pool.FutureResult = @ptrCast(@alignCast(f.result));
            if (f.cancelled) {
                w.print("#future[cancelled]", .{}) catch {};
            } else if (result.isDone()) {
                w.print("#future[", .{}) catch {};
                writeValue(w, result.value);
                w.print("]", .{}) catch {};
            } else {
                w.print("#future[pending]", .{}) catch {};
            }
        },
        .promise => {
            const p = val.asPromise();
            const thread_pool = @import("runtime/thread_pool.zig");
            const sync: *thread_pool.FutureResult = @ptrCast(@alignCast(p.sync));
            if (sync.isDone()) {
                w.print("#promise[", .{}) catch {};
                writeValue(w, sync.value);
                w.print("]", .{}) catch {};
            } else {
                w.print("#promise[pending]", .{}) catch {};
            }
        },
        .agent => {
            const a = val.asAgent();
            const inner = a.getInner();
            if (inner.isInErrorState()) {
                w.print("#agent[FAILED ", .{}) catch {};
            } else {
                w.print("#agent[", .{}) catch {};
            }
            writeValue(w, inner.state);
            w.print("]", .{}) catch {};
        },
        .reduced => writeValue(w, val.asReduced().value),
        .transient_vector => w.print("#<TransientVector>", .{}) catch {},
        .transient_map => w.print("#<TransientMap>", .{}) catch {},
        .transient_set => w.print("#<TransientSet>", .{}) catch {},
        .chunked_cons => {
            const cc = val.asChunkedCons();
            w.print("(", .{}) catch {};
            var i: usize = 0;
            while (i < cc.chunk.count()) : (i += 1) {
                if (i > 0) w.print(" ", .{}) catch {};
                const elem = cc.chunk.nth(i) orelse Value.nil_val;
                writeValue(w, elem);
            }
            if (cc.more.tag() != .nil) w.print(" ...", .{}) catch {};
            w.print(")", .{}) catch {};
        },
        .chunk_buffer => w.print("#<ChunkBuffer>", .{}) catch {},
        .array_chunk => w.print("#<ArrayChunk>", .{}) catch {},
        .wasm_module => w.print("#<WasmModule>", .{}) catch {},
        .wasm_fn => w.print("#<WasmFn {s}>", .{val.asWasmFn().name}) catch {},
        .matcher => w.print("#<Matcher>", .{}) catch {},
        .array => {
            const arr = val.asArray();
            w.print("#<{s}[{d}]>", .{ @tagName(arr.element_type), arr.items.len }) catch {};
        },
        .big_int => w.print("#<BigInt>", .{}) catch {},
        .big_decimal => w.print("#<BigDecimal>", .{}) catch {},
        .ratio => w.print("#<Ratio>", .{}) catch {},
    }
}

// === Single Binary Builder (Phase 28) ===

/// Read embedded source from this binary's CLJW trailer.
/// Returns null if no trailer found (normal cljw binary).
fn readEmbeddedSource(allocator: Allocator) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch return null;
    const file = std.fs.openFileAbsolute(self_path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size < embed_trailer_size) return null;

    // Read trailer (last 12 bytes)
    file.seekTo(file_size - embed_trailer_size) catch return null;
    var trailer: [embed_trailer_size]u8 = undefined;
    const n = file.readAll(&trailer) catch return null;
    if (n != embed_trailer_size) return null;

    // Check magic
    if (!std.mem.eql(u8, trailer[8..12], embed_magic)) return null;

    // Extract payload size
    const payload_size = std.mem.readInt(u64, trailer[0..8], .little);
    if (payload_size == 0 or payload_size > file_size - embed_trailer_size) return null;

    // Read payload
    file.seekTo(file_size - embed_trailer_size - payload_size) catch return null;
    const source = allocator.alloc(u8, @intCast(payload_size)) catch return null;
    const bytes_read = file.readAll(source) catch {
        allocator.free(source);
        return null;
    };
    if (bytes_read != @as(usize, @intCast(payload_size))) {
        allocator.free(source);
        return null;
    }
    return source;
}

/// Evaluate embedded source and exit. Used by built binaries.
fn evalEmbedded(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, cli_args: []const [:0]const u8) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set *command-line-args*
    setCommandLineArgs(gc_alloc, &env, cli_args);

    // Evaluate using VM backend
    _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Run shutdown hooks (relevant when run-server returns via SIGINT)
    if (lifecycle.isShutdownRequested()) {
        lifecycle.runShutdownHooks(gc_alloc, &env);
    }
}

/// Start nREPL server with a file pre-evaluated.
/// Used by: cljw --nrepl-server --port=N file.clj
fn startNreplWithFile(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, filepath: []const u8, nrepl_port: u16) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set up load paths for require resolution
    const dir = std.fs.path.dirname(filepath) orelse ".";
    ns_ops.addLoadPath(dir) catch {};
    ns_ops.detectAndAddSrcPath(dir) catch {};

    const max_file_size = 10 * 1024 * 1024;
    const file_bytes = std.fs.cwd().readFileAlloc(infra_alloc, filepath, max_file_size) catch {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: could not read file\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(file_bytes);

    err.setSourceFile(filepath);
    err.setSourceText(file_bytes);

    // HTTP servers should run in background so nREPL can start after eval.
    http_server.background_mode = true;

    // Evaluate file (defines user namespaces/defs)
    _ = bootstrap.evalString(gc_alloc, &env, file_bytes) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Start nREPL server with user's Env (blocking accept loop).
    nrepl.startServerWithEnv(infra_alloc, &env, gc, nrepl_port) catch |e| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: nREPL server failed: ") catch {};
        _ = stderr.write(@errorName(e)) catch {};
        _ = stderr.write("\n") catch {};
        std.process.exit(1);
    };

    lifecycle.runShutdownHooks(gc_alloc, &env);
}

/// Evaluate embedded source, then start nREPL server on the same Env.
/// Used by built binaries with --nrepl flag.
fn evalEmbeddedWithNrepl(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, source: []const u8, cli_args: []const [:0]const u8, nrepl_port: u16) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    setCommandLineArgs(gc_alloc, &env, cli_args);

    // HTTP servers should run in background so nREPL can start after eval.
    http_server.background_mode = true;

    // Evaluate embedded source (defines user namespaces/defs)
    _ = bootstrap.evalStringVM(gc_alloc, &env, source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Start nREPL server with user's Env (blocking accept loop).
    // Returns when shutdown signal is received.
    nrepl.startServerWithEnv(infra_alloc, &env, gc, nrepl_port) catch |e| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        _ = stderr.write("Error: nREPL server failed: ") catch {};
        _ = stderr.write(@errorName(e)) catch {};
        _ = stderr.write("\n") catch {};
        std.process.exit(1);
    };

    // Run user-registered shutdown hooks before exit
    lifecycle.runShutdownHooks(gc_alloc, &env);
}

/// Set *command-line-args* to a list of string Values.
fn setCommandLineArgs(gc_alloc: Allocator, env: *Env, cli_args: []const [:0]const u8) void {
    if (cli_args.len == 0) return; // leave as nil

    const core_ns = env.findNamespace("clojure.core") orelse return;
    const v = core_ns.resolve("*command-line-args*") orelse return;

    // Build list of string Values
    const items = gc_alloc.alloc(Value, cli_args.len) catch return;
    for (cli_args, 0..) |arg, i| {
        const duped = gc_alloc.dupe(u8, arg) catch return;
        items[i] = Value.initString(gc_alloc, duped);
    }
    const list = gc_alloc.create(collections.PersistentList) catch return;
    list.* = .{ .items = items };
    v.bindRoot(Value.initList(list));
}

/// Handle `cljw build <file> [-o <output>]` subcommand.
/// Evaluates the entry file to resolve all requires, then bundles dependency
/// sources (in load order) + entry source into a single binary.
fn handleBuildCommand(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, build_args: []const [:0]const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    var source_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < build_args.len) : (i += 1) {
        if (std.mem.eql(u8, build_args[i], "-o")) {
            i += 1;
            if (i >= build_args.len) {
                _ = stderr.write("Error: -o requires an output file argument\n") catch {};
                std.process.exit(1);
            }
            output_file = build_args[i];
        } else {
            source_file = build_args[i];
        }
    }

    if (source_file == null) {
        _ = stderr.write("Usage: cljw build <source.clj> [-o <output>]\n") catch {};
        std.process.exit(1);
    }

    // Read entry file source
    const max_file_size = 10 * 1024 * 1024; // 10MB
    const user_source = std.fs.cwd().readFileAlloc(infra_alloc, source_file.?, max_file_size) catch {
        _ = stderr.write("Error: could not read source file\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(user_source);

    // Bootstrap runtime from cache
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    // Set up load paths from entry file directory
    const dir = std.fs.path.dirname(source_file.?) orelse ".";
    ns_ops.addLoadPath(dir) catch {};
    ns_ops.detectAndAddSrcPath(dir) catch {};

    // Enable file tracking, then evaluate entry file to resolve all requires.
    // Each file loaded by require is recorded in load order.
    ns_ops.enableFileTracking();
    http_server.build_mode = true;
    _ = bootstrap.evalStringVM(gc_alloc, &env, user_source) catch |e| {
        reportError(e);
        std.process.exit(1);
    };

    // Collect dependency sources (in load order) and bundle with entry source
    const loaded_files = ns_ops.getLoadedFiles();
    var bundled_size: usize = user_source.len;
    for (loaded_files) |rec| {
        bundled_size += rec.content.len + 1; // +1 for newline separator
    }
    const bundled = infra_alloc.alloc(u8, bundled_size) catch {
        _ = stderr.write("Error: out of memory\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(bundled);

    var offset: usize = 0;
    for (loaded_files) |rec| {
        @memcpy(bundled[offset..][0..rec.content.len], rec.content);
        offset += rec.content.len;
        bundled[offset] = '\n';
        offset += 1;
    }
    @memcpy(bundled[offset..][0..user_source.len], user_source);

    // Determine output filename (default: strip .clj extension)
    const out_name = output_file orelse blk: {
        const src = source_file.?;
        if (std.mem.endsWith(u8, src, ".clj")) {
            break :blk src[0 .. src.len - 4];
        }
        break :blk src;
    };

    // Read self binary
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch {
        _ = stderr.write("Error: could not determine self executable path\n") catch {};
        std.process.exit(1);
    };
    const self_bytes = std.fs.cwd().readFileAlloc(infra_alloc, self_path, 100 * 1024 * 1024) catch {
        _ = stderr.write("Error: could not read self executable\n") catch {};
        std.process.exit(1);
    };
    defer infra_alloc.free(self_bytes);

    // Write output: [self binary] + [bundled source] + [u64 size] + "CLJW"
    const out_file = std.fs.cwd().createFile(out_name, .{ .mode = 0o755 }) catch {
        _ = stderr.write("Error: could not create output file\n") catch {};
        std.process.exit(1);
    };
    defer out_file.close();

    out_file.writeAll(self_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(bundled) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    const size_bytes = std.mem.toBytes(std.mem.nativeTo(u64, @as(u64, @intCast(bundled.len)), .little));
    out_file.writeAll(&size_bytes) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };
    out_file.writeAll(embed_magic) catch {
        _ = stderr.write("Error: write failed\n") catch {};
        std.process.exit(1);
    };

    // Report success
    const dep_count = loaded_files.len;
    const total_size = self_bytes.len + bundled.len + embed_trailer_size;
    var msg_buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&msg_buf);
    const w = stream.writer();
    if (dep_count > 0) {
        w.print("Built: {s} ({d} bytes, {d} deps, source: {d} bytes)\n", .{ out_name, total_size, dep_count, bundled.len }) catch {};
    } else {
        w.print("Built: {s} ({d} bytes, source: {d} bytes)\n", .{ out_name, total_size, bundled.len }) catch {};
    }
    _ = stdout.write(stream.getWritten()) catch {};
}

/// Run embedded bytecode payload (built binary with compiled .cljc).
/// Like evalEmbedded but for bytecode — does NOT print the result (scripts handle output).
fn runEmbeddedBytecode(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, module_bytes: []const u8) void {
    var env = Env.init(infra_alloc);
    defer env.deinit();
    bootstrapFromCache(gc_alloc, &env, gc);

    _ = bootstrap.runBytecodeModule(gc_alloc, &env, module_bytes) catch |e| {
        reportError(e);
        std.process.exit(1);
    };
}

/// Check if bytes are a compiled bytecode Module (starts with "CLJC" magic).
fn isBytecodeModule(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], "CLJC");
}

