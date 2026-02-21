// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.spec.alpha — NamespaceDef for registry.
//! Lazy: loaded on first require. Source via @embedFile.
//! Pre-requires: clojure.spec.gen.alpha (loaded automatically).
//! Extra aliases needed at read time (CW reads all forms before evaluating).

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const es = @import("../../runtime/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.spec.alpha",
    .loading = .lazy,
    .embedded_source = es.spec_alpha_clj_source,
    .extra_aliases = &.{
        .{ "c", "clojure.core" },
        .{ "walk", "clojure.walk" },
        .{ "gen", "clojure.spec.gen.alpha" },
        .{ "str", "clojure.string" },
    },
};
