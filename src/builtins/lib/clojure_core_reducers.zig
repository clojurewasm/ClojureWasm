// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.reducers — ForkJoin stubs and utilities.
//! Builtins registered eagerly; protocols/macros/reify loaded via evalString.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const es = @import("../../runtime/embedded_sources.zig");
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

/// (fjtask f) — identity, CW has no ForkJoinTask
fn fjtaskFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.EvalError;
    return args[0];
}

/// (fjinvoke f) — sequential: just call f
fn fjinvokeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    return bootstrap.callFnVal(allocator, args[0], &.{});
}

/// (fjfork task) — no-op: sequential
fn fjforkFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.EvalError;
    return args[0];
}

/// (fjjoin task) — sequential: just call task
fn fjjoinFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.EvalError;
    return bootstrap.callFnVal(allocator, args[0], &.{});
}

/// (append! acc x) — conj wrapper
fn appendFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.EvalError;
    return callCore(allocator, "conj", &.{ args[0], args[1] });
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "fjtask", .func = &fjtaskFn, .doc = "Coerces f into a ForkJoinTask (identity in CW)." },
    .{ .name = "fjinvoke", .func = &fjinvokeFn, .doc = "Calls f sequentially (no ForkJoin pool in CW)." },
    .{ .name = "fjfork", .func = &fjforkFn, .doc = "Forks a task (no-op in CW, sequential execution)." },
    .{ .name = "fjjoin", .func = &fjjoinFn, .doc = "Joins a task (sequential execution in CW)." },
    .{ .name = "append!", .func = &appendFn, .doc = "Adds x to acc and returns acc." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.reducers",
    .builtins = &builtins,
    .loading = .eager_eval,
    .embedded_source = es.reducers_macros_source,
};
