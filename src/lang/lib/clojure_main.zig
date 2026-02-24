// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.main — Top-level main function for Clojure REPL and scripts.
//! Simple functions are Zig builtins; complex code (repl, ex-triage, ex-str,
//! macros) stays as evalString in bootstrap.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../engine/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const es = @import("../../engine/embedded_sources.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Implementation
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn str(allocator: Allocator, s: []const u8) Value {
    return Value.initString(allocator, @constCast(s));
}

/// (demunge fn-name) — identity, CW doesn't munge names
fn demungeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.EvalError;
    return args[0];
}

/// (root-cause t) — walks ex-cause chain
fn rootCauseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    var cause = args[0];
    while (true) {
        const c = try callCore(allocator, "ex-cause", &.{cause});
        if (!c.isTruthy()) return cause;
        cause = c;
    }
}

/// (stack-element-str el) — str conversion
fn stackElementStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    return callCore(allocator, "str", &.{args[0]});
}

/// (repl-prompt) — prints "ns=> "
fn replPromptFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.EvalError;
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const ns_var = core_ns.resolve("*ns*") orelse return error.EvalError;
    const current_ns = ns_var.deref();
    const ns_name = try callCore(allocator, "ns-name", &.{current_ns});
    _ = try callCore(allocator, "printf", &.{ str(allocator, "%s=> "), ns_name });
    return Value.nil_val;
}

/// (repl-read request-prompt request-exit) — reads from *in*
fn replReadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.EvalError;
    const request_exit = args[1];
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const in_var = core_ns.resolve("*in*") orelse return error.EvalError;
    const in_val = in_var.deref();
    // (read {:eof request-exit} *in*)
    const eof_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "eof" });
    const opts = try callCore(allocator, "hash-map", &.{ eof_kw, request_exit });
    return callCore(allocator, "read", &.{ opts, in_val });
}

/// (repl-exception throwable) — returns root cause
fn replExceptionFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    return rootCauseFn(allocator, args);
}

/// (err->msg e) — returns error message string
fn errMsgFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    const msg = try callCore(allocator, "ex-message", &.{args[0]});
    if (msg.isTruthy()) {
        return callCore(allocator, "str", &.{ str(allocator, "Execution error at REPL.\n"), msg, str(allocator, "\n") });
    }
    const e_str = try callCore(allocator, "str", &.{args[0]});
    return callCore(allocator, "str", &.{ str(allocator, "Execution error at REPL.\n"), e_str, str(allocator, "\n") });
}

/// (repl-caught e) — default :caught hook
fn replCaughtFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    const msg = try errMsgFn(allocator, args);
    // binding [*out* *err*] — just print to *err*
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const err_var = core_ns.resolve("*err*") orelse return error.EvalError;
    const out_var = core_ns.resolve("*out*") orelse return error.EvalError;
    const saved_out = out_var.deref();
    out_var.bindRoot(err_var.deref());
    _ = try callCore(allocator, "print", &.{msg});
    _ = try callCore(allocator, "flush", &.{});
    out_var.bindRoot(saved_out);
    return Value.nil_val;
}

/// (load-script path) — loads from file
fn loadScriptFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    return callCore(allocator, "load-file", &.{args[0]});
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "demunge", .func = &demungeFn, .doc = "Given a string representation of a fn class, returns a readable version." },
    .{ .name = "root-cause", .func = &rootCauseFn, .doc = "Returns the initial cause of an exception by peeling off wrappers." },
    .{ .name = "stack-element-str", .func = &stackElementStrFn, .doc = "Returns a string representation of a stack trace element." },
    .{ .name = "repl-prompt", .func = &replPromptFn, .doc = "Default :prompt hook for repl." },
    .{ .name = "repl-read", .func = &replReadFn, .doc = "Default :read hook for repl. Reads from *in*." },
    .{ .name = "repl-exception", .func = &replExceptionFn, .doc = "Returns the root cause of throwables." },
    .{ .name = "err->msg", .func = &errMsgFn, .doc = "Helper to return an error message string from an exception." },
    .{ .name = "repl-caught", .func = &replCaughtFn, .doc = "Default :caught hook for repl." },
    .{ .name = "load-script", .func = &loadScriptFn, .doc = "Loads Clojure source from a file given its path." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.main",
    .builtins = &builtins,
    .loading = .lazy,
    .embedded_source = es.main_macros_source,
};
