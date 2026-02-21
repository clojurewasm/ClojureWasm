// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.walk — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_walk.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.walk",
    .builtins = &impl.builtins,
};
