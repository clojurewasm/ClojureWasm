// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.pprint — NamespaceDef for registry.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const DynVarDef = registry.DynVarDef;
const Value = @import("../../runtime/value.zig").Value;
const impl = @import("../builtins/pprint.zig");
const es = @import("../../engine/embedded_sources.zig");

pub const namespace_def = NamespaceDef{
    .name = "clojure.pprint",
    .builtins = &impl.builtins,
    .embedded_source = es.pprint_clj_source,
    .dynamic_vars = &.{
        DynVarDef{ .name = "*print-right-margin*", .default = Value.initInteger(72) },
        DynVarDef{ .name = "*print-miser-width*", .default = Value.initInteger(40) },
        DynVarDef{ .name = "*print-pretty*", .default = Value.true_val },
        DynVarDef{ .name = "*print-suppress-namespaces*", .default = Value.false_val },
        DynVarDef{ .name = "*print-radix*", .default = Value.false_val },
        DynVarDef{ .name = "*print-base*", .default = Value.initInteger(10) },
        DynVarDef{ .name = "*print-pprint-dispatch*", .default = Value.nil_val },
    },
    .loading = .eager_eval,
};
