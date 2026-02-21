// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.template — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const impl = @import("../ns_template.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.template",
    .builtins = &impl.builtins,
    .macro_builtins = &.{impl.do_template_def},
};
