// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.uuid — NamespaceDef for registry.
//! Lazy: loaded on first require. No vars — UUID printing handled in Zig.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

pub const namespace_def = NamespaceDef{
    .name = "clojure.uuid",
    .loading = .lazy,
};
