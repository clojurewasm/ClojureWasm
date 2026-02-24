// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.test — NamespaceDef for registry.
//! Eagerly loaded at startup; all content via evalString.
//! Requires clojure.walk referred (are macro uses postwalk-replace).

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const es = @import("../../engine/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.test",
    .loading = .eager_eval,
    .embedded_source = es.test_clj_source,
    .extra_refers = &.{"clojure.walk"},
};
