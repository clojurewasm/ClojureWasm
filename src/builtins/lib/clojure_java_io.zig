// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.io — NamespaceDef for registry.
//! Merges io.zig::java_io_builtins + ns_java_io.zig builtins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const Value = @import("../../runtime/value.zig").Value;
const Env = @import("../../runtime/env.zig").Env;
const io_mod = @import("../io.zig");
const ns_java_io_mod = @import("../ns_java_io.zig");

fn postRegister(allocator: Allocator, env: *Env) anyerror!void {
    // Register Coercions + IOFactory protocols
    try ns_java_io_mod.registerProtocols(allocator, env);
    // Bind default-streams-impl var
    const java_io_ns = env.findNamespace("clojure.java.io") orelse return error.EvalError;
    const v = try java_io_ns.intern("default-streams-impl");
    const impl_map = try ns_java_io_mod.makeDefaultStreamsImpl(allocator);
    v.bindRoot(impl_map);
}

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.io",
    // io.zig base builtins first, then ns_java_io protocol-based builtins override (e.g. as-file)
    .builtins = &(io_mod.java_io_builtins ++ ns_java_io_mod.builtins),
    .post_register = &postRegister,
};
