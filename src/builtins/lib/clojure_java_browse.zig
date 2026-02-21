// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.browse — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_browse.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.browse",
    .builtins = &impl.builtins,
};
