// SPDX-License-Identifier: EPL-2.0
//! STM + IDeref primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! `ref` + the broader `deref` / `delay` / `future` / `promise` /
//! `deliver` / `realized?` Tier A IDeref surface. `deref` dispatches
//! by tag to atom / ref / delay / promise / future (all wired). The
//! STM transaction engine — `dosync` / `alter` / `commute` / `ensure`
//! / `ref-set` — is implemented here over `concurrency/lock_tx.zig`
//! (Phase B #5).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const ref_mod = @import("../../runtime/stm/ref.zig");
const lock_tx = @import("../../runtime/concurrency/lock_tx.zig");
const delay_mod = @import("../../runtime/delay.zig");
const promise_mod = @import("../../runtime/promise.zig");
const future_mod = @import("../../runtime/future.zig");
const lazy_seq_mod = @import("../../runtime/lazy_seq.zig");
const atom_mod = @import("../../runtime/atom.zig");
const agent_mod = @import("../../runtime/agent.zig");
const volatile_mod = @import("../../runtime/volatile.zig");
const reduced_mod = @import("../../runtime/collection/reduced.zig");

/// `(ref init)` — construct a Tier A STM Ref seeded with `init`.
/// JVM `clojure.core/ref` also accepts `:meta` / `:validator` /
/// `:min-history` / `:max-history` option kwargs; those ride the
/// Phase B transaction engine (D-102) and are not accepted yet.
pub fn refFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("ref", args, 1, loc);
    return try ref_mod.alloc(rt, args[0]);
}

/// `(deref r)` / `@r` — return an Atom / Ref / Delay / Promise /
/// Future / Var / Volatile / Reduced current value. Every IDeref
/// arm is wired; real CAS-under-contention for atoms is Phase B.
pub fn derefFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("deref", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .atom => atom_mod.current(v),
        .agent => agent_mod.current(v),
        .@"volatile" => volatile_mod.current(v),
        // In a transaction, a Ref reads through the in-txn cache (the txn sees
        // its own writes); outside, it reads the current committed value.
        .ref => if (lock_tx.current_tx) |tx| lock_tx.doGet(tx, v.decodePtr(*ref_mod.Ref)) else ref_mod.current(v),
        .reduced => reduced_mod.unreduce(v),
        .delay => try delay_mod.force(rt, env, v, loc),
        // Blocks until delivered (Phase B #4b / D-113) — matches JVM Clojure.
        .promise => promise_mod.deref(v),
        .future => future_mod.deref(v) orelse
            error_catalog.raise(.future_thunk_failed, loc, .{}),
        // `@#'x` / `(deref a-var)` reads the Var's active value, mirroring
        // the analyzer's var_ref node (tree_walk.zig). resolve returns one.
        .var_ref => v.decodePtr(*const env_mod.Var).deref(),
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
/// Future that has already eagerly evaluated the body (the
/// pre-Phase-B single-thread stand-in; real off-thread execution
/// arrives with Phase B concurrency).
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
        // A lazy seq is IPending: true once its head thunk is forced.
        .lazy_seq => if (lazy_seq_mod.isRealised(v)) Value.true_val else Value.false_val,
        else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "realized? called on non-IPending value" }),
    };
}

/// `(force x)` — if `x` is a delay, force + return its value (memoised);
/// otherwise return `x` unchanged (clj: `(if (delay? x) (deref x) x)`).
/// The `.delay` type + macro + deref already existed; only this
/// user-facing fn was unwired.
pub fn forceFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("force", args, 1, loc);
    const v = args[0];
    if (v.tag() == .delay) return try delay_mod.force(rt, env, v, loc);
    return v;
}

/// `(delay? x)` — true iff `x` is a Delay.
pub fn delayQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("delay?", args, 1, loc);
    return if (args[0].tag() == .delay) Value.true_val else Value.false_val;
}

fn requireRef(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!ref_mod.isRef(v)) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = name,
            .expected = "ref",
            .actual = @tagName(v.tag()),
        });
    }
}

/// `(__run-in-transaction thunk)` — the `dosync` macro's expansion target;
/// runs the 0-arg thunk inside an STM transaction (Phase B #5).
pub fn runInTransactionFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("dosync", args, 1, loc);
    return lock_tx.runInTransaction(rt, env, args[0], loc);
}

/// `(ref-set r v)` — set a Ref's in-transaction value. Must run inside a
/// `dosync`; returns the new value.
pub fn refSetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ref-set", args, 2, loc);
    try requireRef("ref-set", args[0], loc);
    const tx = lock_tx.current_tx orelse
        return error_catalog.raise(.stm_no_transaction, loc, .{ .name = "ref-set" });
    return lock_tx.doSet(tx, args[0].decodePtr(*ref_mod.Ref), args[1]);
}

/// `(alter r f & args)` — in-transaction `(ref-set r (apply f (deref r) args))`.
pub fn alterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityMin("alter", args, 2, loc);
    try requireRef("alter", args[0], loc);
    const tx = lock_tx.current_tx orelse
        return error_catalog.raise(.stm_no_transaction, loc, .{ .name = "alter" });
    const ref = args[0].decodePtr(*ref_mod.Ref);
    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(rt.gpa);
    try call_args.append(rt.gpa, lock_tx.doGet(tx, ref));
    try call_args.appendSlice(rt.gpa, args[2..]);
    const vtable = rt.vtable orelse return error.InternalError;
    const newval = try vtable.callFn(rt, env, args[1], call_args.items, loc);
    return lock_tx.doSet(tx, ref, newval);
}

/// `(commute r f & args)` — like `alter`, but `f` is re-applied against the
/// committed value at commit (order-independent), so a commuted ref never
/// conflicts/retries. `f` must be commutative (the user's contract).
pub fn commuteFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityMin("commute", args, 2, loc);
    try requireRef("commute", args[0], loc);
    const tx = lock_tx.current_tx orelse
        return error_catalog.raise(.stm_no_transaction, loc, .{ .name = "commute" });
    return lock_tx.doCommute(rt, env, tx, args[0].decodePtr(*ref_mod.Ref), args[1], args[2..], loc);
}

/// `(ensure r)` — read-lock a Ref in the transaction so no peer writes it under
/// us (write-skew prevention); returns r's in-transaction value.
pub fn ensureFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ensure", args, 1, loc);
    try requireRef("ensure", args[0], loc);
    const tx = lock_tx.current_tx orelse
        return error_catalog.raise(.stm_no_transaction, loc, .{ .name = "ensure" });
    return lock_tx.doEnsure(tx, args[0].decodePtr(*ref_mod.Ref));
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "ref", .f = &refFn },
    .{ .name = "deref", .f = &derefFn },
    .{ .name = "__run-in-transaction", .f = &runInTransactionFn },
    .{ .name = "ref-set", .f = &refSetFn },
    .{ .name = "alter", .f = &alterFn },
    .{ .name = "commute", .f = &commuteFn },
    .{ .name = "ensure", .f = &ensureFn },
    .{ .name = "__delay-create", .f = &delayCreateFn },
    .{ .name = "__future-call", .f = &futureCallFn },
    .{ .name = "promise", .f = &promiseFn },
    .{ .name = "deliver", .f = &deliverFn },
    .{ .name = "realized?", .f = &realizedQFn },
    .{ .name = "force", .f = &forceFn },
    .{ .name = "delay?", .f = &delayQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
