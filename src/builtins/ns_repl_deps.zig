// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.repl.deps — stub namespace for dynamic library loading.
//! CW doesn't support dynamic classpath modification. All functions throw ex-info.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../runtime/error.zig");

/// (add-libs lib-coords)
fn addLibsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to add-libs", .{args.len});
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.repl.deps/add-libs not yet implemented in CW", .{});
}

/// (add-lib lib coord) / (add-lib lib)
fn addLibFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to add-lib", .{args.len});
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.repl.deps/add-lib not yet implemented in CW", .{});
}

/// (sync-deps & opts)
fn syncDepsFn(_: Allocator, args: []const Value) anyerror!Value {
    _ = args;
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.repl.deps/sync-deps not yet implemented in CW", .{});
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "add-libs",
        .func = &addLibsFn,
        .doc = "Given lib-coords, a map of lib to coord, will resolve all transitive deps for the libs together and add them to the repl classpath. Not yet implemented in CW.",
    },
    .{
        .name = "add-lib",
        .func = &addLibFn,
        .doc = "Given a lib that is not yet on the repl classpath, make it available. Not yet implemented in CW.",
    },
    .{
        .name = "sync-deps",
        .func = &syncDepsFn,
        .doc = "Calls add-libs with any libs present in deps.edn but not yet present on the classpath. Not yet implemented in CW.",
    },
};
