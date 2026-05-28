// SPDX-License-Identifier: EPL-2.0
//! STM primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! `ref` and `deref` from clojure.core, wrapping `runtime/stm/ref.zig`
//! per F-009. Phase 13 read-only path only (ADR-0010 amendment 3):
//! `(ref init)` constructs a Ref; `(deref r)` returns its current
//! value. `dosync` / `alter` / `commute` / `ensure` / `ref-set` are
//! not wired here (Phase 14-15). `deref` of a non-Ref raises until
//! atom / future / promise / delay land (Phase 15).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const ref_mod = @import("../../runtime/stm/ref.zig");

/// `(ref init)` — construct a Tier A STM Ref seeded with `init`.
/// JVM `clojure.core/ref` also accepts `:meta` / `:validator` /
/// `:min-history` / `:max-history` option kwargs; those ride the
/// Phase-14 transaction machinery (D-102) and are not accepted yet.
pub fn refFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("ref", args, 1, loc);
    return try ref_mod.alloc(rt, args[0]);
}

/// `(deref r)` / `@r` — return a Ref's current value. Outside a
/// transaction this is the newest committed value (JVM `Ref.deref`
/// collapses to `currentVal()`). Other IDeref types (atom / future /
/// promise / delay) land in Phase 15; deref of a non-Ref raises
/// until then.
pub fn derefFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("deref", args, 1, loc);
    if (ref_mod.isRef(args[0])) return ref_mod.current(args[0]);
    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "deref of a non-Ref value" });
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "ref", .f = &refFn },
    .{ .name = "deref", .f = &derefFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
