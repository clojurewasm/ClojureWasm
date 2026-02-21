// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.spec.gen.alpha — NamespaceDef for registry.
//! Lazy: loaded on first require. Source via @embedFile.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const es = @import("../../runtime/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.spec.gen.alpha",
    .loading = .lazy,
    .embedded_source = es.spec_gen_alpha_clj_source,
};
