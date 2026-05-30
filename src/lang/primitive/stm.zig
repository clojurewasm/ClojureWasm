// SPDX-License-Identifier: EPL-2.0
//! STM + IDeref primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! `ref` (STM, Phase 13 read-only) + the broader `deref` / `delay` /
//! `future` / `promise` / `deliver` / `realized?` Tier A IDeref
//! surface (row 14.8, D-098 follow-up). `deref` dispatches by tag
//! to atom / ref / delay / promise / future (atom lands Phase 15).
//! `dosync` / `alter` / `commute` / `ensure` / `ref-set` ride Phase
//! 14 D-102 / Phase 15.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const ref_mod = @import("../../runtime/stm/ref.zig");
const delay_mod = @import("../../runtime/delay.zig");
const promise_mod = @import("../../runtime/promise.zig");
const future_mod = @import("../../runtime/future.zig");
const atom_mod = @import("../../runtime/atom.zig");

/// `(ref init)` — construct a Tier A STM Ref seeded with `init`.
/// JVM `clojure.core/ref` also accepts `:meta` / `:validator` /
/// `:min-history` / `:max-history` option kwargs; those ride the
/// Phase-14 transaction machinery (D-102) and are not accepted yet.
pub fn refFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("ref", args, 1, loc);
    return try ref_mod.alloc(rt, args[0]);
}

/// `(deref r)` / `@r` — return a Ref / Delay / Promise / Future's
/// current value. Row 14.8 (D-098 follow-up) extends the Phase-13
/// Ref-only path with delay / promise / future arms. Atom remains
/// Phase 15 (alongside `std.Io.Mutex`).
pub fn derefFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("deref", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .atom => atom_mod.current(v),
        .ref => ref_mod.current(v),
        .delay => try delay_mod.force(rt, env, v, loc),
        .promise => promise_mod.deref(v) orelse
            error_catalog.raise(.promise_undelivered_error, loc, .{}),
        .future => future_mod.deref(v) orelse
            error_catalog.raise(.future_thunk_failed, loc, .{}),
        else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "deref of non-IDeref value" }),
    };
}

/// `__delay-create` — internal primitive called by the `delay` Zig
/// macro transform. Receives a zero-arity fn (the thunk) and
/// returns a Delay Value. Underscore prefix marks it as a Clojure-
/// ns internal — the user-facing surface is `(delay expr)` (macro).
pub fn delayCreateFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__delay-create", args, 1, loc);
    return try delay_mod.alloc(rt, args[0]);
}

/// `__future-call` — internal primitive called by the `future` Zig
/// macro transform. Receives a zero-arity fn and constructs a
/// Future that has already eagerly evaluated the body (single-
/// thread Phase 14 semantic).
pub fn futureCallFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("__future-call", args, 1, loc);
    return try future_mod.alloc(rt, env, args[0], loc);
}

/// `(promise)` — construct an unfulfilled Promise.
pub fn promiseFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("promise", args, 0, loc);
    return try promise_mod.alloc(rt);
}

/// `(deliver p v)` — set the Promise's value on first call; return
/// nil on retry-deliver (JVM-correct semantics: failed CAS = nil).
pub fn deliverFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("deliver", args, 2, loc);
    if (args[0].tag() != .promise)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "deliver: first arg must be a promise" });
    return promise_mod.deliver(args[0], args[1]);
}

/// `(realized? x)` — true iff x is a delay/promise/future that has
/// completed its computation (or a Ref, which is always realised
/// per JVM semantics).
pub fn realizedQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("realized?", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .delay => if (delay_mod.isRealised(v)) Value.true_val else Value.false_val,
        .promise => if (promise_mod.isRealised(v)) Value.true_val else Value.false_val,
        .future => if (future_mod.isRealised(v)) Value.true_val else Value.false_val,
        .ref => Value.true_val,
        else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "realized? called on non-IPending value" }),
    };
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "ref", .f = &refFn },
    .{ .name = "deref", .f = &derefFn },
    .{ .name = "__delay-create", .f = &delayCreateFn },
    .{ .name = "__future-call", .f = &futureCallFn },
    .{ .name = "promise", .f = &promiseFn },
    .{ .name = "deliver", .f = &deliverFn },
    .{ .name = "realized?", .f = &realizedQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
