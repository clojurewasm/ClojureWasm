// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.core.server — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const DynVarDef = registry.DynVarDef;
const Value = @import("../../runtime/value.zig").Value;
const impl = @import("../ns_server.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.core.server",
    .builtins = &impl.builtins,
    .dynamic_vars = &.{
        DynVarDef{ .name = "*session*", .default = Value.nil_val },
    },
};
