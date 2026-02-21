// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Aggregate NamespaceDef for all library (non-core) namespaces.
//!
//! Each lib/*.zig module exports a `namespace_def: NamespaceDef`.
//! This file collects them into `all_namespace_defs` for use by
//! registry.zig and ns_loader.zig.

const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

/// All library namespace definitions.
/// Populated incrementally as namespaces are migrated (Phase R2).
pub const all_namespace_defs = [_]NamespaceDef{};
