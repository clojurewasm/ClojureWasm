// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.main — NamespaceDef for registry.
//! Zig builtins (demunge, root-cause, etc.) + evalString for macros/complex fns.
//! Lazy: loaded on first require.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_main.zig");
const es = @import("../../runtime/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.main",
    .builtins = &impl.builtins,
    .loading = .lazy,
    .embedded_source = es.main_macros_source,
};
