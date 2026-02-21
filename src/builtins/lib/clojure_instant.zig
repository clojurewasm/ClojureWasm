// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.instant — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_instant.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.instant",
    .builtins = &impl.builtins,
};
