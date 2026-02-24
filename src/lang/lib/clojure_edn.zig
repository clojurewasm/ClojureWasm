// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.edn — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../builtins/eval.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.edn",
    .builtins = &impl.edn_builtins,
};
