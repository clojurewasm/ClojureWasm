// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.test.tap — NamespaceDef for registry.
//! Lazy: loaded on first require. All content via evalString.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const es = @import("../../engine/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.test.tap",
    .loading = .lazy,
    .embedded_source = es.test_tap_clj_source,
};
