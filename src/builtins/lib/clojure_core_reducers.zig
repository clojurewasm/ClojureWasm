// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.reducers — NamespaceDef for registry.
//! Builtins registered eagerly; protocols/macros/reify loaded via evalString in bootstrap.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_reducers.zig");
const es = @import("../../runtime/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.reducers",
    .builtins = &impl.builtins,
    .loading = .eager_eval,
    .embedded_source = es.reducers_macros_source,
};
