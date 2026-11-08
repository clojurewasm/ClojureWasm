// SPDX-License-Identifier: EPL-2.0
//! Namespace source loader (ADR-0084, D-158). Analyses + evaluates a
//! namespace's source into the env, with cycle detection, `*ns*` save/restore,
//! and loaded-lib idempotency. Lives in Layer 1 (`eval/`) so BOTH backends
//! (tree_walk + vm) share one load body — `bootstrap.zig` is Layer 2 and must
//! not be imported by `eval/backend/*` (zone_deps).
//!
//! The forms are analysed + evaluated against `rt.load_arena` (session-lifetime)
//! because loaded fns / macros capture their analyzer Nodes; a transient arena
//! would dangle them after the load returns.

const Runtime = @import("../runtime/runtime.zig").Runtime;
const ResolvedSource = @import("../runtime/runtime.zig").ResolvedSource;
const root_set = @import("../runtime/gc/root_set.zig");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const Reader = @import("reader.zig").Reader;
const analyzeForm = @import("analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("macro_dispatch.zig");
const driver = @import("driver.zig");
const vm_compiler = @import("backend/vm/compiler.zig");
const serialize = @import("bytecode/serialize.zig");
const Form = @import("form.zig").Form;
const error_catalog = @import("../runtime/error/catalog.zig");
const error_mod = @import("../runtime/error/info.zig");
const SourceLocation = error_mod.SourceLocation;

/// Load `resolved.source` as namespace `ns_name` into `env`. Idempotent (skips
/// if already in `rt.loaded_libs`); raises `circular_require` if `ns_name` is
/// already in-flight (`a → b → a`); restores the caller's current ns after the
/// loaded file's own `(ns …)` switches it. Errors propagate after cleanup.
pub fn loadNamespace(
    rt: *Runtime,
    env: *Env,
    ns_name: []const u8,
    resolved: ResolvedSource,
    loc: SourceLocation,
) !void {
    if (rt.loaded_libs.contains(ns_name)) return;
    if (rt.require_in_progress.contains(ns_name))
        return error_catalog.raise(.circular_require, loc, .{ .chain = ns_name });

    const gpa = rt.gpa;
    {
        const key = try gpa.dupe(u8, ns_name);
        errdefer gpa.free(key);
        try rt.require_in_progress.put(gpa, key, {});
    }
    // Pop the in-flight marker on every exit (success or error).
    defer if (rt.require_in_progress.fetchRemove(ns_name)) |kv| gpa.free(kv.key);

    // Register the source FIRST so a parse/analyze/eval error inside the lib
    // renders with the lib's file:line, not <bootstrap> (ADR-0084 (f)).
    try rt.registerSource(resolved.label, resolved.source);

    // Restore the caller's ns after the load (the file's `(ns …)` switches it).
    const saved_ns = env.current_ns;
    defer if (saved_ns) |s| env.setCurrentNs(s);

    const macro_table: *const macro_dispatch.Table = @ptrCast(@alignCast(rt.macro_table.?));
    const arena = rt.load_arena.allocator();
    var reader = Reader.init(arena, resolved.source);
    reader.file_name = resolved.label;
    while (try reader.read()) |form| {
        try loadTopLevelForm(rt, env, arena, macro_table, form, resolved.from_filesystem);
    }

    // Mark fully-loaded only on success (after every form evaluated).
    const loaded_key = try gpa.dupe(u8, ns_name);
    errdefer gpa.free(loaded_key);
    try rt.loaded_libs.put(gpa, loaded_key, {});
}

/// Analyze + evaluate one top-level form from a loaded namespace, unrolling a
/// top-level `(do …)` recursively (D-374) so a later child sees an earlier
/// child's analyze-time effect (`(import …)` / `(defmacro …)`). On the `cljw
/// build` path each LEAF form's compiled chunk is pushed to the sink AFTER eval
/// (post-order — a nested `require` ran during eval and pushed its deps first),
/// so an unrolled `do` embeds its children as separate top-level chunks with the
/// identical replay order.
fn loadTopLevelForm(
    rt: *Runtime,
    env: *Env,
    arena: @import("std").mem.Allocator,
    macro_table: *const macro_dispatch.Table,
    form: Form,
    from_filesystem: bool,
) !void {
    if (driver.topLevelDoChildren(form)) |children| {
        for (children) |child|
            try loadTopLevelForm(rt, env, arena, macro_table, child, from_filesystem);
        return;
    }
    // D-430 / ADR-0169: per-form analysis bracket — the require/load twin of
    // driver.evalTopLevelForm's (kept open through eval + the sink recompile).
    var af: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af, rt.gc.infra);
    defer root_set.endAnalysisPersist(&af, &rt.gc);
    const node = try analyzeForm(arena, rt, env, null, form, macro_table);
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    _ = try driver.evalForm(rt, env, &locals, arena, node);
    if (from_filesystem) {
        if (rt.build_chunk_sink) |sink| {
            const chunk = try vm_compiler.compile(rt, arena, node);
            try sink.push(sink.ctx, &chunk);
        }
    }
}

/// Read and evaluate every form of `source` in order, reading each form only
/// after the previous one ran, as `loadNamespace` does: a `(ns …)` in the text
/// decides how its later forms read and resolve (`::kw`, syntax-quote). Backs
/// `load-string` and `load-file`. `label` names the source in errors and in
/// `:file` meta. Restores the caller's ns. => the last form's value, nil for
/// none. Unlike `loadNamespace` it records no lib: loading twice runs twice.
pub fn loadSource(rt: *Runtime, env: *Env, label: []const u8, source: []const u8, loc: SourceLocation) !Value {
    const table_opaque = rt.macro_table orelse
        return error_catalog.raiseInternal(loc, "load: macro_table not installed");
    const macro_table: *const macro_dispatch.Table = @ptrCast(@alignCast(table_opaque));
    // Forms borrow the text (symbol names, string literals), and a loaded fn
    // keeps its Nodes for the session, so the text lives in the load arena too.
    const arena = rt.load_arena.allocator();
    const text = try arena.dupe(u8, source);
    const name = try arena.dupe(u8, label);
    // Replace, not register: a file loaded again after an edit must render
    // its errors against the new text.
    try rt.replaceSource(name, text);

    const saved_ns = env.current_ns;
    defer if (saved_ns) |s| env.setCurrentNs(s);

    var reader = Reader.init(arena, text);
    reader.file_name = name;
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    // Only the last form's value is returned, and between one eval and the
    // next only the reader runs (arena Forms, no GC allocation), so `result`
    // needs no root.
    var result: Value = .nil_val;
    while (try reader.read()) |form|
        result = try driver.evalTopLevelForm(rt, env, &locals, arena, form, macro_table);
    return result;
}

/// Return the named namespace, loading it via the require resolver if it has
/// not been loaded yet. "Loaded" is keyed off `rt.loaded_libs` (ADR-0163), NOT
/// `mappings.count() > 0`: a ns can EXIST with interned vars yet have an
/// un-run `.clj` body (e.g. `cljw.error`, whose `*error-context*` var is
/// Zig-interned by `error_context.register` before its macro file loads; or
/// any `(intern 'foo 'x 1)` then `(require 'foo)`). The old mappings-count
/// proxy wrongly treated those as loaded and skipped the body. Shared by the
/// `require` special form and the runtime `use` fn (ADR-0085 / F-011). Raises
/// `lib_not_found` when no resolver / source.
pub fn loadOrFindNs(rt: *Runtime, env: *Env, name: []const u8, loc: SourceLocation) !*env_mod.Namespace {
    if (rt.loaded_libs.contains(name)) {
        if (env.findNs(name)) |existing| return existing;
    }
    // ADR-0163 D-516: a lazy bootstrap namespace lives as a bytecode region in the
    // embedded blob — replay it (no re-parse) before consulting the source resolver.
    if (rt.bootstrap_region_blob) |blob| {
        if (serialize.findRegion(blob, name)) |ref| {
            // C5': a lazy region is stored flate-compressed; decompress into
            // the session arena (8-aligned — the in-place instr views run
            // over the buffer). Raw regions pass through untouched.
            const region = try serialize.decompressRegion(rt.load_arena.allocator(), ref);
            try loadRegionNamespace(rt, env, name, region, loc);
            return env.findNs(name) orelse
                return error_catalog.raise(.lib_not_found, loc, .{ .ns = name });
        }
    }
    if (rt.require_resolver) |resolver| {
        if (try resolver(rt, name)) |resolved| {
            try loadNamespace(rt, env, name, resolved, loc);
            return env.findNs(name) orelse
                return error_catalog.raise(.lib_not_found, loc, .{ .ns = name });
        }
    }
    // Neither in loaded_libs, nor a bytecode region, nor resolvable to source —
    // but the ns may have been defined INLINE (e.g. `(ns mylib …)` then
    // `(require '[mylib])`): there is nothing to load, so a non-empty ns is found
    // as-is. (This is the legitimate residue of the old mappings-count guard, now
    // a last resort so it no longer masks a lazy bootstrap ns whose registerAll
    // private leaves made `mappings.count() > 0` before its `.clj` body ran.)
    if (env.findNs(name)) |existing| {
        if (existing.mappings.count() > 0) return existing;
    }
    return error_catalog.raise(.lib_not_found, loc, .{ .ns = name });
}

/// Replay a lazy bootstrap namespace's bytecode `region` (ADR-0163 D-516) into
/// `env`. The bytecode analog of `loadNamespace`: same cycle-detection + `*ns*`
/// save/restore + loaded-lib bookkeeping, but runs `driver.runEnvelope` (the
/// region is a self-contained envelope whose `(in-ns 'X)` creates the ns and
/// whose `(:require dep)` forms cascade-load deps through `loadOrFindNs`) instead
/// of parse+analyze+eval. Forms live on `rt.load_arena` (session-lifetime) since
/// the ns's fns/macros capture their bytecode constants.
fn loadRegionNamespace(rt: *Runtime, env: *Env, ns_name: []const u8, region: []const u8, loc: SourceLocation) !void {
    if (rt.loaded_libs.contains(ns_name)) return;
    if (rt.require_in_progress.contains(ns_name))
        return error_catalog.raise(.circular_require, loc, .{ .chain = ns_name });

    const gpa = rt.gpa;
    {
        const key = try gpa.dupe(u8, ns_name);
        errdefer gpa.free(key);
        try rt.require_in_progress.put(gpa, key, {});
    }
    defer if (rt.require_in_progress.fetchRemove(ns_name)) |kv| gpa.free(kv.key);

    // Restore the caller's ns after the region's own `(in-ns …)` switches it.
    const saved_ns = env.current_ns;
    defer if (saved_ns) |s| env.setCurrentNs(s);

    // v7 (ADR-0173): the region's pool_refs resolve against the blob-level
    // shared pool; parse per replay (an index walk + slice array — not hot).
    var blob_pool: ?serialize.ConstPool = if (rt.bootstrap_region_blob) |b| try serialize.readBlobPool(gpa, b) else null;
    defer if (blob_pool) |*cp| cp.deinit(gpa);
    try driver.runEnvelope(rt, env, rt.load_arena.allocator(), region, if (blob_pool) |*cp| cp else null);

    const loaded_key = try gpa.dupe(u8, ns_name);
    errdefer gpa.free(loaded_key);
    try rt.loaded_libs.put(gpa, loaded_key, {});
}
