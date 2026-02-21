// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.string — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../strings.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.string",
    .builtins = &impl.clj_string_builtins,
};
