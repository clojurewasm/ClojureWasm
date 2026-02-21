// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.repl — NamespaceDef for registry.
//! Builtins registered eagerly; macros (doc, dir, source) loaded via evalString in bootstrap.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_repl.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.repl",
    .builtins = &impl.builtins,
    .loading = .eager_eval,
};
