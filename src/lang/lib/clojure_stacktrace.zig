// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.stacktrace — print Clojure-centric stack traces.
//! Replaces clojure/stacktrace.clj.
//! UPSTREAM-DIFF: Simplified for CW error model (no Java Throwable/StackTraceElement).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../engine/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
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

/// (root-cause tr) — Returns the last 'cause' Throwable in a chain.
fn rootCauseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to root-cause", .{args.len});
    var tr = args[0];
    while (true) {
        const cause = try callCore(allocator, "ex-cause", &.{tr});
        if (cause.tag() == .nil) return tr;
        tr = cause;
    }
}

/// (print-trace-element e) — Prints a Clojure-oriented view of one stack trace element.
fn printTraceElementFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to print-trace-element", .{args.len});
    const e = args[0];
    const sym = try callCore(allocator, "str", &.{try callCore(allocator, "nth", &.{ e, Value.initInteger(0) })});
    const file = try callCore(allocator, "str", &.{try callCore(allocator, "nth", &.{ e, Value.initInteger(1) })});
    const line = try callCore(allocator, "nth", &.{ e, Value.initInteger(2) });
    _ = try callCore(allocator, "printf", &.{ Value.initString(allocator, "%s (%s:%s)"), sym, file, line });
    return Value.nil_val;
}

/// (print-throwable tr) — Prints the class and message of a Throwable.
fn printThrowableFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to print-throwable", .{args.len});
    const tr = args[0];
    const m = try callCore(allocator, "Throwable->map", &.{tr});
    const cause_key = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
    const cause_val = try callCore(allocator, "get", &.{ m, cause_key });
    const msg = if (cause_val.tag() != .nil) cause_val else try callCore(allocator, "str", &.{tr});
    _ = try callCore(allocator, "printf", &.{ Value.initString(allocator, "%s"), msg });
    const info = try callCore(allocator, "ex-data", &.{tr});
    if (info.tag() != .nil) {
        _ = try callCore(allocator, "println", &.{});
        _ = try callCore(allocator, "pr", &.{info});
    }
    return Value.nil_val;
}

/// (print-stack-trace tr) or (print-stack-trace tr n)
fn printStackTraceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to print-stack-trace", .{args.len});
    const tr = args[0];
    const n = if (args.len == 2) args[1] else Value.nil_val;

    const m = try callCore(allocator, "Throwable->map", &.{tr});
    const trace_key = Value.initKeyword(allocator, .{ .ns = null, .name = "trace" });
    const st = try callCore(allocator, "get", &.{ m, trace_key });

    _ = try printThrowableFn(allocator, &.{tr});
    _ = try callCore(allocator, "println", &.{});
    _ = try callCore(allocator, "print", &.{Value.initString(allocator, " at ")});

    const first_elem = try callCore(allocator, "first", &.{st});
    if (first_elem.tag() != .nil) {
        _ = try printTraceElementFn(allocator, &.{first_elem});
    } else {
        _ = try callCore(allocator, "print", &.{Value.initString(allocator, "[empty stack trace]")});
    }
    _ = try callCore(allocator, "println", &.{});

    const rest_st = try callCore(allocator, "rest", &.{st});
    const elements = if (n.tag() == .nil)
        rest_st
    else blk: {
        const dec_n = try callCore(allocator, "dec", &.{n});
        break :blk try callCore(allocator, "take", &.{ dec_n, rest_st });
    };

    var seq = try callCore(allocator, "seq", &.{elements});
    while (seq.tag() != .nil) {
        _ = try callCore(allocator, "print", &.{Value.initString(allocator, "    ")});
        const e = try callCore(allocator, "first", &.{seq});
        _ = try printTraceElementFn(allocator, &.{e});
        _ = try callCore(allocator, "println", &.{});
        seq = try callCore(allocator, "next", &.{seq});
        if (seq.tag() == .nil) break;
    }
    return Value.nil_val;
}

/// (print-cause-trace tr) or (print-cause-trace tr n)
fn printCauseTraceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to print-cause-trace", .{args.len});
    const n = if (args.len == 2) args[1] else Value.nil_val;
    var tr = args[0];

    while (true) {
        if (n.tag() == .nil) {
            _ = try printStackTraceFn(allocator, &.{tr});
        } else {
            _ = try printStackTraceFn(allocator, &.{ tr, n });
        }
        const cause = try callCore(allocator, "ex-cause", &.{tr});
        if (cause.tag() == .nil) break;
        _ = try callCore(allocator, "print", &.{Value.initString(allocator, "Caused by: ")});
        tr = cause;
    }
    return Value.nil_val;
}

/// (e) — REPL utility. Prints a brief stack trace for the root cause of *e.
fn eFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to e", .{args.len});
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const star_e_var = core_ns.mappings.get("*e") orelse return Value.nil_val;
    const star_e = star_e_var.deref();
    if (star_e.tag() == .nil) return Value.nil_val;
    const root = try rootCauseFn(allocator, &.{star_e});
    return printStackTraceFn(allocator, &.{ root, Value.initInteger(8) });
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "root-cause", .func = &rootCauseFn, .doc = "Returns the last 'cause' Throwable in a chain of Throwables." },
    .{ .name = "print-trace-element", .func = &printTraceElementFn, .doc = "Prints a Clojure-oriented view of one element in a stack trace." },
    .{ .name = "print-throwable", .func = &printThrowableFn, .doc = "Prints the class and message of a Throwable. Prints the ex-data map if present." },
    .{ .name = "print-stack-trace", .func = &printStackTraceFn, .doc = "Prints a Clojure-oriented stack trace of tr, a Throwable. Prints a maximum of n stack frames (default: unlimited)." },
    .{ .name = "print-cause-trace", .func = &printCauseTraceFn, .doc = "Like print-stack-trace but prints chained exceptions (causes)." },
    .{ .name = "e", .func = &eFn, .doc = "REPL utility. Prints a brief stack trace for the root cause of the most recent exception." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.stacktrace",
    .builtins = &builtins,
};
