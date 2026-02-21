// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.data — NamespaceDef for registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const Env = @import("../../runtime/env.zig").Env;
const impl = @import("../ns_data.zig");

fn postRegister(allocator: Allocator, env: *Env) anyerror!void {
    try impl.registerProtocols(allocator, env);
}

pub const namespace_def = NamespaceDef{
    .name = "clojure.data",
    .builtins = &impl.builtins,
    .post_register = &postRegister,
};
