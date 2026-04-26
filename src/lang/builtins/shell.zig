// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! clojure.java.shell — Shell execution via subprocess.
//!
//! Implements: sh, *sh-dir*, *sh-env*, with-sh-dir, with-sh-env.
//! sh spawns a subprocess via std.process.Child, captures stdout/stderr,
//! and returns {:exit N :out "..." :err "..."}.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../../runtime/value.zig").Value;
const collections = @import("../../runtime/collections.zig");
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../engine/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const io_default = @import("../../runtime/io_default.zig");

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
        if (dispatch.macro_eval_env) |env| {
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

    // Spawn subprocess via std.process.run (collects stdout+stderr+wait in one call).
    // For input mode, std.process.spawn is used so we can write stdin manually.
    const proc_io = io_default.get();
    var stdout_data: []u8 = "";
    var stderr_data: []u8 = "";
    var term: std.process.Child.Term = .{ .exited = 0 };

    if (input) |in_data| {
        var child = try std.process.spawn(proc_io, .{
            .argv = argv,
            .cwd = if (dir) |d| .{ .path = d } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        if (child.stdin) |stdin_file| {
            stdin_file.writeStreamingAll(proc_io, in_data) catch {};
            stdin_file.close(proc_io);
            child.stdin = null;
        }
        if (child.stdout) |stdout_file| {
            var rbuf: [4096]u8 = undefined;
            var r = stdout_file.reader(proc_io, &rbuf);
            stdout_data = r.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch "";
        }
        if (child.stderr) |stderr_file| {
            var rbuf: [4096]u8 = undefined;
            var r = stderr_file.reader(proc_io, &rbuf);
            stderr_data = r.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch "";
        }
        term = child.wait(proc_io) catch |e| {
            return err.setErrorFmt(.eval, .io_error, .{}, "sh: wait failed: {s}", .{@errorName(e)});
        };
    } else {
        const result = std.process.run(allocator, proc_io, .{
            .argv = argv,
            .cwd = if (dir) |d| .{ .path = d } else .inherit,
            .stdout_limit = .limited(10 * 1024 * 1024),
            .stderr_limit = .limited(10 * 1024 * 1024),
        }) catch |e| {
            return err.setErrorFmt(.eval, .io_error, .{}, "sh: spawn failed: {s}", .{@errorName(e)});
        };
        stdout_data = result.stdout;
        stderr_data = result.stderr;
        term = result.term;
    }

    const exit_code: i64 = switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i64, @intCast(@intFromEnum(sig))),
        .stopped => |sig| -@as(i64, @intCast(@intFromEnum(sig))),
        .unknown => |code| -@as(i64, @intCast(code)),
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
// Macros: with-sh-dir, with-sh-env
// ============================================================

/// (with-sh-dir dir & forms) → (binding [clojure.java.shell/*sh-dir* dir] forms...)
pub fn withShDirMacro(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "with-sh-dir requires at least 1 argument", .{});

    return buildBindingMacro(allocator, "*sh-dir*", args);
}

/// (with-sh-env env & forms) → (binding [clojure.java.shell/*sh-env* env] forms...)
pub fn withShEnvMacro(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "with-sh-env requires at least 1 argument", .{});

    return buildBindingMacro(allocator, "*sh-env*", args);
}

/// Helper: build (binding [clojure.java.shell/<var-name> <val>] <body...>)
fn buildBindingMacro(allocator: Allocator, var_name: []const u8, args: []const Value) anyerror!Value {
    const PersistentList = collections.PersistentList;
    const PersistentVector = collections.PersistentVector;

    // Build binding vector: [clojure.java.shell/*sh-dir* dir-arg]
    const binding_items = try allocator.alloc(Value, 2);
    binding_items[0] = Value.initSymbol(allocator, .{ .ns = "clojure.java.shell", .name = var_name });
    binding_items[1] = args[0];
    const binding_vec = try allocator.create(PersistentVector);
    binding_vec.* = .{ .items = binding_items };

    // Build (binding [bindings...] body...)
    // Total: binding sym + vector + body forms
    const list_items = try allocator.alloc(Value, 2 + args.len - 1);
    list_items[0] = Value.initSymbol(allocator, .{ .ns = null, .name = "binding" });
    list_items[1] = Value.initVector(binding_vec);
    for (args[1..], 0..) |body_form, i| {
        list_items[2 + i] = body_form;
    }
    const result_list = try allocator.create(PersistentList);
    result_list.* = .{ .items = list_items };
    return Value.initList(result_list);
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

/// Macro definitions (registered separately with setMacro)
pub const with_sh_dir_def = BuiltinDef{
    .name = "with-sh-dir",
    .func = withShDirMacro,
    .doc = "Sets the directory for use with sh, see sh for details.",
    .arglists = "([dir & forms])",
    .added = "1.2",
};

pub const with_sh_env_def = BuiltinDef{
    .name = "with-sh-env",
    .func = withShEnvMacro,
    .doc = "Sets the environment for use with sh, see sh for details.",
    .arglists = "([env & forms])",
    .added = "1.2",
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Test helper: set up a real std.Io.Threaded and install it as the default
/// io for the duration of the calling test. The default io_default points
/// at `std.Io.Threaded.init_single_threaded`, whose allocator is `.failing`
/// — fine for mutex-only paths but not for `std.process.spawn`, which needs
/// to allocate Future closures.
fn setupTestIo(alloc: Allocator, threaded: *std.Io.Threaded) void {
    threaded.* = std.Io.Threaded.init(alloc, .{});
    io_default.set(threaded.io());
}

test "sh - echo hello" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var th: std.Io.Threaded = undefined;
    setupTestIo(alloc, &th);
    defer th.deinit();

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
    var th: std.Io.Threaded = undefined;
    setupTestIo(alloc, &th);
    defer th.deinit();

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
    var th: std.Io.Threaded = undefined;
    setupTestIo(alloc, &th);
    defer th.deinit();

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
    var th: std.Io.Threaded = undefined;
    setupTestIo(alloc, &th);
    defer th.deinit();

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
