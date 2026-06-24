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
const worker_error = @import("../../runtime/concurrency/worker_error.zig");
const lazy_seq_mod = @import("../../runtime/lazy_seq.zig");
const atom_mod = @import("../../runtime/atom.zig");
const agent_mod = @import("../../runtime/agent.zig");
const volatile_mod = @import("../../runtime/volatile.zig");
const reduced_mod = @import("../../runtime/collection/reduced.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const iref = @import("../../runtime/iref.zig");

/// `(ref init & {:keys [meta validator min-history max-history]})` — construct a
/// Tier A STM Ref seeded with `init` (clj `clojure.core/ref`). `:validator`
/// validates the INITIAL value (clj `ARef.setValidator`), so
/// `(ref -1 :validator pos?)` throws IllegalStateException. `:meta` stores the
/// metadata map (observable via `(meta r)`); `:min-history` / `:max-history` set
/// the ring history bounds (clj `Ref.setMinHistory` / `setMaxHistory`). Unknown
/// keys are ignored; an odd-length options tail is an error.
pub fn refFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1)
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "ref", .got = args.len, .min = 1 });
    const r = try ref_mod.alloc(rt, args[0]);
    if (args.len == 1) return r;
    if ((args.len - 1) % 2 != 0)
        return error_catalog.raise(.ref_options_odd, loc, .{ .fn_name = "ref" });

    const kw_meta = try keyword_mod.intern(rt, null, "meta");
    const kw_validator = try keyword_mod.intern(rt, null, "validator");
    const kw_min = try keyword_mod.intern(rt, null, "min-history");
    const kw_max = try keyword_mod.intern(rt, null, "max-history");
    var validator: Value = .nil_val;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const val = args[i + 1];
        if (@intFromEnum(k) == @intFromEnum(kw_meta)) {
            ref_mod.setMeta(r, val);
        } else if (@intFromEnum(k) == @intFromEnum(kw_validator)) {
            ref_mod.setValidator(r, val);
            validator = val;
        } else if (@intFromEnum(k) == @intFromEnum(kw_min)) {
            if (val.tag() == .integer) ref_mod.setMinHistory(r, @intCast(@max(0, val.asInteger())));
        } else if (@intFromEnum(k) == @intFromEnum(kw_max)) {
            if (val.tag() == .integer) ref_mod.setMaxHistory(r, @intCast(@max(0, val.asInteger())));
        }
    }
    // clj's setValidator validates the current (initial) value — throw if rejected.
    if (!validator.isNil()) try iref.validateOrThrow(rt, env, validator, args[0]);
    return r;
}

/// `(deref r)` / `@r` — return an Atom / Ref / Delay / Promise /
/// Future / Var / Volatile / Reduced current value. Every IDeref
/// arm is wired; real CAS-under-contention for atoms is Phase B.
pub fn derefFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len != 1 and args.len != 3) {
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "deref", .expected = 1, .got = args.len });
    }
    // `(deref x timeout-ms timeout-val)` — the clojure.lang.IBlockingDeref
    // surface (D-400): native future/promise take a timed wait; a deftype
    // dispatches its 3-arity `deref` impl via IBlockingDeref/-blocking-deref.
    // Anything else cannot block, so the timeout form is an error (clj:
    // ClassCastException to IBlockingDeref).
    if (args.len == 3) {
        const ref = args[0];
        if (args[1].tag() != .integer) {
            return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "deref", .actual = @tagName(args[1].tag()) });
        }
        const timeout_ms = args[1].asInteger();
        const timeout_val = args[2];
        switch (ref.tag()) {
            .future => {
                if (!future_mod.waitRealised(rt.io, ref, timeout_ms)) return timeout_val;
                // realised — fall through to the 1-arity logic below.
            },
            .promise => {
                if (!promise_mod.waitDelivered(rt.io, ref, timeout_ms)) return timeout_val;
            },
            .typed_instance, .reified_instance => {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, ref, "IBlockingDeref", "-blocking-deref", &.{ ref, args[1], timeout_val }, loc)) |r| return r;
                return timedDerefTypeError(ref, loc);
            },
            // clj throws a catchable ClassCastException for a timed deref of a
            // non-blocking reference (`(deref (atom 1) 100 :to)`), so this is a
            // `.type_error`, not the uncatchable `.not_implemented`.
            else => return timedDerefTypeError(ref, loc),
        }
    }
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
        // ADR-0120: a failed future re-raises the worker's MARSHALLED error
        // (real kind/message/location), not a generic future_thunk_failed.
        // The `future_thunk_failed` fallback only fires if the marshal yielded
        // nil (no error info — shouldn't happen at a real thunk failure).
        .future => blk: {
            if (future_mod.deref(v)) |val| break :blk val;
            // D-442 / ADR-0153: a cancelled future's deref throws a
            // CancellationException (distinct from a thunk failure).
            if (future_mod.isCancelled(v)) break :blk error_catalog.raise(.future_cancelled, loc, .{});
            if (future_mod.errorValue(v)) |ev| break :blk worker_error.reraise(ev);
            break :blk error_catalog.raise(.future_thunk_failed, loc, .{});
        },
        // `@#'x` / `(deref a-var)` reads the Var's active value, mirroring
        // the analyzer's var_ref node (tree_walk.zig). resolve returns one.
        .var_ref => v.decodePtr(*const env_mod.Var).deref(),
        // D-307: a deftype/reify implementing clojure.lang.IDeref → consult
        // IDeref/-deref (mirrors metadata.zig's IObj consult for typed_instance).
        .typed_instance, .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IDeref", "-deref", &.{v}, loc)) |r| break :blk r;
            break :blk derefTypeError(v, loc);
        },
        // A type error on the implemented `deref`, NOT a missing feature: clj
        // throws a catchable ClassCastException (`(deref 5)`) / NullPointerException
        // (`(deref nil)`), so this must be `.type_error` (catchable), not the
        // uncatchable `.not_implemented` the old `feature_not_supported` carried.
        else => derefTypeError(v, loc),
    };
}

/// A non-IDeref value reached `deref`/`@` — a CATCHABLE type error (clj:
/// ClassCastException / NullPointerException), not a missing feature. Shared
/// by the typed-instance-without-IDeref arm and the generic else arm so both
/// raise one consistent `.type_error`-Kind message (F-011, D-446 follow-up).
fn derefTypeError(v: Value, loc: SourceLocation) anyerror!Value {
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "deref",
        .expected = "a reference type (atom, ref, agent, var, delay, future, promise) or a clojure.lang.IDeref",
        .actual = @tagName(v.tag()),
    });
}

/// A non-blocking reference reached the 3-arg timed `deref` — a CATCHABLE type
/// error (clj: ClassCastException), not a missing feature.
fn timedDerefTypeError(ref: Value, loc: SourceLocation) anyerror!Value {
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "deref",
        .expected = "a blocking reference (future, promise) or a clojure.lang.IBlockingDeref",
        .actual = @tagName(ref.tag()),
    });
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
    try error_catalog.checkArity("realized?", args, 1, loc);
    const v = args[0];
    return switch (v.tag()) {
        .delay => if (delay_mod.isRealised(v)) Value.true_val else Value.false_val,
        .promise => if (promise_mod.isRealised(v)) Value.true_val else Value.false_val,
        .future => if (future_mod.isRealised(v)) Value.true_val else Value.false_val,
        .ref => Value.true_val,
        // A lazy seq is IPending: true once its head thunk is forced.
        .lazy_seq => if (lazy_seq_mod.isRealised(v)) Value.true_val else Value.false_val,
        // D-307: a deftype/reify implementing clojure.lang.IPending → consult
        // IPending/-realized?.
        .typed_instance, .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, "IPending", "-realized?", &.{v}, loc)) |r| break :blk r;
            break :blk realizedTypeError(v, loc);
        },
        // clj throws a catchable ClassCastException on a non-IPending value.
        else => realizedTypeError(v, loc),
    };
}

/// A non-IPending value reached `realized?` — a CATCHABLE type error
/// (clj: ClassCastException), not a missing feature (D-446 follow-up).
fn realizedTypeError(v: Value, loc: SourceLocation) anyerror!Value {
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "realized?",
        .expected = "an IPending (delay, future, promise, lazy seq) or a clojure.lang.IPending",
        .actual = @tagName(v.tag()),
    });
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

/// `(future? x)` — true iff x is a future.
pub fn futureQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("future?", args, 1, loc);
    return if (future_mod.isFuture(args[0])) Value.true_val else Value.false_val;
}

/// `(agent? x)` — true iff x is an agent.
pub fn agentQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("agent?", args, 1, loc);
    return if (agent_mod.isAgent(args[0])) Value.true_val else Value.false_val;
}

/// `(future-done? f)` — true iff the future has completed (value or error). clj
/// `(.isDone f)`; requires a future (a non-future is a type error).
pub fn futureDoneQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("future-done?", args, 1, loc);
    if (!future_mod.isFuture(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "future-done?", .expected = "future", .actual = @tagName(args[0].tag()) });
    return if (future_mod.isRealised(args[0])) Value.true_val else Value.false_val;
}

/// `(future-cancel f)` — D-442 / ADR-0153. Marks a still-pending future
/// `.cancelled` (its later result is discarded; deref throws); returns true if
/// it was cancelled, false if it had already realised/cancelled (clj parity).
pub fn futureCancelFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("future-cancel", args, 1, loc);
    if (!future_mod.isFuture(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "future-cancel", .expected = "future", .actual = @tagName(args[0].tag()) });
    return if (future_mod.cancel(args[0])) Value.true_val else Value.false_val;
}

/// `(future-cancelled? f)` — D-442 / ADR-0153. True iff `future-cancel` won.
pub fn futureCancelledQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("future-cancelled?", args, 1, loc);
    if (!future_mod.isFuture(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "future-cancelled?", .expected = "future", .actual = @tagName(args[0].tag()) });
    return if (future_mod.isCancelled(args[0])) Value.true_val else Value.false_val;
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

/// `(__in-transaction?)` — true iff an STM transaction is running on this thread
/// (clj `LockingTransaction/isRunning`). Backs the `io!` macro's guard so an I/O
/// form inside `dosync` (which may retry) raises instead of running repeatedly.
pub fn inTransactionFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__in-transaction?", args, 0, loc);
    return Value.initBoolean(lock_tx.inTransaction());
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "ref", .f = &refFn },
    .{ .name = "deref", .f = &derefFn },
    .{ .name = "__in-transaction?", .f = &inTransactionFn },
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
    .{ .name = "future?", .f = &futureQFn },
    .{ .name = "agent?", .f = &agentQFn },
    .{ .name = "future-done?", .f = &futureDoneQFn },
    .{ .name = "future-cancel", .f = &futureCancelFn },
    .{ .name = "future-cancelled?", .f = &futureCancelledQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
