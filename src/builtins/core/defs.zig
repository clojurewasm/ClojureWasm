// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Aggregate builtin tables for clojure.core.
//!
//! Currently re-exports from parent-directory modules (temporary compat).
//! Will aggregate core/*.zig builtin tables after Phase R4 file moves.

const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;

// Re-export parent-dir modules (Phase R4 will move files here)
const arithmetic = @import("../arithmetic.zig");
const special_forms = @import("../special_forms.zig");
const collections_mod = @import("../collections.zig");
const predicates_mod = @import("../predicates.zig");
const strings_mod = @import("../strings.zig");
const io_mod = @import("../io.zig");
const atom_mod = @import("../atom.zig");
const sequences_mod = @import("../sequences.zig");
const metadata_mod = @import("../metadata.zig");
const regex_mod = @import("../regex_builtins.zig");
const eval_mod = @import("../eval.zig");
const ns_ops_mod = @import("../ns_ops.zig");
const misc_mod = @import("../misc.zig");
const multimethods_mod = @import("../multimethods.zig");
const system_mod = @import("../system.zig");
const transient_mod = @import("../transient.zig");
const chunk_mod = @import("../chunk.zig");
const lifecycle_mod = @import("../../runtime/lifecycle.zig");
const array_mod = @import("../array.zig");
const constructors_mod = @import("../../interop/constructors.zig");

/// All clojure.core builtins aggregated from category modules.
pub const all_builtins = arithmetic.builtins ++
    special_forms.builtins ++
    collections_mod.builtins ++
    predicates_mod.builtins ++
    strings_mod.builtins ++
    io_mod.builtins ++
    atom_mod.builtins ++
    sequences_mod.builtins ++
    arithmetic.numeric_builtins ++
    metadata_mod.builtins ++
    regex_mod.builtins ++
    eval_mod.builtins ++
    ns_ops_mod.builtins ++
    misc_mod.builtins ++
    multimethods_mod.builtins ++
    io_mod.file_io_builtins ++
    system_mod.builtins ++
    transient_mod.builtins ++
    chunk_mod.builtins ++
    lifecycle_mod.builtins ++
    array_mod.builtins ++
    constructors_mod.builtins;
