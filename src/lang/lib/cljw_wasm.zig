// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! cljw.wasm — NamespaceDef for registry.
//! Conditionally enabled when wasm support is compiled in.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;
const wasm_types = @import("../../runtime/wasm_types.zig");

const impl = @import("cljw_wasm_builtins.zig");

pub const namespace_def = NamespaceDef{
    .name = "cljw.wasm",
    .builtins = impl.builtins,
    .enabled = wasm_types.enable_wasm,
};
