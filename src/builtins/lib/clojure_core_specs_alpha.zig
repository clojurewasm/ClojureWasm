// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.specs.alpha — NamespaceDef for registry.
//! Lazy: loaded on first require. Source via @embedFile.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const es = @import("../../runtime/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.specs.alpha",
    .loading = .lazy,
    .embedded_source = es.core_specs_alpha_clj_source,
};
