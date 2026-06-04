// SPDX-License-Identifier: EPL-2.0
//! Atom primitives — `atom` / `swap!` / `reset!` / `compare-and-set!`.
//!
//! The mutable cell + GC trace live in `runtime/atom.zig` (Layer 0).
//! `deref` / `@` for atoms is handled by the shared IDeref dispatcher in
//! `stm.zig` + the `@` reader macro. Watches + validators are wired
//! (ADR-0081 / D-157). Real CAS-under-contention is Phase B
//! (concurrency) — single-threaded now, so `swap!` needs no CAS-retry
//! loop (no contention exists; a no-op loop would be a smell).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const atom_mod = @import("../../runtime/atom.zig");
const volatile_mod = @import("../../runtime/volatile.zig");
const higher_order = @import("higher_order.zig");
const map_mod = @import("../../runtime/collection/map.zig");
const list_mod = @import("../../runtime/collection/list.zig");
const ex_info = @import("../../runtime/collection/ex_info.zig");

/// Run the atom's validator (if any) against the proposed `newval` BEFORE the
/// change is committed (ADR-0081). A falsey return throws IllegalStateException
/// "Invalid reference state" — the caller must NOT commit (clj parity: the ref
/// is left unchanged). A validator that itself throws propagates as-is.
fn validateOrThrow(rt: *Runtime, env: *Env, a: Value, newval: Value, loc: SourceLocation) !void {
    const v = atom_mod.validatorOf(a);
    if (v.isNil()) return;
    const ok = try higher_order.invokeCallable(rt, env, v, &[_]Value{newval}, loc);
    if (!ok.isTruthy()) {
        dispatch.last_thrown_exception = try ex_info.allocException(rt, "Invalid reference state", "IllegalStateException");
        return error.ThrownValue;
    }
}

/// Fire the atom's watches synchronously after a state change (ADR-0081 /
/// D-157): for each `{key → fn}` registered by `add-watch`, call
/// `(fn key ref old new)`. clj fires on EVERY change (incl. `old == new`),
/// so callers invoke this unconditionally after the in-place set. A
/// zero-watch atom (`watches == nil`) returns immediately — the common path
/// allocates nothing. The watches map is snapshotted (a re-entrant `swap!`
/// inside a watch fn reads the already-committed `current`, matching clj).
fn notifyWatches(rt: *Runtime, env: *Env, a: Value, old: Value, new: Value, loc: SourceLocation) !void {
    const watches = atom_mod.watchesOf(a);
    if (watches.tag() != .array_map and watches.tag() != .hash_map) return;
    if (map_mod.count(watches) == 0) return;
    var cur = try map_mod.keys(rt, watches);
    while (!cur.isNil()) {
        const key = list_mod.first(cur);
        const f = try map_mod.get(watches, key);
        const cb = [_]Value{ key, a, old, new };
        _ = try higher_order.invokeCallable(rt, env, f, &cb, loc);
        cur = list_mod.rest(cur);
    }
}

fn requireAtom(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!atom_mod.isAtom(v)) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = name,
            .expected = "atom",
            .actual = @tagName(v.tag()),
        });
    }
}

/// `(atom x)` — construct an atom holding x. (JVM also accepts
/// `:meta` / `:validator` ctor kwargs; those are not accepted yet
/// — D-157. `set-validator!` / `add-watch` are already wired.)
pub fn atomFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("atom", args, 1, loc);
    return try atom_mod.alloc(rt, args[0]);
}

/// `(reset! a newval)` — set the atom to newval, return newval.
pub fn resetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("reset!", args, 2, loc);
    try requireAtom("reset!", args[0], loc);
    const old = atom_mod.current(args[0]);
    try validateOrThrow(rt, env, args[0], args[1], loc);
    atom_mod.setCurrent(args[0], args[1]);
    try notifyWatches(rt, env, args[0], old, args[1], loc);
    return args[1];
}

/// `(swap! a f & args)` — set the atom to `(apply f current args)` and
/// return the new value.
pub fn swapFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2) {
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "swap!", .got = args.len, .min = 2 });
    }
    try requireAtom("swap!", args[0], loc);
    const a = args[0];
    const f = args[1];
    // CAS-retry (JVM Atom.swap): read current, compute (f current args...),
    // install iff current is still unchanged, else retry with a fresh read. f
    // may run more than once under contention — the documented swap! contract
    // (f must be side-effect-free). Without the CAS, concurrent swaps lose
    // updates wholesale (4×100 increments landing ~250 instead of 400).
    while (true) {
        const old = atom_mod.current(a);
        var call_args: std.ArrayList(Value) = .empty;
        defer call_args.deinit(rt.gpa);
        try call_args.append(rt.gpa, old);
        try call_args.appendSlice(rt.gpa, args[2..]);
        const newval = try higher_order.invokeCallable(rt, env, f, call_args.items, loc);
        try validateOrThrow(rt, env, a, newval, loc);
        if (atom_mod.compareAndSet(a, old, newval)) {
            try notifyWatches(rt, env, a, old, newval, loc);
            return newval;
        }
    }
}

/// `(compare-and-set! a old new)` — set to new iff current is IDENTICAL
/// to old (JVM `AtomicReference.compareAndSet` — reference identity, NOT
/// `=`). Returns true on success, false otherwise.
pub fn compareAndSetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("compare-and-set!", args, 3, loc);
    try requireAtom("compare-and-set!", args[0], loc);
    // Validate the candidate before the CAS (JVM validates `new` regardless of
    // whether the swap lands), then a single atomic compare-and-set by identity.
    try validateOrThrow(rt, env, args[0], args[2], loc);
    if (atom_mod.compareAndSet(args[0], args[1], args[2])) {
        try notifyWatches(rt, env, args[0], args[1], args[2], loc);
        return Value.true_val;
    }
    return Value.false_val;
}

// --- volatile (unsynchronized mutable box: volatile! / vreset! / vswap! / volatile?) ---

fn requireVolatile(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!volatile_mod.isVolatile(v)) {
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "volatile", .actual = @tagName(v.tag()) });
    }
}

/// `(volatile! x)` — construct a volatile holding x.
pub fn volatileBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("volatile!", args, 1, loc);
    return try volatile_mod.alloc(rt, args[0]);
}

/// `(vreset! v newval)` — set the volatile to newval, return newval.
pub fn vresetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("vreset!", args, 2, loc);
    try requireVolatile("vreset!", args[0], loc);
    volatile_mod.setCurrent(args[0], args[1]);
    return args[1];
}

/// `(vswap! v f & args)` — set the volatile to `(apply f current args)`,
/// return the new value. No CAS / retry (volatiles are unsynchronized).
pub fn vswapFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2) {
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "vswap!", .got = args.len, .min = 2 });
    }
    try requireVolatile("vswap!", args[0], loc);
    const vol = args[0];
    const f = args[1];
    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(rt.gpa);
    try call_args.append(rt.gpa, volatile_mod.current(vol));
    try call_args.appendSlice(rt.gpa, args[2..]);
    const newval = try higher_order.invokeCallable(rt, env, f, call_args.items, loc);
    volatile_mod.setCurrent(vol, newval);
    return newval;
}

/// `(volatile? x)` — true iff x is a volatile.
pub fn volatileQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("volatile?", args, 1, loc);
    return if (volatile_mod.isVolatile(args[0])) Value.true_val else Value.false_val;
}

// --- watches (add-watch / remove-watch) — ADR-0081 / D-157 ---

/// `(add-watch ref key fn)` — register `fn` (called `(fn key ref old new)` on
/// every state change) under `key`; an existing key is replaced. Returns ref.
pub fn addWatchFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("add-watch", args, 3, loc);
    try requireAtom("add-watch", args[0], loc);
    const cur = atom_mod.watchesOf(args[0]);
    const base = if (cur.tag() == .array_map or cur.tag() == .hash_map) cur else map_mod.empty();
    const next = try map_mod.assoc(rt, base, args[1], args[2]);
    atom_mod.setWatches(args[0], next);
    return args[0];
}

/// `(remove-watch ref key)` — drop the watch under `key` (no-op if absent).
/// Returns ref.
pub fn removeWatchFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("remove-watch", args, 2, loc);
    try requireAtom("remove-watch", args[0], loc);
    const cur = atom_mod.watchesOf(args[0]);
    if (cur.tag() != .array_map and cur.tag() != .hash_map) return args[0];
    const next = try map_mod.dissoc(rt, cur, args[1]);
    atom_mod.setWatches(args[0], next);
    return args[0];
}

// --- validators (set-validator! / get-validator) — ADR-0081 ---

/// `(set-validator! ref f)` — install validator `f` (or `nil` to clear). clj
/// validates the CURRENT value against the new validator immediately and throws
/// IllegalStateException if it fails. Returns nil.
pub fn setValidatorFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("set-validator!", args, 2, loc);
    try requireAtom("set-validator!", args[0], loc);
    const f = args[1];
    if (!f.isNil()) {
        const ok = try higher_order.invokeCallable(rt, env, f, &[_]Value{atom_mod.current(args[0])}, loc);
        if (!ok.isTruthy()) {
            dispatch.last_thrown_exception = try ex_info.allocException(rt, "Invalid reference state", "IllegalStateException");
            return error.ThrownValue;
        }
    }
    atom_mod.setValidator(args[0], f);
    return Value.nil_val;
}

/// `(get-validator ref)` — the installed validator fn, or nil.
pub fn getValidatorFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("get-validator", args, 1, loc);
    try requireAtom("get-validator", args[0], loc);
    return atom_mod.validatorOf(args[0]);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "atom", .f = &atomFn },
    .{ .name = "swap!", .f = &swapFn },
    .{ .name = "reset!", .f = &resetFn },
    .{ .name = "compare-and-set!", .f = &compareAndSetFn },
    .{ .name = "add-watch", .f = &addWatchFn },
    .{ .name = "remove-watch", .f = &removeWatchFn },
    .{ .name = "set-validator!", .f = &setValidatorFn },
    .{ .name = "get-validator", .f = &getValidatorFn },
    .{ .name = "volatile!", .f = &volatileBangFn },
    .{ .name = "vreset!", .f = &vresetFn },
    .{ .name = "vswap!", .f = &vswapFn },
    .{ .name = "volatile?", .f = &volatileQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
