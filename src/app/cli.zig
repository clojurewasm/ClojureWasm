// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! CLI argument parsing, help text, deps.edn resolution, project scaffolding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("../runtime/env.zig").Env;
const deps_mod = @import("deps.zig");
const ns_ops = @import("../lang/builtins/ns_ops.zig");
const err = @import("../runtime/error.zig");
const gc_mod = @import("../runtime/gc.zig");
const nrepl = @import("repl/nrepl.zig");
const runner = @import("runner.zig");
const wasm_builtins = @import("wasm/builtins.zig");

const build_options = @import("build_options");
const enable_wasm = build_options.enable_wasm;

fn printHelp() void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(runner.version_string) catch {};
    _ = stdout.write(
        \\
        \\Usage:
        \\  cljw [options] [file.clj]
        \\  cljw -A:alias              REPL with alias
        \\  cljw -M:alias [-m ns]      Main mode with alias
        \\  cljw -X:alias fn [:k v]    Exec mode
        \\  cljw -P                    Resolve deps only
        \\  cljw build <file> [-o out] Build standalone binary
        \\  cljw test [files...]       Run tests
        \\  cljw new <name>            Create new project
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
        \\  cljw new my-app            Create new project
        \\
    ) catch {};
}

const CliMode = enum { normal, alias_repl, main_mode, exec_mode, resolve_only, show_path };

/// Main CLI dispatch: parse args, load deps.edn, execute.
/// Called from main() after infrastructure init and subcommand dispatch.
pub fn run(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, args: []const [:0]const u8) void {
    // Parse flags
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
            _ = stdout.write(runner.version_string) catch {};
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
            runner.startNreplWithFile(gc_alloc, infra_alloc, gc, f, nrepl_port);
        } else {
            nrepl.startServer(infra_alloc, nrepl_port) catch |e| {
                const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                _ = stderr.write("Error: nREPL server failed: ") catch {};
                _ = stderr.write(@errorName(e)) catch {};
                _ = stderr.write("\n") catch {};
                std.process.exit(1);
            };
        }
        return;
    }

    // Load deps.edn config if present.
    // Uses arena for config parsing — freed when config is no longer needed.
    var config_arena = std.heap.ArenaAllocator.init(infra_alloc);
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

        // Apply resolved deps (resolve_deps=true for direct deps → reads transitive dep configs)
        for (resolved.deps) |dep| {
            if (dep.local_root) |root| {
                resolveLocalDep(root, config_dir, true);
            } else if (dep.git_url != null and dep.git_sha != null) {
                resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, s_force, true, mode == .resolve_only);
            } else {
                // Try io.github/io.gitlab URL inference
                if (deps_mod.inferGitUrl(config_alloc, dep.name)) |inferred_url| {
                    if (dep.git_sha) |sha| {
                        resolveGitDep(inferred_url, sha, dep.git_tag, dep.deps_root, s_force, true, mode == .resolve_only);
                    }
                }
            }
        }

        // Apply wasm deps
        if (enable_wasm) {
            for (resolved.wasm_deps) |wd| {
                var wasm_buf: [4096]u8 = undefined;
                const wasm_resolved = if (config_dir) |dir|
                    std.fmt.bufPrint(&wasm_buf, "{s}/{s}", .{ dir, wd.path }) catch continue
                else
                    wd.path;
                wasm_builtins.registerWasmDep(wd.name, wasm_resolved);
            }
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
                var env2 = Env.init(infra_alloc);
                defer env2.deinit();
                runner.bootstrapFromCache(gc_alloc, &env2, gc);
                if (file) |f| {
                    // -A:dev file.clj — run file with alias
                    const dir = std.fs.path.dirname(f) orelse ".";
                    ns_ops.addLoadPath(dir) catch {};
                    const max_file_size = 10 * 1024 * 1024;
                    const file_bytes = std.fs.cwd().readFileAlloc(infra_alloc, f, max_file_size) catch {
                        _ = stderr_file.write("Error: could not read file\n") catch {};
                        std.process.exit(1);
                    };
                    defer infra_alloc.free(file_bytes);
                    err.setSourceFile(f);
                    err.setSourceText(file_bytes);
                    runner.evalAndPrint(gc_alloc, infra_alloc, gc, file_bytes, use_vm, dump_bytecode, .file);
                } else {
                    runner.runRepl(gc_alloc, &env2, gc);
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
                        const file_bytes = std.fs.cwd().readFileAlloc(infra_alloc, f, max_file_size) catch {
                            _ = stderr_file.write("Error: could not read file\n") catch {};
                            std.process.exit(1);
                        };
                        defer infra_alloc.free(file_bytes);
                        err.setSourceFile(f);
                        err.setSourceText(file_bytes);
                        runner.evalAndPrint(gc_alloc, infra_alloc, gc, file_bytes, use_vm, dump_bytecode, .file);
                        return;
                    }
                    _ = stderr_file.write("Error: -M requires -m <namespace> or a file argument\n") catch {};
                    std.process.exit(1);
                };
                runner.runMainNs(gc_alloc, infra_alloc, gc, ns, use_vm);
                return;
            },
            .exec_mode => {
                // -X: Exec mode — invoke a function
                const fn_name = exec_fn_arg orelse resolved.exec_fn orelse {
                    _ = stderr_file.write("Error: -X requires a function name\n") catch {};
                    std.process.exit(1);
                };
                runner.runExecFn(gc_alloc, infra_alloc, gc, fn_name, exec_extra_args[0..exec_extra_count], resolved.exec_args, use_vm);
                return;
            },
            .normal => unreachable,
        }
    }

    // Standard mode (no deps.edn flags)
    const config = if (deps_config_opt) |dc| blk: {
        // deps.edn found — convert to ProjectConfig
        break :blk projectConfigFromDepsConfig(config_alloc, dc);
    } else blk: {
        // No deps.edn — check for project.clj
        warnIfLeinProject(".");
        break :blk ProjectConfig{};
    };
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
        runner.evalAndPrint(gc_alloc, infra_alloc, gc, e, use_vm, dump_bytecode, .expr);
    } else if (file) |f| {
        // Add entry file's directory and detect src/ for require resolution
        const dir = std.fs.path.dirname(f) orelse ".";
        ns_ops.addLoadPath(dir) catch {};
        ns_ops.detectAndAddSrcPath(dir) catch {};

        const max_file_size = 10 * 1024 * 1024; // 10MB
        const file_bytes = std.fs.cwd().readFileAlloc(infra_alloc, f, max_file_size) catch {
            const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: could not read file (max 10MB)\n") catch {};
            std.process.exit(1);
        };
        defer infra_alloc.free(file_bytes);

        err.setSourceFile(f);
        err.setSourceText(file_bytes);
        runner.evalAndPrint(gc_alloc, infra_alloc, gc, file_bytes, use_vm, dump_bytecode, .file);
    } else if (config.main_ns) |main_ns| {
        // deps.edn :cljw/main — load the main namespace
        runner.runMainNs(gc_alloc, infra_alloc, gc, main_ns, use_vm);
    } else {
        // No args, no file, no :main — start REPL
        var env2 = Env.init(infra_alloc);
        defer env2.deinit();
        runner.bootstrapFromCache(gc_alloc, &env2, gc);
        runner.runRepl(gc_alloc, &env2, gc);
    }
}

// === Project scaffolding ===

/// Handle `cljw new <project-name>` subcommand.
/// Creates a new project directory with deps.edn, src/, and test/ scaffolding.
pub fn handleNewCommand(new_args: []const [:0]const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    if (new_args.len == 0) {
        _ = stderr.write("Usage: cljw new <project-name>\n") catch {};
        std.process.exit(1);
    }

    const project_name = new_args[0];

    // Validate project name (alphanumeric, hyphens, underscores)
    for (project_name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') {
            _ = stderr.write("Error: invalid project name (use alphanumeric, hyphens, underscores)\n") catch {};
            std.process.exit(1);
        }
    }

    // Convert project name to namespace: hyphens -> underscores for dirs/files
    var ns_name_buf: [256]u8 = undefined;
    const ns_name = blk: {
        if (project_name.len > ns_name_buf.len) {
            _ = stderr.write("Error: project name too long\n") catch {};
            std.process.exit(1);
        }
        @memcpy(ns_name_buf[0..project_name.len], project_name);
        // Namespace uses hyphens (Clojure convention), file path uses underscores
        break :blk ns_name_buf[0..project_name.len];
    };

    var file_name_buf: [256]u8 = undefined;
    const file_name = blk: {
        @memcpy(file_name_buf[0..project_name.len], project_name);
        // Replace hyphens with underscores for file paths
        for (file_name_buf[0..project_name.len]) |*c| {
            if (c.* == '-') c.* = '_';
        }
        break :blk file_name_buf[0..project_name.len];
    };

    // Create project directory
    std.fs.cwd().makeDir(project_name) catch |e| {
        if (e == error.PathAlreadyExists) {
            _ = stderr.write("Error: directory already exists\n") catch {};
        } else {
            _ = stderr.write("Error creating directory\n") catch {};
        }
        std.process.exit(1);
    };

    var project_dir = std.fs.cwd().openDir(project_name, .{}) catch {
        _ = stderr.write("Error: cannot open project directory\n") catch {};
        std.process.exit(1);
    };
    defer project_dir.close();

    // Create subdirectories
    project_dir.makePath("src") catch {};
    project_dir.makePath("test") catch {};

    // Write deps.edn
    {
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        w.print("{{:paths [\"src\"]\n :deps {{}}\n :aliases\n {{:test {{:extra-paths [\"test\"]}}}}}}\n", .{}) catch {};
        project_dir.writeFile(.{ .sub_path = "deps.edn", .data = stream.getWritten() }) catch {};
    }

    // Write src/<file_name>.clj
    {
        var path_buf: [512]u8 = undefined;
        var path_stream = std.io.fixedBufferStream(&path_buf);
        path_stream.writer().print("src/{s}.clj", .{file_name}) catch {};
        const src_path = path_stream.getWritten();

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        w.print("(ns {s})\n\n(defn -main [& args]\n  (println \"Hello from {s}!\"))\n", .{ ns_name, ns_name }) catch {};
        project_dir.writeFile(.{ .sub_path = src_path, .data = stream.getWritten() }) catch {};
    }

    // Write test/<file_name>_test.clj
    {
        var path_buf: [512]u8 = undefined;
        var path_stream = std.io.fixedBufferStream(&path_buf);
        path_stream.writer().print("test/{s}_test.clj", .{file_name}) catch {};
        const test_path = path_stream.getWritten();

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        w.print("(ns {s}-test\n  (:require [clojure.test :refer [deftest is testing run-tests]]\n            [{s} :refer :all]))\n\n(deftest greeting-test\n  (testing \"main function\"\n    (is (= 1 1))))\n\n(run-tests)\n", .{ ns_name, ns_name }) catch {};
        project_dir.writeFile(.{ .sub_path = test_path, .data = stream.getWritten() }) catch {};
    }

    {
        var msg_buf: [1024]u8 = undefined;
        var msg_stream = std.io.fixedBufferStream(&msg_buf);
        const w = msg_stream.writer();
        w.print("Project '{s}' created!\n\n  cd {s}\n  cljw -M -m {s}    # Run main\n  cljw test          # Run tests\n  cljw               # Start REPL\n", .{ project_name, project_name, ns_name }) catch {};
        _ = stdout.write(msg_stream.getWritten()) catch {};
    }
}

// === deps.edn support ===

pub const DepsEdnFile = struct {
    content: []const u8,
    dir: ?[]const u8, // directory containing deps.edn (null = CWD)
};

const Dep = struct {
    local_root: ?[]const u8 = null,
    git_url: ?[]const u8 = null,
    git_sha: ?[]const u8 = null,
    git_tag: ?[]const u8 = null,
};

const WasmDep = struct {
    name: []const u8,
    path: []const u8,
};

const ProjectConfig = struct {
    paths: []const []const u8 = &.{},
    deps: []const Dep = &.{},
    main_ns: ?[]const u8 = null,
    wasm_deps: []const WasmDep = &.{},
};

/// Search for deps.edn starting from dir, walking up to root.
pub fn findDepsEdnFile(allocator: Allocator, start_dir: ?[]const u8) ?DepsEdnFile {
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
                .git_url = src_dep.git_url orelse blk2: {
                    break :blk2 deps_mod.inferGitUrl(allocator, src_dep.name);
                },
                .git_sha = src_dep.git_sha,
                .git_tag = src_dep.git_tag,
            };
        }
        break :blk @as([]const Dep, d);
    } else @as([]const Dep, &.{});

    // Convert wasm deps
    const wasm_dep_count = deps_config.wasm_deps.len;
    const wasm_deps = if (wasm_dep_count > 0) blk: {
        const wd = allocator.alloc(WasmDep, wasm_dep_count) catch break :blk @as([]const WasmDep, &.{});
        for (deps_config.wasm_deps, 0..) |src_wd, idx| {
            wd[idx] = .{ .name = src_wd.name, .path = src_wd.path };
        }
        break :blk @as([]const WasmDep, wd);
    } else @as([]const WasmDep, &.{});

    return .{
        .paths = deps_config.paths,
        .deps = deps,
        .main_ns = deps_config.main_ns,
        .wasm_deps = wasm_deps,
    };
}

fn inferGitUrlFromName(allocator: Allocator, name: []const u8) ?[]const u8 {
    return deps_mod.inferGitUrl(allocator, name);
}

fn applyConfig(config: ProjectConfig, config_dir: ?[]const u8) void {
    // Apply paths from config (relative to config dir)
    for (config.paths) |path| {
        if (config_dir) |dir| {
            var buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
            ns_ops.addLoadPath(full) catch {};
        } else {
            ns_ops.addLoadPath(path) catch {};
        }
    }

    // Apply deps
    for (config.deps) |dep| {
        if (dep.local_root) |root| {
            resolveLocalDep(root, config_dir, false);
        } else if (dep.git_url != null and dep.git_sha != null) {
            resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, null, false, false, false);
        }
    }

    // Apply wasm deps
    if (enable_wasm) {
        for (config.wasm_deps) |wd| {
            var wasm_buf: [4096]u8 = undefined;
            const wasm_resolved = if (config_dir) |dir|
                std.fmt.bufPrint(&wasm_buf, "{s}/{s}", .{ dir, wd.path }) catch continue
            else
                wd.path;
            wasm_builtins.registerWasmDep(wd.name, wasm_resolved);
        }
    }
}

pub fn resolveLocalDep(root: []const u8, config_dir: ?[]const u8, resolve_deps: bool) void {
    var buf: [4096]u8 = undefined;
    const resolved_root = if (config_dir) |dir|
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, root }) catch return
    else
        root;

    // Add local dep's source paths
    ns_ops.addLoadPath(resolved_root) catch {};

    // Also try resolved_root/src
    var src_buf: [4096]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{resolved_root}) catch return;
    ns_ops.addLoadPath(src_path) catch {};

    // Recursively resolve deps from local dep's own deps.edn
    if (resolve_deps) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (readFileFromDir(alloc, resolved_root, "deps.edn")) |content| {
            const dep_config = deps_mod.parseDepsEdn(alloc, content);
            for (dep_config.paths) |path| {
                var path_buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ resolved_root, path }) catch continue;
                ns_ops.addLoadPath(full) catch {};
            }
            for (dep_config.deps) |dep| {
                if (dep.local_root) |lr| {
                    resolveLocalDep(lr, resolved_root, true);
                } else if (dep.git_url != null and dep.git_sha != null) {
                    resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, false, true, false);
                } else {
                    if (deps_mod.inferGitUrl(alloc, dep.name)) |inferred_url| {
                        if (dep.git_sha) |sha| {
                            resolveGitDep(inferred_url, sha, dep.git_tag, dep.deps_root, false, true, false);
                        }
                    }
                }
            }
        }
    }
}

fn warnIfLeinProject(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/project.clj", .{dir}) catch return;
    // Check if project.clj exists
    std.fs.cwd().access(path, .{}) catch return;
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    _ = stderr.write("Warning: Found project.clj but no deps.edn. ClojureWasm uses deps.edn for dependencies.\n") catch {};
    _ = stderr.write("  Run `cljw new <name>` to create a deps.edn project, or create deps.edn manually.\n") catch {};
}

pub fn resolveGitDep(url: []const u8, sha: []const u8, tag: ?[]const u8, deps_root: ?[]const u8, force: bool, resolve_deps: bool, allow_fetch: bool) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

    // Cache location: ~/.cljw/gitlibs/<sha-prefix>/<repo-name>
    const home = std.posix.getenv("HOME") orelse return;
    var dir_buf: [4096]u8 = undefined;

    // Extract repo name from URL (last path component, without .git)
    const repo_name = blk: {
        const trimmed = if (std.mem.endsWith(u8, url, ".git")) url[0 .. url.len - 4] else url;
        if (std.mem.lastIndexOf(u8, trimmed, "/")) |idx| {
            break :blk trimmed[idx + 1 ..];
        }
        break :blk trimmed;
    };

    // Use short SHA prefix for directory name
    const sha_prefix = if (sha.len > 8) sha[0..8] else sha;
    const cache_dir = std.fmt.bufPrint(&dir_buf, "{s}/.cljw/gitlibs/{s}/{s}", .{ home, sha_prefix, repo_name }) catch return;

    // Check if already cached
    if (!force) {
        if (std.fs.cwd().access(cache_dir, .{})) |_| {
            // Already cached — add to load path
            if (deps_root) |root| {
                var root_buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&root_buf, "{s}/{s}", .{ cache_dir, root }) catch return;
                ns_ops.addLoadPath(full) catch {};
                // Also try root/src
                var src_buf: [4096]u8 = undefined;
                const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{full}) catch return;
                ns_ops.addLoadPath(src_path) catch {};
            } else {
                ns_ops.addLoadPath(cache_dir) catch {};
                var src_buf: [4096]u8 = undefined;
                const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{cache_dir}) catch return;
                ns_ops.addLoadPath(src_path) catch {};
            }

            // Resolve transitive deps from cached dep's deps.edn
            if (resolve_deps) {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const dep_root = if (deps_root) |root| blk: {
                    var rb: [4096]u8 = undefined;
                    break :blk std.fmt.bufPrint(&rb, "{s}/{s}", .{ cache_dir, root }) catch cache_dir;
                } else cache_dir;
                if (readFileFromDir(alloc, dep_root, "deps.edn")) |content| {
                    const dep_config = deps_mod.parseDepsEdn(alloc, content);
                    for (dep_config.paths) |path| {
                        var path_buf: [4096]u8 = undefined;
                        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dep_root, path }) catch continue;
                        ns_ops.addLoadPath(full) catch {};
                    }
                    for (dep_config.deps) |dep| {
                        if (dep.local_root) |lr| {
                            resolveLocalDep(lr, dep_root, true);
                        } else if (dep.git_url != null and dep.git_sha != null) {
                            resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, false, true, false);
                        } else {
                            if (deps_mod.inferGitUrl(alloc, dep.name)) |inferred_url| {
                                if (dep.git_sha) |dep_sha| {
                                    resolveGitDep(inferred_url, dep_sha, dep.git_tag, dep.deps_root, false, true, false);
                                }
                            }
                        }
                    }
                }
            }
            return;
        } else |_| {}
    }

    if (!allow_fetch) {
        // Not cached and not allowed to fetch
        _ = stderr.write("Warning: git dependency not cached: ") catch {};
        _ = stderr.write(url) catch {};
        _ = stderr.write("\n  Run `cljw -P` to fetch dependencies.\n") catch {};
        return;
    }

    // Clone the repo
    _ = stderr.write("Fetching: ") catch {};
    _ = stderr.write(url) catch {};
    _ = stderr.write(" @ ") catch {};
    _ = stderr.write(sha) catch {};
    _ = stderr.write("\n") catch {};

    // Create parent directories
    var parent_buf: [4096]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/.cljw/gitlibs/{s}", .{ home, sha_prefix }) catch return;
    std.fs.cwd().makePath(parent_dir) catch {};

    // Clone and checkout specific SHA
    // Use a temp dir, then rename to final location
    var tmp_buf: [4096]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_buf, "{s}/.cljw/gitlibs/.tmp-{s}", .{ home, sha_prefix }) catch return;

    // Clean up any leftover tmp dir
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    // git clone --depth 1 (for tag) or full clone (for arbitrary sha)
    var clone_buf: [8192]u8 = undefined;
    const clone_cmd = if (tag) |t|
        std.fmt.bufPrint(&clone_buf, "git clone --depth 1 --branch {s} --single-branch {s} {s} 2>&1", .{ t, url, tmp_dir }) catch return
    else
        std.fmt.bufPrint(&clone_buf, "git clone {s} {s} 2>&1", .{ url, tmp_dir }) catch return;

    const clone_result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/sh", "-c", clone_cmd },
    }) catch {
        _ = stderr.write("Error: git clone failed\n") catch {};
        return;
    };
    defer std.heap.page_allocator.free(clone_result.stdout);
    defer std.heap.page_allocator.free(clone_result.stderr);

    if (clone_result.term.Exited != 0) {
        _ = stderr.write("Error: git clone failed: ") catch {};
        _ = stderr.write(clone_result.stderr) catch {};
        _ = stderr.write("\n") catch {};
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        return;
    }

    // Validate tag→SHA mapping if both are provided
    if (tag) |t| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (!validateGitTag(arena.allocator(), tmp_dir, t, sha)) {
            _ = stderr.write("Error: git tag '") catch {};
            _ = stderr.write(t) catch {};
            _ = stderr.write("' does not match SHA ") catch {};
            _ = stderr.write(sha) catch {};
            _ = stderr.write("\n") catch {};
            std.fs.cwd().deleteTree(tmp_dir) catch {};
            return;
        }
    }

    // Checkout specific SHA (if not already at it from tag clone)
    if (tag == null) {
        var checkout_buf: [8192]u8 = undefined;
        const checkout_cmd = std.fmt.bufPrint(&checkout_buf, "cd {s} && git checkout {s} 2>&1", .{ tmp_dir, sha }) catch return;
        const checkout_result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", checkout_cmd },
        }) catch {
            _ = stderr.write("Error: git checkout failed\n") catch {};
            std.fs.cwd().deleteTree(tmp_dir) catch {};
            return;
        };
        defer std.heap.page_allocator.free(checkout_result.stdout);
        defer std.heap.page_allocator.free(checkout_result.stderr);

        if (checkout_result.term.Exited != 0) {
            _ = stderr.write("Error: git checkout failed: ") catch {};
            _ = stderr.write(checkout_result.stderr) catch {};
            _ = stderr.write("\n") catch {};
            std.fs.cwd().deleteTree(tmp_dir) catch {};
            return;
        }
    }

    // Rename to final location
    std.fs.cwd().rename(tmp_dir, cache_dir) catch {
        // If target already exists (race condition), that's fine — use it
        std.fs.cwd().deleteTree(tmp_dir) catch {};
    };

    // Add to load path
    if (deps_root) |root| {
        var root_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&root_buf, "{s}/{s}", .{ cache_dir, root }) catch return;
        ns_ops.addLoadPath(full) catch {};
        var src_buf: [4096]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{full}) catch return;
        ns_ops.addLoadPath(src_path) catch {};
    } else {
        ns_ops.addLoadPath(cache_dir) catch {};
        var src_buf: [4096]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{cache_dir}) catch return;
        ns_ops.addLoadPath(src_path) catch {};
    }

    // Resolve transitive deps
    if (resolve_deps) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const dep_root = if (deps_root) |root| blk: {
            var rb: [4096]u8 = undefined;
            break :blk std.fmt.bufPrint(&rb, "{s}/{s}", .{ cache_dir, root }) catch cache_dir;
        } else cache_dir;
        if (readFileFromDir(alloc, dep_root, "deps.edn")) |content| {
            const dep_config = deps_mod.parseDepsEdn(alloc, content);
            for (dep_config.paths) |path| {
                var path_buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dep_root, path }) catch continue;
                ns_ops.addLoadPath(full) catch {};
            }
            for (dep_config.deps) |dep| {
                if (dep.local_root) |lr| {
                    resolveLocalDep(lr, dep_root, true);
                } else if (dep.git_url != null and dep.git_sha != null) {
                    resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, false, true, false);
                } else {
                    if (deps_mod.inferGitUrl(alloc, dep.name)) |inferred_url| {
                        if (dep.git_sha) |dep_sha| {
                            resolveGitDep(inferred_url, dep_sha, dep.git_tag, dep.deps_root, false, true, false);
                        }
                    }
                }
            }
        }
    }
}

fn validateGitTag(alloc: Allocator, repo_dir: []const u8, tag_name: []const u8, expected_sha: []const u8) bool {
    // Get the commit SHA that the tag points to
    // For annotated tags, we need to dereference: git rev-parse <tag>^{commit}
    var cmd_buf: [8192]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "cd {s} && git rev-parse {s}^{{commit}} 2>/dev/null || git rev-parse {s} 2>/dev/null", .{ repo_dir, tag_name, tag_name }) catch return false;

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/sh", "-c", cmd },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return false;

    const tag_sha = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (tag_sha.len == 0) return false;

    // Full SHA match
    if (std.mem.eql(u8, tag_sha, expected_sha)) return true;

    // Prefix match (short SHA in deps.edn)
    if (expected_sha.len < tag_sha.len and std.mem.startsWith(u8, tag_sha, expected_sha)) return true;
    if (tag_sha.len < expected_sha.len and std.mem.startsWith(u8, expected_sha, tag_sha)) return true;

    return false;
}
