// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.process — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_java_process.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.process",
    .builtins = &impl.builtins,
};
