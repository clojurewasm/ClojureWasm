// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.server — Socket server support (stub).
//! Replaces clojure/core/server.clj.
//! UPSTREAM-DIFF: Stub namespace. Socket server requires Zig networking not yet implemented.

const Allocator = @import("std").mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const DynVarDef = registry.DynVarDef;

// ============================================================
// Implementation
// ============================================================

/// (start-server opts) — stub
fn startServerFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to start-server", .{args.len});
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.core.server/start-server not yet implemented in CW", .{});
}

/// (stop-server) or (stop-server name) — no-op stub
fn stopServerFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len > 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stop-server", .{args.len});
    return Value.nil_val;
}

/// (stop-servers) — no-op stub
fn stopServersFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to stop-servers", .{args.len});
    return Value.nil_val;
}

/// (prepl in-reader out-fn & opts) — stub
fn preplFn(_: Allocator, args: []const Value) anyerror!Value {
    _ = args;
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.core.server/prepl not yet implemented in CW", .{});
}

/// (io-prepl) — stub
fn ioPreplFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to io-prepl", .{args.len});
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.core.server/io-prepl not yet implemented in CW", .{});
}

/// (remote-prepl host port in-reader out-fn & opts) — stub
fn remotePreplFn(_: Allocator, args: []const Value) anyerror!Value {
    _ = args;
    return err.setErrorFmt(.eval, .value_error, .{}, "clojure.core.server/remote-prepl not yet implemented in CW", .{});
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "start-server", .func = &startServerFn, .doc = "Start a socket server. Not yet implemented in CW." },
    .{ .name = "stop-server", .func = &stopServerFn, .doc = "Stop server with name or all if no name." },
    .{ .name = "stop-servers", .func = &stopServersFn, .doc = "Stop all servers." },
    .{ .name = "prepl", .func = &preplFn, .doc = "A REPL with structured output. Not yet implemented in CW." },
    .{ .name = "io-prepl", .func = &ioPreplFn, .doc = "prepl bound to *in* and *out*, suitable for use with start-server." },
    .{ .name = "remote-prepl", .func = &remotePreplFn, .doc = "Implements a prepl on in-reader and out-fn by forwarding to a remote [host port] prepl." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.server",
    .builtins = &builtins,
    .dynamic_vars = &.{
        DynVarDef{ .name = "*session*", .default = Value.nil_val },
    },
};
