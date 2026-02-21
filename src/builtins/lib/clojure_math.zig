// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.math — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const ConstVarDef = registry.ConstVarDef;
const Value = @import("../../runtime/value.zig").Value;
const impl = @import("../math.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.math",
    .builtins = &impl.builtins,
    .constant_vars = &.{
        ConstVarDef{ .name = "PI", .value = Value.initFloat(impl.PI) },
        ConstVarDef{ .name = "E", .value = Value.initFloat(impl.E) },
    },
};
