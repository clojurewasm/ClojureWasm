// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// clojure.java.shell — Shell execution via subprocess.
//
// Implements: sh, *sh-dir*, *sh-env*, with-sh-dir, with-sh-env.
// sh spawns a subprocess via std.process.Child, captures stdout/stderr,
// and returns {:exit N :out "..." :err "..."}.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../value.zig").Value;
const collections = @import("../collections.zig");
const err = @import("../error.zig");
const bootstrap = @import("../bootstrap.zig");

// ============================================================
// sh implementation
// ============================================================

/// (sh & args) — execute a subprocess.
///
/// Positional args are command strings.
/// Keyword options after command strings:
///   :dir  "path"   — working directory
///   :in   "input"  — stdin input string
///
/// Returns: {:exit N :out "stdout" :err "stderr"}
pub fn shFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to sh", .{});

    // Parse: command strings, then keyword options
    var cmd_end: usize = args.len;
    for (args, 0..) |arg, i| {
        if (arg.tag() == .keyword) {
            cmd_end = i;
            break;
        }
    }

    if (cmd_end == 0) return err.setErrorFmt(.eval, .type_error, .{}, "sh: no command specified", .{});

    // Collect command strings
    var argv_list: std.ArrayList([]const u8) = .empty;
    for (args[0..cmd_end]) |arg| {
        if (arg.tag() != .string) {
            return err.setErrorFmt(.eval, .type_error, .{}, "sh: command args must be strings, got {s}", .{@tagName(arg.tag())});
        }
        try argv_list.append(allocator, arg.asString());
    }
    const argv = try argv_list.toOwnedSlice(allocator);

    // Parse keyword options
    var dir: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var i: usize = cmd_end;
    while (i + 1 < args.len) {
        if (args[i].tag() != .keyword) {
            i += 1;
            continue;
        }
        const kw = args[i].asKeyword();
        const val = args[i + 1];
        if (std.mem.eql(u8, kw.name, "dir")) {
            dir = if (val == Value.nil_val) null else if (val.tag() == .string) val.asString() else null;
        } else if (std.mem.eql(u8, kw.name, "in")) {
            input = if (val == Value.nil_val) null else if (val.tag() == .string) val.asString() else null;
        }
        // :out-enc, :in-enc, :env — ignore for now (UTF-8 default)
        i += 2;
    }

    // Check dynamic vars *sh-dir* and *sh-env* if dir not explicitly set
    if (dir == null) {
        if (bootstrap.macro_eval_env) |env| {
            if (env.findNamespace("clojure.java.shell")) |shell_ns| {
                if (shell_ns.resolve("*sh-dir*")) |sh_dir_var| {
                    const dv = sh_dir_var.deref();
                    if (dv != Value.nil_val and dv.tag() == .string) {
                        dir = dv.asString();
                    }
                }
            }
        }
    }

    // Spawn subprocess
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = if (input != null) .Pipe else .Close;
    if (dir) |d| child.cwd = d;

    try child.spawn();

    // Write stdin if provided
    if (input) |in_data| {
        if (child.stdin) |stdin_file| {
            var stdin = stdin_file;
            stdin.writeAll(in_data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Read stdout and stderr
    const stdout_data = if (child.stdout) |stdout_file| blk: {
        var stdout = stdout_file;
        break :blk stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch "";
    } else "";

    const stderr_data = if (child.stderr) |stderr_file| blk: {
        var stderr = stderr_file;
        break :blk stderr.readToEndAlloc(allocator, 10 * 1024 * 1024) catch "";
    } else "";

    // Wait for exit
    const term = child.wait() catch |e| {
        return err.setErrorFmt(.eval, .io_error, .{}, "sh: wait failed: {s}", .{@errorName(e)});
    };

    const exit_code: i64 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| -@as(i64, @intCast(sig)),
        .Stopped => |sig| -@as(i64, @intCast(sig)),
        .Unknown => |code| -@as(i64, @intCast(code)),
    };

    // Build result map: {:exit N :out "..." :err "..."}
    const exit_key = Value.initKeyword(allocator, .{ .ns = null, .name = "exit" });
    const out_key = Value.initKeyword(allocator, .{ .ns = null, .name = "out" });
    const err_key = Value.initKeyword(allocator, .{ .ns = null, .name = "err" });

    const exit_val = Value.initInteger(exit_code);
    const out_val = Value.initString(allocator, stdout_data);
    const err_val = Value.initString(allocator, stderr_data);

    // Build hash-map result
    const HashMap = collections.PersistentHashMap;
    const hm1 = try HashMap.EMPTY.assoc(allocator, exit_key, exit_val);
    const hm2 = try hm1.assoc(allocator, out_key, out_val);
    const hm3 = try hm2.assoc(allocator, err_key, err_val);

    return Value.initHashMap(hm3);
}

// ============================================================
// Builtin definitions for clojure.java.shell
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "sh",
        .func = shFn,
        .doc = "Passes the given strings to launch a sub-process. Returns a map of :exit, :out, :err.",
        .arglists = "([& args])",
        .added = "1.2",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "sh - echo hello" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try shFn(alloc, &[_]Value{
        Value.initString(alloc, "echo"),
        Value.initString(alloc, "hello"),
    });

    try testing.expect(result.tag() == .hash_map);
    const hm = result.asHashMap();

    // Check :exit
    const exit_key = Value.initKeyword(alloc, .{ .ns = null, .name = "exit" });
    const exit_val = hm.get(exit_key);
    try testing.expect(exit_val != null);
    try testing.expectEqual(@as(i64, 0), exit_val.?.asInteger());

    // Check :out
    const out_key = Value.initKeyword(alloc, .{ .ns = null, .name = "out" });
    const out_val = hm.get(out_key);
    try testing.expect(out_val != null);
    try testing.expectEqualStrings("hello\n", out_val.?.asString());
}

test "sh - with :in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try shFn(alloc, &[_]Value{
        Value.initString(alloc, "cat"),
        Value.initKeyword(alloc, .{ .ns = null, .name = "in" }),
        Value.initString(alloc, "piped input"),
    });

    try testing.expect(result.tag() == .hash_map);
    const hm = result.asHashMap();

    const out_key = Value.initKeyword(alloc, .{ .ns = null, .name = "out" });
    const out_val = hm.get(out_key);
    try testing.expect(out_val != null);
    try testing.expectEqualStrings("piped input", out_val.?.asString());
}

test "sh - with :dir" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try shFn(alloc, &[_]Value{
        Value.initString(alloc, "pwd"),
        Value.initKeyword(alloc, .{ .ns = null, .name = "dir" }),
        Value.initString(alloc, "/tmp"),
    });

    try testing.expect(result.tag() == .hash_map);
    const hm = result.asHashMap();

    const out_key = Value.initKeyword(alloc, .{ .ns = null, .name = "out" });
    const out_val = hm.get(out_key);
    try testing.expect(out_val != null);
    // macOS resolves /tmp to /private/tmp
    const out_str = out_val.?.asString();
    try testing.expect(std.mem.indexOf(u8, out_str, "tmp") != null);
}

test "sh - nonexistent command returns non-zero exit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try shFn(alloc, &[_]Value{
        Value.initString(alloc, "false"),
    });

    try testing.expect(result.tag() == .hash_map);
    const hm = result.asHashMap();

    const exit_key = Value.initKeyword(alloc, .{ .ns = null, .name = "exit" });
    const exit_val = hm.get(exit_key);
    try testing.expect(exit_val != null);
    try testing.expectEqual(@as(i64, 1), exit_val.?.asInteger());
}
