// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! cljw.http — NamespaceDef for registry.
//! HTTP server builtins with hidden __handler var for GC rooting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const Env = @import("../../runtime/env.zig").Env;
const impl = @import("../builtins/http_server.zig");

fn postRegister(_: Allocator, env: *Env) anyerror!void {
    // Hidden var for GC rooting of handler function
    const http_ns = env.findNamespace("cljw.http") orelse return error.EvalError;
    _ = try http_ns.intern("__handler");
}

pub const namespace_def = NamespaceDef{
    .name = "cljw.http",
    .builtins = &impl.builtins,
    .post_register = &postRegister,
};
