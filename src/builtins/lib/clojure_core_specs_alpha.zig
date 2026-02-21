// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.specs.alpha — Specs for clojure.core macros.
//! Replaces clojure/core/specs/alpha.clj (10 lines).
//! UPSTREAM-DIFF: Minimal implementation. Only includes non-spec helper functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
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

/// (even-number-of-forms? forms)
/// Returns true if there are an even number of forms in a binding vector.
fn evenNumberOfFormsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to even-number-of-forms?", .{args.len});
    const cnt = try callCore(allocator, "count", &.{args[0]});
    return try callCore(allocator, "even?", &.{cnt});
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{
        .name = "even-number-of-forms?",
        .func = &evenNumberOfFormsFn,
        .doc = "Returns true if there are an even number of forms in a binding vector",
    },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.specs.alpha",
    .builtins = &builtins,
    .loading = .lazy,
};
