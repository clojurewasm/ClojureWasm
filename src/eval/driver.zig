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
const value_mod = @import("../runtime/value/value.zig");
const Value = value_mod.Value;
const tree_walk = @import("backend/tree_walk.zig");
const vm = @import("backend/vm.zig");
const vm_compiler = @import("backend/vm/compiler.zig");
const serialize = @import("bytecode/serialize.zig");

pub const MAX_LOCALS = tree_walk.MAX_LOCALS;

/// Deserialize + run a bytecode envelope (one `BytecodeChunk` per
/// top-level form). Chunks run interleaved — each is deserialized then
/// evaluated before the next — so a later chunk's `var_ref` to an
/// earlier chunk's `def` resolves against the live var (ADR-0034 am1
/// Alt B). Each chunk evaluates on the VM (`vm.eval`); fns it `def`s
/// carry bytecode and dispatch via the vtable's `evalChunk` slot
/// (wired into both backends' vtables — ADR-0056 Cycle 0).
///
/// This is the single envelope-run primitive the `cljw build`
/// embedded-run, the AOT-bootstrap restore, and lazy-`require` all route
/// through (ADR-0056 Alt-2 — impl lives once, in Layer 1, so both
/// `lang/bootstrap` and `app/builder` can call it).
pub fn runEnvelope(rt: *Runtime, env: *Env, arena: std.mem.Allocator, payload: []const u8) !void {
    var it = try serialize.EnvelopeIterator.init(payload);
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    while (try it.next()) |chunk_bytes| {
        var chunk = try serialize.deserializeChunk(arena, rt, env, chunk_bytes);
        _ = try vm.eval(rt, env, &locals, &chunk);
    }
}

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
        // ADR-0056 Cycle 0: a tree_walk-default runtime still dispatches
        // bytecode-backed fns (AOT-restored bootstrap / `cljw build`
        // payloads) on the VM via the per-method `bytecode`/`body` hybrid
        // (`tree_walk.zig:1004`). Inert until such a fn exists — pure
        // source-eval'd tree_walk fns carry `bytecode == null` and never
        // consult this slot. The VM eval loop is already linked in (the
        // `cljw build` path references it), so this adds no code bloat.
        rt.vtable.?.evalChunk = &vm.evalChunkErased;
    }
}
