// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.process — Process invocation API.
//! Replaces clojure/java/process.clj.
//! CLJW: Synchronous execution via clojure.java.shell/sh. No ProcessBuilder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Implementation
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

/// (start & opts+args) — synchronous process execution via sh
fn startFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to start", .{args.len});

    // Parse: optional map first, then command args
    var opts = Value.nil_val;
    var cmd_start: usize = 0;
    if (args.len > 0 and (args[0].tag() == .hash_map or args[0].tag() == .map)) {
        opts = args[0];
        cmd_start = 1;
    }

    // Build sh args: command... [:dir dir]
    var sh_args = std.ArrayList(Value).empty;
    for (args[cmd_start..]) |a| {
        sh_args.append(allocator, a) catch return error.EvalError;
    }

    // Add :dir if present in opts
    if (opts.tag() != .nil) {
        const dir_key = Value.initKeyword(allocator, .{ .ns = null, .name = "dir" });
        const dir_val = try callCore(allocator, "get", &.{ opts, dir_key });
        if (dir_val.tag() != .nil) {
            sh_args.append(allocator, Value.initKeyword(allocator, .{ .ns = null, .name = "dir" })) catch return error.EvalError;
            sh_args.append(allocator, dir_val) catch return error.EvalError;
        }
    }

    return callCore(allocator, "apply", &.{ try resolveShellFn(allocator, "sh"), try callCore(allocator, "seq", &.{try buildList(allocator, sh_args.items)}) });
}

fn resolveShellFn(allocator: Allocator, name: []const u8) !Value {
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    var shell_ns = env.findNamespace("clojure.java.shell");
    if (shell_ns == null) {
        const require_sym = Value.initSymbol(allocator, .{ .ns = null, .name = "clojure.java.shell" });
        _ = try callCore(allocator, "require", &.{require_sym});
        shell_ns = env.findNamespace("clojure.java.shell");
    }
    const ns = shell_ns orelse return error.EvalError;
    const v = ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

fn buildList(allocator: Allocator, items: []const Value) !Value {
    var result: Value = Value.nil_val;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try callCore(allocator, "cons", &.{ items[i], result });
    }
    return result;
}

/// (stdout process) — return :out from process result
fn stdoutFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stdout", .{args.len});
    return callCore(allocator, "get", &.{ args[0], Value.initKeyword(allocator, .{ .ns = null, .name = "out" }) });
}

/// (stderr process) — return :err from process result
fn stderrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stderr", .{args.len});
    return callCore(allocator, "get", &.{ args[0], Value.initKeyword(allocator, .{ .ns = null, .name = "err" }) });
}

/// (exit-ref process) — return a delay wrapping the exit code
fn exitRefFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to exit-ref", .{args.len});
    const exit_val = try callCore(allocator, "get", &.{ args[0], Value.initKeyword(allocator, .{ .ns = null, .name = "exit" }) });
    // Create an already-realized delay
    const delay = try allocator.create(value_mod.Delay);
    delay.* = .{
        .realized = true,
        .cached = exit_val,
    };
    return Value.initDelay(delay);
}

/// (exec & opts+args) — execute and return stdout, or throw on failure
fn execFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const proc = try startFn(allocator, args);
    const exit_val = try callCore(allocator, "get", &.{ proc, Value.initKeyword(allocator, .{ .ns = null, .name = "exit" }) });
    const is_zero = try callCore(allocator, "zero?", &.{exit_val});
    if (is_zero.isTruthy()) {
        return callCore(allocator, "get", &.{ proc, Value.initKeyword(allocator, .{ .ns = null, .name = "out" }) });
    }
    // Throw on non-zero exit
    return err.setErrorFmt(.eval, .value_error, .{}, "Process failed with exit={d}", .{exit_val.asInteger()});
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "start", .func = &startFn, .doc = "Start an external command. Returns a process result map with :exit, :out, :err." },
    .{ .name = "stdout", .func = &stdoutFn, .doc = "Given a process result, return the stdout output string." },
    .{ .name = "stderr", .func = &stderrFn, .doc = "Given a process result, return the stderr output string." },
    .{ .name = "exit-ref", .func = &exitRefFn, .doc = "Given a process result, return a reference that can be deref'd to get the exit value." },
    .{ .name = "exec", .func = &execFn, .doc = "Execute a command and on successful exit, return the captured output, else throw." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.process",
    .builtins = &builtins,
};
