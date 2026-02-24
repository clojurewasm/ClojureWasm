// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Test runner: `cljw test` subcommand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("../runtime/env.zig").Env;
const bootstrap = @import("../engine/bootstrap.zig");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const deps_mod = @import("deps.zig");
const ns_ops = @import("../lang/builtins/ns_ops.zig");
const err = @import("../runtime/error.zig");
const gc_mod = @import("../runtime/gc.zig");
const wasm_builtins = @import("../lang/lib/cljw_wasm_builtins.zig");
const thread_pool = @import("../runtime/thread_pool.zig");
const runner = @import("runner.zig");
const cli = @import("cli.zig");

const build_options = @import("build_options");
const enable_wasm = build_options.enable_wasm;

/// Handle `cljw test [-A:alias] [file.clj ...]` subcommand.
/// If specific files are given, loads and runs tests from those files.
/// Otherwise, searches :test-paths (or "test/") for .clj files and runs all tests.
/// Supports -A:alias for extra paths/deps via deps.edn aliases.
pub fn handleTestCommand(gc_alloc: Allocator, infra_alloc: Allocator, gc: *gc_mod.MarkSweepGc, test_args: []const [:0]const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Parse test subcommand flags: -A:alias, --tree-walk, and file paths
    var test_alias_str: ?[]const u8 = null;
    var test_file_args: [64][]const u8 = undefined;
    var test_file_count: usize = 0;
    for (test_args) |arg| {
        if (std.mem.startsWith(u8, arg, "-A")) {
            test_alias_str = arg[2..]; // ":dev" or ":dev:test"
        } else {
            if (test_file_count < test_file_args.len) {
                test_file_args[test_file_count] = arg;
                test_file_count += 1;
            }
        }
    }

    // Load config: deps.edn
    var config_arena = std.heap.ArenaAllocator.init(infra_alloc);
    defer config_arena.deinit();
    const config_alloc = config_arena.allocator();
    var test_config_dir: ?[]const u8 = null;

    // Try deps.edn first
    const deps_config_opt: ?deps_mod.DepsConfig = if (cli.findDepsEdnFile(config_alloc, null)) |cf| blk: {
        test_config_dir = cf.dir;
        break :blk deps_mod.parseDepsEdn(config_alloc, cf.content);
    } else null;

    var test_paths_from_config: []const []const u8 = &.{};

    if (deps_config_opt) |dc| {
        // Apply deps.edn config with optional alias
        const alias_names = if (test_alias_str) |as_| deps_mod.parseAliasString(config_alloc, as_) else &[_][]const u8{};
        const resolved = deps_mod.resolveAliases(config_alloc, dc, alias_names);

        // Print warnings
        for (resolved.warnings) |warning| {
            _ = stderr.write(warning) catch {};
            _ = stderr.write("\n") catch {};
        }

        // Apply paths
        for (resolved.paths) |path| {
            if (test_config_dir) |dir| {
                var buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, path }) catch continue;
                ns_ops.addLoadPath(full) catch {};
            } else {
                ns_ops.addLoadPath(path) catch {};
            }
        }

        // Apply deps
        for (resolved.deps) |dep| {
            if (dep.local_root) |root| {
                cli.resolveLocalDep(root, test_config_dir, true);
            } else if (dep.git_url != null and dep.git_sha != null) {
                cli.resolveGitDep(dep.git_url.?, dep.git_sha.?, dep.git_tag, dep.deps_root, false, true, false);
            } else {
                if (deps_mod.inferGitUrl(config_alloc, dep.name)) |inferred_url| {
                    if (dep.git_sha) |sha| {
                        cli.resolveGitDep(inferred_url, sha, dep.git_tag, dep.deps_root, false, true, false);
                    }
                }
            }
        }

        // Apply wasm deps
        if (enable_wasm) {
            for (resolved.wasm_deps) |wd| {
                var wasm_buf: [4096]u8 = undefined;
                const wasm_resolved = if (test_config_dir) |dir|
                    std.fmt.bufPrint(&wasm_buf, "{s}/{s}", .{ dir, wd.path }) catch continue
                else
                    wd.path;
                wasm_builtins.registerWasmDep(wd.name, wasm_resolved);
            }
        }

        test_paths_from_config = resolved.test_paths;
    } else {
        // No deps.edn — no config to apply
    }

    // Arena for test file paths and source buffers (survives until function exit).
    var file_arena = std.heap.ArenaAllocator.init(infra_alloc);
    defer file_arena.deinit();
    const file_alloc = file_arena.allocator();

    // Collect test files
    var test_files: std.ArrayList([]const u8) = .empty;
    defer test_files.deinit(infra_alloc);

    if (test_file_count > 0) {
        // Specific files provided
        for (test_file_args[0..test_file_count]) |arg| {
            test_files.append(infra_alloc, arg) catch {};
        }
    } else {
        // Search test directories for .clj files
        const search_paths = if (test_paths_from_config.len > 0) test_paths_from_config else &[_][]const u8{"test"};
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

        // Fresh env per test file to prevent state pollution (I-001).
        // defmethod, derive, protocol extensions, atom mutations all live in Env.
        // Without isolation, tests that pass individually fail in batch.
        thread_pool.shutdownGlobalPool(); // join background threads before env teardown
        ns_ops.resetLoadedLibs();
        var file_env = Env.init(infra_alloc);
        defer file_env.deinit();
        runner.bootstrapFromCache(gc_alloc, &file_env, gc);

        err.setSourceFile(tf);
        err.setSourceText(file_bytes);
        const result = bootstrap.evalStringVM(gc_alloc, &file_env, file_bytes) catch |e| {
            runner.reportError(e);
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
/// Skips directories not suitable for `cljw test` (e2e, compat, etc.).
fn collectTestFiles(str_alloc: Allocator, list_alloc: Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const skip_dirs = [_][]const u8{ "e2e", "compat", "diff", "wasm" };

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".clj")) {
            const full = std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            out.append(list_alloc, full) catch {};
        } else if (entry.kind == .directory) {
            var skip = false;
            for (&skip_dirs) |sd| {
                if (std.mem.eql(u8, entry.name, sd)) {
                    skip = true;
                    break;
                }
            }
            if (!skip) {
                const subdir = std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                collectTestFiles(str_alloc, list_alloc, subdir, out);
            }
        }
    }
}
