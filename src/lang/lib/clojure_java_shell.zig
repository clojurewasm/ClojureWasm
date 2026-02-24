// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.shell — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const DynVarDef = registry.DynVarDef;
const Value = @import("../../runtime/value.zig").Value;
const impl = @import("../builtins/shell.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.shell",
    .builtins = &impl.builtins,
    .macro_builtins = &.{ impl.with_sh_dir_def, impl.with_sh_env_def },
    .dynamic_vars = &.{
        DynVarDef{ .name = "*sh-dir*", .default = Value.nil_val },
        DynVarDef{ .name = "*sh-env*", .default = Value.nil_val },
    },
};
