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
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const Reader = @import("reader.zig").Reader;
const analyzeForm = @import("analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("macro_dispatch.zig");
const driver = @import("driver.zig");
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
        const node = try analyzeForm(arena, rt, env, null, form, macro_table);
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        _ = try driver.evalForm(rt, env, &locals, arena, node);
    }

    // Mark fully-loaded only on success (after every form evaluated).
    const loaded_key = try gpa.dupe(u8, ns_name);
    errdefer gpa.free(loaded_key);
    try rt.loaded_libs.put(gpa, loaded_key, {});
}
