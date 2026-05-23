// SPDX-License-Identifier: EPL-2.0
//! Top-level eval driver — comptime-routes each analysed form to the
//! configured backend (ROADMAP §9.6 / 4.8, ADR-0005 + ADR-0023).
//!
//! `evalForm` is the single seam main.zig / bootstrap.zig use to
//! evaluate a `Node`. `build_options.backend == .tree_walk` recurses
//! through `tree_walk.eval` (the default). `build_options.backend ==
//! .vm` compiles the node into a `BytecodeChunk` (per-form arena
//! lifetime) and runs it through `vm.eval`. The choice happens at
//! comptime; only one path lands in the final binary.

const std = @import("std");
const build_options = @import("build_options");

const node_mod = @import("node.zig");
const Node = node_mod.Node;
const runtime_mod = @import("../runtime/runtime.zig");
const Runtime = runtime_mod.Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const tree_walk = @import("backend/tree_walk.zig");
const vm = @import("backend/vm.zig");
const vm_compiler = @import("backend/vm/compiler.zig");

pub const MAX_LOCALS = tree_walk.MAX_LOCALS;

/// Evaluate one top-level form. Callers own `locals` (typically a
/// fixed `[MAX_LOCALS]Value`); `arena` is consulted only by the VM
/// backend to hold the per-form `BytecodeChunk` slices.
pub fn evalForm(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    arena: std.mem.Allocator,
    node: *const Node,
) anyerror!Value {
    if (comptime build_options.backend == .vm) {
        const chunk = try vm_compiler.compile(rt, arena, node);
        return vm.eval(rt, env, locals, &chunk);
    } else {
        return tree_walk.eval(rt, env, locals, node);
    }
}

/// Install the active backend's vtable. Called once at startup, after
/// `Runtime.init` + `Env.init`.
pub fn installVTable(rt: *Runtime) void {
    if (comptime build_options.backend == .vm) {
        vm.installVTable(rt);
    } else {
        tree_walk.installVTable(rt);
    }
}
