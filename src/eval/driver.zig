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
const analyzer = @import("analyzer/analyzer.zig");
const root_set = @import("../runtime/gc/root_set.zig");
const macro_dispatch = @import("macro_dispatch.zig");
const Form = @import("form.zig").Form;
const error_catalog = @import("../runtime/error/catalog.zig");
const SourceLocation = @import("../runtime/error/info.zig").SourceLocation;
const dispatch = @import("../runtime/dispatch.zig");

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
pub fn runEnvelope(rt: *Runtime, env: *Env, arena: std.mem.Allocator, payload: []const u8, pool: ?*const serialize.ConstPool) !void {
    var it = try serialize.EnvelopeIterator.init(payload);
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    // ADR-0129 / Track D D1: arm the ambient eval Env for the envelope run — this
    // is a second top-level-form driver alongside evalForm, so an AOT (`cljw
    // build`) top-level seq-keyed map literal (e.g. `{(map inc xs) :a}`) must hash
    // its key by content too. Without this the key hashes by identity at run and
    // silently misses (the worst F-011 failure class). treeWalkCall re-arms per
    // nested call; both restore.
    const saved_consult_env = dispatch.current_env;
    dispatch.current_env = env;
    defer dispatch.current_env = saved_consult_env;
    while (try it.next()) |chunk_bytes| {
        // D-430: per-chunk analysis bracket — roots the deserialized
        // constants from `deserializeChunk` through this chunk's eval
        // (per-chunk grain keeps the high-water mark at one form's
        // constants, not the whole envelope's).
        var af: root_set.AnalysisFrame = undefined;
        root_set.beginAnalysis(&af, rt.gc.infra);
        defer root_set.endAnalysisPersist(&af, &rt.gc);
        var chunk = try serialize.deserializeChunk(arena, rt, env, chunk_bytes, pool, true);
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
    // ADR-0129: arm the ambient eval Env for the top-level-form window (before
    // the first call, e.g. a top-level map literal `{(->Box 1) :a}` whose key is
    // hashed during arg-eval) so Layer-0 key-hash/equiv consults reach a
    // deftype's hasheq/equiv. treeWalkCall re-arms per nested call; both restore.
    const saved_consult_env = dispatch.current_env;
    dispatch.current_env = env;
    defer dispatch.current_env = saved_consult_env;
    if (comptime build_options.backend == .vm) {
        const chunk = try vm_compiler.compile(rt, arena, node);
        return vm.eval(rt, env, locals, &chunk);
    } else {
        // GC-ROOT: A6 — the TOP-LEVEL locals window on the tree_walk backend
        // (vm.eval pushes its own A1 frame; tree_walk fn activations push per
        // call, but a top-level `let`'s slots live in THIS caller-owned array
        // and were otherwise invisible to a mid-eval collect — D-555).
        var gc_stack: [1]Value = .{.nil_val};
        var gc_sp: u16 = 0;
        var gc_frame: root_set.EvalFrame = .{
            .stack = &gc_stack,
            .sp = &gc_sp,
            .locals = locals,
            .parent = root_set.eval_frame_head,
        };
        root_set.eval_frame_head = &gc_frame;
        defer root_set.eval_frame_head = gc_frame.parent;
        return tree_walk.eval(rt, env, locals, node);
    }
}

/// Children of a literal top-level `(do …)` form, or null if `form` is not one.
/// Returns a (possibly empty) slice of the `do`'s argument forms — the seam the
/// top-level `do`-unroll (D-374) hangs on. Only a LITERAL `do` head is matched
/// (the reported case + clj's common top-level forms); a macro expanding to `do`
/// is not unrolled (tracked as the residual in D-374).
pub fn topLevelDoChildren(form: Form) ?[]const Form {
    return switch (form.data) {
        .list => |items| if (items.len >= 1 and items[0].data == .symbol and
            items[0].data.symbol.ns == null and
            std.mem.eql(u8, items[0].data.symbol.name, "do"))
            items[1..]
        else
            null,
        else => null,
    };
}

/// Analyze + evaluate one top-level form, unrolling a top-level `(do …)`
/// recursively so each child is analyzed+evaluated IN SEQUENCE (D-374, clj
/// parity): an effect in an earlier child (`(import …)` / `(defmacro …)`) is
/// visible to a later child's ANALYSIS. cljw otherwise analyzes the whole `do`
/// before evaluating, so `(do (defmacro m [] 42) (m))` fails (m resolved before
/// its def ran). The `do`'s value is its LAST child's value (empty `(do)` → nil),
/// so a `-e`/REPL prints one result per source form. The loader uses
/// `topLevelDoChildren` directly (it also pushes each leaf's chunk to the
/// `cljw build` sink).
pub fn evalTopLevelForm(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    arena: std.mem.Allocator,
    form: Form,
    table: *const macro_dispatch.Table,
) anyerror!Value {
    if (topLevelDoChildren(form)) |children| {
        var result: Value = .nil_val;
        for (children) |child| result = try evalTopLevelForm(rt, env, locals, arena, child, table);
        return result;
    }
    // D-430: analysis bracket — roots every literal/quoted/compile-time
    // Value this form produces, from analysis THROUGH its evaluation (also
    // covers tree_walk Node constants, which have no EvalFrame pool).
    var af: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af, rt.gc.infra);
    defer root_set.endAnalysisPersist(&af, &rt.gc);
    const node = try analyzer.analyze(arena, rt, env, null, form, table);
    return evalForm(rt, env, locals, arena, node);
}

/// Evaluate a runtime data Value as code — the typed Layer-1 verb the
/// `eval` primitive (and future `load-string` / REPL read+eval) consume
/// (ADR-0058). Reconstructs a Form from the Value (`valueToForm`),
/// analyses it with the borrowed canonical macro table (so built-in
/// macros expand; user macros resolve via env Vars), then evaluates the
/// Node. `arena` holds the transient Form + Node; the result Value is
/// GC-allocated and survives the caller freeing the arena. `loc` is the
/// eval call site, stamped onto the reconstructed forms.
///
/// `rt.macro_table` must be installed (`bootstrap.setupCorePrefix`); a
/// null is an internal error (eval before bootstrap). This is the one
/// site that casts the type-erased `rt.macro_table` back to its Layer-1
/// type — callers stay typed.
pub fn evalValue(
    rt: *Runtime,
    env: *Env,
    locals: []Value,
    arena: std.mem.Allocator,
    value: Value,
    loc: SourceLocation,
) anyerror!Value {
    const table_opaque = rt.macro_table orelse
        return error_catalog.raiseInternal(loc, "eval: macro_table not installed");
    const table: *const macro_dispatch.Table = @ptrCast(@alignCast(table_opaque));
    // `analyze` takes a Form by value (D-197: this verb was dead code until the
    // `eval` primitive wired it, so the old `*Form` arg never type-checked).
    const form = try analyzer.valueToForm(arena, rt, env, value, loc);
    // D-374: `(eval '(do …))` treats its arg as a top-level form, so a top-level
    // `do` unrolls (clj parity) — each child sees earlier children's effects.
    return evalTopLevelForm(rt, env, locals, arena, form, table);
}

/// Install the active backend's vtable. Called once at startup, after
/// `Runtime.init` + `Env.init`.
pub fn installVTable(rt: *Runtime) void {
    // D-251: register the `.fn_val` GC trace (marks closure captures + method
    // bytecode constants). Lives here, not runtime.zig's Layer-0 registerGcHooks
    // aggregator, because `Function` is a Layer-1 type Layer 0 must not import.
    tree_walk.registerGcHooks();
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
