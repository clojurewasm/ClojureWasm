// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Atom and Volatile builtins — atom, deref, swap!, reset!, volatile!, vreset!, volatile?
//!
//! Atoms provide mutable reference semantics in Clojure.
//! Volatiles provide non-atomic mutable references (thread-local mutation).
//! Watchers and validators supported via add-watch, remove-watch, set-validator!, get-validator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Atom = value_mod.Atom;
const Volatile = value_mod.Volatile;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const bootstrap = @import("../runtime/bootstrap.zig");
const err = @import("../runtime/error.zig");
const thread_pool_mod = @import("../runtime/thread_pool.zig");
const env_mod = @import("../runtime/env.zig");

/// (atom val) => #<atom val>
pub fn atomFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to atom", .{args.len});
    const a = try allocator.create(Atom);
    a.* = .{ .value = args[0] };
    return Value.initAtom(a);
}

/// (deref ref) => val  — works on atoms, volatiles, delays, vars, promises
pub fn derefFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        return switch (args[0].tag()) {
            .atom => derefAtom(allocator, args[0].asAtom()),
            .volatile_ref => args[0].asVolatile().value,
            .var_ref => args[0].asVarRef().deref(),
            .reduced => args[0].asReduced().value,
            .delay => forceDelay(allocator, args[0].asDelay()),
            .future => derefFuture(args[0].asFuture()),
            .promise => derefPromise(args[0].asPromise()),
            .agent => derefAgent(args[0].asAgent()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "deref expects an atom or volatile, got {s}", .{@tagName(args[0].tag())}),
        };
    }
    // 3-arity: (deref ref timeout-ms timeout-val)
    if (args.len == 3) {
        const timeout_ms: u64 = switch (args[1].tag()) {
            .integer => @intCast(@max(0, args[1].asInteger())),
            else => return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "deref timeout must be an integer" }),
        };
        return switch (args[0].tag()) {
            .future => derefFutureWithTimeout(args[0].asFuture(), timeout_ms, args[2]),
            .promise => derefPromiseWithTimeout(args[0].asPromise(), timeout_ms, args[2]),
            .delay => forceDelay(allocator, args[0].asDelay()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "3-arity deref requires a future, promise, or delay, got {s}", .{@tagName(args[0].tag())}),
        };
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to deref", .{args.len});
}

fn derefAtom(_: Allocator, a: *Atom) Value {
    return a.value;
}

/// Force a Delay value: evaluate thunk on first access, cache result.
/// Exception caching: if thunk throws, the exception is cached and re-thrown
/// on subsequent force calls (JVM Delay semantics).
pub fn forceDelay(allocator: Allocator, d: *value_mod.Delay) anyerror!Value {
    if (d.realized) {
        if (d.getErrorCached()) |cached_ex| {
            // Re-throw the cached exception
            bootstrap.last_thrown_exception = cached_ex;
            return error.UserException;
        }
        return d.getCached() orelse Value.nil_val;
    }
    const thunk = d.getFnVal() orelse return Value.nil_val;
    const result = bootstrap.callFnVal(allocator, thunk, &.{}) catch |e| {
        // Cache the exception value for re-throwing on subsequent calls
        d.realized = true;
        d.clearFnVal();
        if (e == error.UserException) {
            d.setErrorCached(bootstrap.last_thrown_exception orelse Value.nil_val);
        }
        return e;
    };
    d.setCached(result);
    d.clearFnVal();
    d.realized = true;
    return result;
}

/// Deref a Future value: block until result is available.
fn derefFuture(f: *value_mod.FutureObj) Value {
    const result: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(f.result));
    return result.get();
}

/// Deref a Future value with timeout (milliseconds).
/// Returns timeout_val if the future doesn't complete in time.
fn derefFutureWithTimeout(f: *value_mod.FutureObj, timeout_ms: u64, timeout_val: Value) Value {
    const result: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(f.result));
    return result.getWithTimeout(timeout_ms * std.time.ns_per_ms) orelse timeout_val;
}

/// Deref a Promise value: block until delivered.
fn derefPromise(p: *value_mod.PromiseObj) Value {
    const sync: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(p.sync));
    return sync.get();
}

/// Deref a Promise value with timeout (milliseconds).
fn derefPromiseWithTimeout(p: *value_mod.PromiseObj, timeout_ms: u64, timeout_val: Value) Value {
    const sync: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(p.sync));
    return sync.getWithTimeout(timeout_ms * std.time.ns_per_ms) orelse timeout_val;
}

/// Deref an Agent: return current state (non-blocking).
fn derefAgent(a: *value_mod.AgentObj) Value {
    const inner = a.getInner();
    return inner.state;
}

/// (__delay-create thunk-fn) => delay value
pub fn delayCreateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __delay-create", .{args.len});
    const d = try allocator.create(value_mod.Delay);
    d.* = .{ .fn_val = args[0], .cached = value_mod.NO_VALUE, .error_cached = value_mod.NO_VALUE, .realized = false };
    return Value.initDelay(d);
}

/// (reset! atom new-val) => new-val
pub fn resetBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset!", .{args.len});
    return switch (args[0].tag()) {
        .atom => {
            const a = args[0].asAtom();
            try validate(allocator, a, args[1]);
            const old = a.value;
            a.value = args[1];
            try notifyWatchers(allocator, a, args[0], old, args[1]);
            return args[1];
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "reset! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (swap! atom f) => (f @atom)
/// (swap! atom f x y ...) => (f @atom x y ...)
/// Supports builtin_fn directly and fn_val via call_fn dispatcher.
pub fn swapBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap!", .{args.len});
    const atom_ptr = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "swap! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };

    const fn_val = args[1];
    const extra_args = args[2..];

    // Build call args: [current-val, extra-args...]
    const total = 1 + extra_args.len;
    var call_args: [256]Value = undefined;
    if (total > call_args.len) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap!", .{args.len});
    call_args[0] = atom_ptr.value;
    for (extra_args, 0..) |arg, i| {
        call_args[1 + i] = arg;
    }

    const new_val = bootstrap.callFnVal(allocator, fn_val, call_args[0..total]) catch |e| return e;

    try validate(allocator, atom_ptr, new_val);
    const old_val = atom_ptr.value;
    atom_ptr.value = new_val;
    try notifyWatchers(allocator, atom_ptr, args[0], old_val, new_val);
    return new_val;
}

/// (reset-vals! atom new-val) => [old-val new-val]
pub fn resetValsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset-vals!", .{args.len});
    return switch (args[0].tag()) {
        .atom => {
            const a = args[0].asAtom();
            const old = a.value;
            a.value = args[1];
            const items = try allocator.alloc(Value, 2);
            items[0] = old;
            items[1] = args[1];
            const vec = try allocator.create(value_mod.PersistentVector);
            vec.* = .{ .items = items };
            return Value.initVector(vec);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "reset-vals! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (swap-vals! atom f) => [old-val new-val]
/// (swap-vals! atom f x y ...) => [old-val (f @atom x y ...)]
pub fn swapValsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap-vals!", .{args.len});
    const atom_ptr = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "swap-vals! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };

    const fn_val = args[1];
    const extra_args = args[2..];

    // Build call args: [current-val, extra-args...]
    const total = 1 + extra_args.len;
    var call_args: [256]Value = undefined;
    if (total > call_args.len) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap-vals!", .{args.len});
    call_args[0] = atom_ptr.value;
    for (extra_args, 0..) |arg, i| {
        call_args[1 + i] = arg;
    }

    const old = atom_ptr.value;
    const new_val = bootstrap.callFnVal(allocator, fn_val, call_args[0..total]) catch |e| return e;

    atom_ptr.value = new_val;

    const items = try allocator.alloc(Value, 2);
    items[0] = old;
    items[1] = new_val;
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (volatile! val) => #<volatile val>
pub fn volatileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to volatile!", .{args.len});
    const v = try allocator.create(Volatile);
    v.* = .{ .value = args[0] };
    return Value.initVolatile(v);
}

/// (vreset! vol new-val) => new-val
pub fn vresetBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vreset!", .{args.len});
    return switch (args[0].tag()) {
        .volatile_ref => {
            const v = args[0].asVolatile();
            v.value = args[1];
            return args[1];
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "vreset! expects a volatile, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (volatile? x) => true if x is a volatile
pub fn volatilePred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to volatile?", .{args.len});
    return Value.initBoolean(args[0].tag() == .volatile_ref);
}

// ============================================================
// Watchers & Validators
// ============================================================

/// Validate new value against atom's validator. Throws on invalid.
fn validate(allocator: Allocator, a: *Atom, new_val: Value) !void {
    if (a.validator) |vfn| {
        const result = bootstrap.callFnVal(allocator, vfn, &.{new_val}) catch {
            return throwInvalidState(allocator);
        };
        switch (result.tag()) {
            .boolean => {
                if (!result.asBoolean()) return throwInvalidState(allocator);
            },
            .nil => return throwInvalidState(allocator),
            else => {},
        }
    }
}

/// Throw "Invalid reference state" as a catchable UserException (ex-info format).
fn throwInvalidState(allocator: Allocator) !void {
    // Build {:__ex_info true :message "Invalid reference state" :data {} :cause nil :__ex_type ...}
    const entries = allocator.alloc(Value, 10) catch return error.OutOfMemory;
    const empty_map = allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
    empty_map.* = .{ .entries = &.{} };
    entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_info" });
    entries[1] = Value.true_val;
    entries[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
    entries[3] = Value.initString(allocator, "Invalid reference state");
    entries[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "data" });
    entries[5] = Value.initMap(empty_map);
    entries[6] = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
    entries[7] = Value.nil_val;
    entries[8] = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_type" });
    entries[9] = Value.initString(allocator, "IllegalStateException");
    const map = allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
    map.* = .{ .entries = entries };
    bootstrap.last_thrown_exception = Value.initMap(map);
    return error.UserException;
}

/// Notify all watchers: (watch-fn key atom old-val new-val)
fn notifyWatchers(allocator: Allocator, a: *Atom, atom_val: Value, old: Value, new: Value) !void {
    if (a.watch_keys == null or a.watch_count == 0) return;
    const keys = a.watch_keys.?;
    const fns = a.watch_fns.?;
    for (0..a.watch_count) |i| {
        _ = bootstrap.callFnVal(allocator, fns[i], &.{ keys[i], atom_val, old, new }) catch {};
    }
}

/// (add-watch atom key fn)
pub fn addWatchFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to add-watch", .{args.len});
    const a = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "add-watch expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
    const max_watches = 16;
    if (a.watch_keys == null) {
        a.watch_keys = try allocator.alloc(Value, max_watches);
        a.watch_fns = try allocator.alloc(Value, max_watches);
        a.watch_count = 0;
    }
    // Replace existing watcher with same key
    for (0..a.watch_count) |i| {
        if (a.watch_keys.?[i].eql(args[1])) {
            a.watch_fns.?[i] = args[2];
            return args[0];
        }
    }
    if (a.watch_count >= max_watches) return err.setErrorFmt(.eval, .value_error, .{}, "Too many watchers on atom (max 16)", .{});
    a.watch_keys.?[a.watch_count] = args[1];
    a.watch_fns.?[a.watch_count] = args[2];
    a.watch_count += 1;
    return args[0];
}

/// (remove-watch atom key)
pub fn removeWatchFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to remove-watch", .{args.len});
    const a = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "remove-watch expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
    if (a.watch_keys == null or a.watch_count == 0) return args[0];
    for (0..a.watch_count) |i| {
        if (a.watch_keys.?[i].eql(args[1])) {
            // Shift remaining watchers
            var j = i;
            while (j + 1 < a.watch_count) : (j += 1) {
                a.watch_keys.?[j] = a.watch_keys.?[j + 1];
                a.watch_fns.?[j] = a.watch_fns.?[j + 1];
            }
            a.watch_count -= 1;
            break;
        }
    }
    return args[0];
}

/// (set-validator! atom fn)
pub fn setValidatorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set-validator!", .{args.len});
    const a = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "set-validator! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
    if (args[1].tag() == .nil) {
        a.validator = null;
    } else {
        a.validator = args[1];
    }
    return Value.nil_val;
}

/// (get-validator atom)
pub fn getValidatorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to get-validator", .{args.len});
    const a = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "get-validator expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
    return a.validator orelse Value.nil_val;
}

// ============================================================
// Future builtins
// ============================================================

/// (future-call f) => future
fn futureCallFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to future-call", .{args.len});
    const func = args[0];
    if (func.tag() != .fn_val and func.tag() != .builtin_fn and func.tag() != .multi_fn)
        return err.setErrorFmt(.eval, .type_error, .{}, "future-call expects a function, got {s}", .{@tagName(func.tag())});

    // Get or create the global thread pool
    const env: *env_mod.Env = bootstrap.macro_eval_env orelse
        return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "future-call: no eval environment" });
    const pool = thread_pool_mod.getGlobalPool(env) catch
        return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "future-call: failed to create thread pool" });

    // Submit the function to the thread pool
    const result = pool.submit(func) catch
        return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "future-call: failed to submit task" });

    // Create a FutureObj Value
    const future_obj = try allocator.create(value_mod.FutureObj);
    future_obj.kind = .future;
    future_obj.result = @ptrCast(result);
    future_obj.func = func;
    future_obj.cancelled = false;
    return Value.initFuture(future_obj);
}

/// (future? x)
fn futurePredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to future?", .{args.len});
    return if (args[0].tag() == .future) Value.true_val else Value.false_val;
}

/// (future-done? f)
fn futureDonePredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to future-done?", .{args.len});
    if (args[0].tag() != .future)
        return err.setErrorFmt(.eval, .type_error, .{}, "future-done? expects a future, got {s}", .{@tagName(args[0].tag())});
    const f = args[0].asFuture();
    const result: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(f.result));
    return if (result.isDone() or f.cancelled) Value.true_val else Value.false_val;
}

/// (future-cancel f)
fn futureCancelFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to future-cancel", .{args.len});
    if (args[0].tag() != .future)
        return err.setErrorFmt(.eval, .type_error, .{}, "future-cancel expects a future, got {s}", .{@tagName(args[0].tag())});
    const f = args[0].asFuture();
    const result: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(f.result));
    // Can only cancel if still pending
    if (!result.isDone() and !f.cancelled) {
        f.cancelled = true;
        return Value.true_val;
    }
    return Value.false_val;
}

/// (future-cancelled? f)
fn futureCancelledPredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to future-cancelled?", .{args.len});
    if (args[0].tag() != .future)
        return err.setErrorFmt(.eval, .type_error, .{}, "future-cancelled? expects a future, got {s}", .{@tagName(args[0].tag())});
    return if (args[0].asFuture().cancelled) Value.true_val else Value.false_val;
}

// ============================================================
// Promise builtins
// ============================================================

/// (promise) => promise
fn promiseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to promise", .{args.len});

    // Create the synchronization object (FutureResult)
    const sync = try allocator.create(thread_pool_mod.FutureResult);
    sync.* = thread_pool_mod.FutureResult{};

    // Create the PromiseObj
    const p = try allocator.create(value_mod.PromiseObj);
    p.kind = .promise;
    p.sync = @ptrCast(sync);

    return Value.initPromise(p);
}

/// (deliver promise val) => promise
fn deliverFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to deliver", .{args.len});
    if (args[0].tag() != .promise)
        return err.setErrorFmt(.eval, .type_error, .{}, "deliver expects a promise, got {s}", .{@tagName(args[0].tag())});

    const p = args[0].asPromise();
    const sync: *thread_pool_mod.FutureResult = @ptrCast(@alignCast(p.sync));

    // Deliver only if not already delivered (first-write-wins)
    if (!sync.isDone()) {
        sync.setResult(args[1]);
    }

    return args[0]; // return the promise
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "atom",
        .func = &atomFn,
        .doc = "Creates and returns an Atom with an initial value of x.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "deref",
        .func = &derefFn,
        .doc = "Returns the current value of atom.",
        .arglists = "([ref])",
        .added = "1.0",
    },
    .{
        .name = "reset!",
        .func = &resetBangFn,
        .doc = "Sets the value of atom to newval. Returns newval.",
        .arglists = "([atom newval])",
        .added = "1.0",
    },
    .{
        .name = "swap!",
        .func = &swapBangFn,
        .doc = "Atomically swaps the value of atom to be: (apply f current-value-of-atom args).",
        .arglists = "([atom f] [atom f x] [atom f x y] [atom f x y & args])",
        .added = "1.0",
    },
    .{
        .name = "reset-vals!",
        .func = &resetValsFn,
        .doc = "Sets the value of atom to newval. Returns [old new].",
        .arglists = "([atom newval])",
        .added = "1.9",
    },
    .{
        .name = "swap-vals!",
        .func = &swapValsFn,
        .doc = "Atomically swaps the value of atom to be: (apply f current-value-of-atom args). Returns [old new].",
        .arglists = "([atom f] [atom f x] [atom f x y] [atom f x y & args])",
        .added = "1.9",
    },
    .{
        .name = "volatile!",
        .func = &volatileFn,
        .doc = "Creates and returns a Volatile with an initial value of val.",
        .arglists = "([val])",
        .added = "1.7",
    },
    .{
        .name = "vreset!",
        .func = &vresetBangFn,
        .doc = "Sets the value of volatile to newval without regard for the current value. Returns newval.",
        .arglists = "([vol newval])",
        .added = "1.7",
    },
    .{
        .name = "volatile?",
        .func = &volatilePred,
        .doc = "Returns true if x is a volatile.",
        .arglists = "([x])",
        .added = "1.7",
    },
    .{
        .name = "__delay-create",
        .func = &delayCreateFn,
        .doc = "Creates a Delay from a thunk function.",
        .arglists = "([thunk-fn])",
        .added = "1.0",
    },
    .{
        .name = "add-watch",
        .func = &addWatchFn,
        .doc = "Adds a watch function to an atom. The watch fn must be a fn of 4 args: a key, the reference, its old-state, its new-state.",
        .arglists = "([reference key fn])",
        .added = "1.0",
    },
    .{
        .name = "remove-watch",
        .func = &removeWatchFn,
        .doc = "Removes a watch (set by add-watch) from a reference.",
        .arglists = "([reference key])",
        .added = "1.0",
    },
    .{
        .name = "set-validator!",
        .func = &setValidatorFn,
        .doc = "Sets the validator-fn for a var/ref/agent/atom.",
        .arglists = "([iref validator-fn])",
        .added = "1.0",
    },
    .{
        .name = "get-validator",
        .func = &getValidatorFn,
        .doc = "Gets the validator-fn for a var/ref/agent/atom.",
        .arglists = "([iref])",
        .added = "1.0",
    },
    .{
        .name = "future-call",
        .func = &futureCallFn,
        .doc = "Takes a function of no args and yields a future object that will invoke the function in another thread, and will cache the result and return it on all subsequent calls to deref/@.",
        .arglists = "([f])",
        .added = "1.1",
    },
    .{
        .name = "future?",
        .func = &futurePredFn,
        .doc = "Returns true if x is a future.",
        .arglists = "([x])",
        .added = "1.1",
    },
    .{
        .name = "future-done?",
        .func = &futureDonePredFn,
        .doc = "Returns true if future f is done.",
        .arglists = "([f])",
        .added = "1.1",
    },
    .{
        .name = "future-cancel",
        .func = &futureCancelFn,
        .doc = "Cancels the future, if possible.",
        .arglists = "([f])",
        .added = "1.1",
    },
    .{
        .name = "future-cancelled?",
        .func = &futureCancelledPredFn,
        .doc = "Returns true if future f is cancelled.",
        .arglists = "([f])",
        .added = "1.1",
    },
    .{
        .name = "promise",
        .func = &promiseFn,
        .doc = "Returns a promise object that can be read with deref/@, and set, once only, with deliver.",
        .arglists = "([])",
        .added = "1.1",
    },
    .{
        .name = "deliver",
        .func = &deliverFn,
        .doc = "Delivers the supplied value to the promise, releasing any pending derefs.",
        .arglists = "([promise val])",
        .added = "1.1",
    },
    .{
        .name = "agent",
        .func = &agentFn,
        .doc = "Creates and returns an agent with an initial value of state and zero or more options.",
        .arglists = "([state & options])",
        .added = "1.0",
    },
    .{
        .name = "agent-error",
        .func = &agentErrorFn,
        .doc = "Returns the exception thrown during an asynchronous action of the agent if the agent is failed. Returns nil if the agent is not failed.",
        .arglists = "([a])",
        .added = "1.2",
    },
    .{
        .name = "restart-agent",
        .func = &restartAgentFn,
        .doc = "When an agent is failed, changes the agent state to new-state and then un-fails the agent so that sends are allowed again.",
        .arglists = "([a new-state])",
        .added = "1.2",
    },
    .{
        .name = "set-error-handler!",
        .func = &setErrorHandlerFn,
        .doc = "Sets the error-handler of agent a to handler-fn.",
        .arglists = "([a handler-fn])",
        .added = "1.2",
    },
    .{
        .name = "set-error-mode!",
        .func = &setErrorModeFn,
        .doc = "Sets the error-mode of agent a to mode-keyword, which must be either :fail or :continue.",
        .arglists = "([a mode-keyword])",
        .added = "1.2",
    },
    .{
        .name = "agent?",
        .func = &agentPred,
        .doc = "Returns true if x is an agent.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "send",
        .func = &sendFn,
        .doc = "Dispatch an action to an agent. Returns the agent immediately.",
        .arglists = "([a f & args])",
        .added = "1.0",
    },
    .{
        .name = "send-off",
        .func = &sendOffFn,
        .doc = "Dispatch a potentially blocking action to an agent. Returns the agent immediately.",
        .arglists = "([a f & args])",
        .added = "1.0",
    },
    .{
        .name = "await",
        .func = &awaitFn,
        .doc = "Blocks the current thread until all actions dispatched thus far to the agent(s) have occurred.",
        .arglists = "([& agents])",
        .added = "1.0",
    },
    .{
        .name = "await-for",
        .func = &awaitForFn,
        .doc = "Blocks the current thread until all actions dispatched thus far to the agent(s) have occurred, or the timeout (in milliseconds) has elapsed.",
        .arglists = "([timeout-ms & agents])",
        .added = "1.0",
    },
    .{
        .name = "await1",
        .func = &awaitFn,
        .doc = "Internal: same as await.",
        .arglists = "([a])",
        .added = "1.0",
    },
    .{
        .name = "release-pending-sends",
        .func = &releasePendingSendsFn,
        .doc = "Normally, actions sent directly or indirectly during another action are held until the action completes (changes the agent's state). This function can be used to dispatch any pending sent actions immediately.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "agent-errors",
        .func = &agentErrorsFn,
        .doc = "DEPRECATED: Use agent-error instead.",
        .arglists = "([a])",
        .added = "1.0",
    },
    .{
        .name = "clear-agent-errors",
        .func = &clearAgentErrorsFn,
        .doc = "DEPRECATED: Use restart-agent instead.",
        .arglists = "([a])",
        .added = "1.0",
    },
};

// === Agent builtins ===

/// (agent initial-state) or (agent initial-state :error-handler fn :error-mode mode)
pub fn agentFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to agent", .{args.len});
    const initial_state = args[0];

    // Parse optional keyword args
    var error_handler = Value.nil_val;
    var error_mode = value_mod.AgentInner.ErrorMode.continue_mode;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i].tag() != .keyword) {
            return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "agent options must be keyword-value pairs" });
        }
        const kw = args[i].asKeyword();
        if (kw.ns == null) {
            if (std.mem.eql(u8, kw.name, "error-handler")) {
                error_handler = args[i + 1];
            } else if (std.mem.eql(u8, kw.name, "error-mode")) {
                if (args[i + 1].tag() == .keyword) {
                    const mode_kw = args[i + 1].asKeyword();
                    if (mode_kw.ns == null and std.mem.eql(u8, mode_kw.name, "continue")) {
                        error_mode = .continue_mode;
                    } else if (mode_kw.ns == null and std.mem.eql(u8, mode_kw.name, "fail")) {
                        error_mode = .fail_mode;
                    } else {
                        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "Invalid agent error mode, must be :continue or :fail" });
                    }
                } else {
                    return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "agent :error-mode must be a keyword" });
                }
            }
            // ignore unknown options (JVM Clojure also has :meta, :validator)
        }
    }

    // Allocate inner via page allocator (avoids GC interference with mutex)
    const page_alloc = std.heap.page_allocator;
    const inner = try page_alloc.create(value_mod.AgentInner);
    inner.* = .{
        .state = initial_state,
        .error_handler = error_handler,
        .error_mode = error_mode,
    };

    // Allocate AgentObj via GC allocator (tracked by GC)
    const agent_obj = try allocator.create(value_mod.AgentObj);
    agent_obj.* = .{ .inner = @ptrCast(inner) };
    return Value.initAgent(agent_obj);
}

/// (agent-error agent) => exception or nil
pub fn agentErrorFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to agent-error", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "agent-error expects an agent" });
    const inner = args[0].asAgent().getInner();
    return inner.error_val;
}

/// (restart-agent agent new-state) => agent
pub fn restartAgentFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to restart-agent", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "restart-agent expects an agent" });
    const inner = args[0].asAgent().getInner();
    inner.mutex.lock();
    defer inner.mutex.unlock();
    if (!inner.isInErrorState()) {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "Agent does not need restart" });
    }
    inner.state = args[1];
    inner.error_val = Value.nil_val;
    return args[0];
}

/// (set-error-handler! agent handler-fn) => agent
pub fn setErrorHandlerFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set-error-handler!", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "set-error-handler! expects an agent" });
    const inner = args[0].asAgent().getInner();
    inner.mutex.lock();
    defer inner.mutex.unlock();
    inner.error_handler = args[1];
    return args[0];
}

/// (set-error-mode! agent mode-keyword) => agent
pub fn setErrorModeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set-error-mode!", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "set-error-mode! expects an agent" });
    if (args[1].tag() != .keyword) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "set-error-mode! mode must be a keyword" });
    const mode_kw = args[1].asKeyword();
    if (mode_kw.ns != null) return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "Invalid agent error mode" });
    const inner = args[0].asAgent().getInner();
    inner.mutex.lock();
    defer inner.mutex.unlock();
    if (std.mem.eql(u8, mode_kw.name, "continue")) {
        inner.error_mode = .continue_mode;
    } else if (std.mem.eql(u8, mode_kw.name, "fail")) {
        inner.error_mode = .fail_mode;
    } else {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "Invalid agent error mode, must be :continue or :fail" });
    }
    return args[0];
}

/// (send agent fn & args) => agent
/// Dispatches an action (fn state args...) to the agent's queue.
pub fn sendFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to send", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "send expects an agent as first argument" });
    const agent_obj = args[0].asAgent();
    const inner = agent_obj.getInner();

    // Check if agent is in failed state
    if (inner.isInErrorState()) {
        return err.setError(.{ .kind = .value_error, .phase = .eval, .message = "Agent is failed, needs restart-agent" });
    }

    const page_alloc = std.heap.page_allocator;

    // Copy extra args (args beyond agent and fn)
    const extra_args = if (args.len > 2)
        page_alloc.alloc(Value, args.len - 2) catch return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: allocation failed" })
    else
        page_alloc.alloc(Value, 0) catch return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: allocation failed" });
    if (args.len > 2) @memcpy(extra_args, args[2..]);

    // Create action node
    const action = page_alloc.create(value_mod.AgentAction) catch
        return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: allocation failed" });
    action.* = .{ .func = args[1], .args = extra_args };

    // Enqueue and trigger processing
    inner.mutex.lock();
    inner.enqueue(action);
    const was_processing = inner.processing.swap(true, .acq_rel);
    inner.mutex.unlock();

    if (!was_processing) {
        // Submit agent work to thread pool
        const env_ptr = bootstrap.macro_eval_env orelse
            return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: no eval environment" });
        const pool = thread_pool_mod.getGlobalPool(env_ptr) catch
            return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: failed to get thread pool" });
        pool.submitAgentWork(agent_obj) catch
            return err.setError(.{ .kind = .internal_error, .phase = .eval, .message = "send: failed to submit work" });
    }

    return args[0]; // return the agent
}

/// (send-off agent fn & args) => agent
/// Same as send but intended for potentially blocking actions.
/// In our implementation, uses the same thread pool as send.
pub fn sendOffFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return sendFn(allocator, args);
}

/// (await & agents) => nil
/// Blocks until all actions dispatched to agents have completed.
pub fn awaitFn(_: Allocator, args: []const Value) anyerror!Value {
    for (args) |arg| {
        if (arg.tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "await expects agents" });
        const inner = arg.asAgent().getInner();
        inner.mutex.lock();
        while (inner.processing.load(.acquire) or inner.action_head != null) {
            inner.await_cond.wait(&inner.mutex);
        }
        inner.mutex.unlock();
    }
    return Value.nil_val;
}

/// (await-for timeout-ms & agents) => boolean
/// Blocks until all actions have completed or timeout (ms). Returns logical false on timeout.
pub fn awaitForFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to await-for", .{args.len});
    if (args[0].tag() != .integer) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "await-for timeout must be an integer" });
    const timeout_ms: u64 = @intCast(@max(0, args[0].asInteger()));
    const timeout_ns = timeout_ms * std.time.ns_per_ms;

    for (args[1..]) |arg| {
        if (arg.tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "await-for expects agents" });
        const inner = arg.asAgent().getInner();
        inner.mutex.lock();
        const start = std.time.nanoTimestamp();
        while (inner.processing.load(.acquire) or inner.action_head != null) {
            const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
            if (elapsed >= timeout_ns) {
                inner.mutex.unlock();
                return Value.nil_val; // timeout — return nil (logical false)
            }
            const remaining = timeout_ns - elapsed;
            inner.await_cond.timedWait(&inner.mutex, remaining) catch {};
        }
        inner.mutex.unlock();
    }
    return Value.true_val; // all completed
}

/// (agent? x) => boolean
pub fn agentPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to agent?", .{args.len});
    return if (args[0].tag() == .agent) Value.true_val else Value.false_val;
}

/// (release-pending-sends) — no-op in CW (no send buffering)
pub fn releasePendingSendsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to release-pending-sends", .{args.len});
    return Value.initInteger(0);
}

/// (agent-errors agent) — deprecated, returns nil or the error
pub fn agentErrorsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to agent-errors", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "agent-errors expects an agent" });
    const inner = args[0].asAgent().getInner();
    if (inner.isInErrorState()) {
        // Return as a list (deprecated API returns sequence of errors)
        return inner.error_val;
    }
    return Value.nil_val;
}

/// (clear-agent-errors agent) — deprecated, same as restart-agent with current state
pub fn clearAgentErrorsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clear-agent-errors", .{args.len});
    if (args[0].tag() != .agent) return err.setError(.{ .kind = .type_error, .phase = .eval, .message = "clear-agent-errors expects an agent" });
    const inner = args[0].asAgent().getInner();
    inner.mutex.lock();
    defer inner.mutex.unlock();
    inner.error_val = Value.nil_val;
    return args[0];
}

// === Tests ===

const testing = std.testing;

test "atom - create and deref" {
    const args = [_]Value{Value.initInteger(42)};
    const result = try atomFn(testing.allocator, &args);
    defer testing.allocator.destroy(result.asAtom());
    try testing.expect(result.tag() == .atom);

    const deref_args = [_]Value{result};
    const val = try derefFn(testing.allocator, &deref_args);
    try testing.expectEqual(Value.initInteger(42), val);
}

test "atom - arity error" {
    const result = atomFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "deref - type error on non-atom" {
    const args = [_]Value{Value.initInteger(42)};
    const result = derefFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "reset! - sets new value" {
    var a = Atom{ .value = Value.initInteger(1) };
    const args = [_]Value{ Value.initAtom(&a), Value.initInteger(99) };
    const result = try resetBangFn(testing.allocator, &args);
    try testing.expectEqual(Value.initInteger(99), result);
    try testing.expectEqual(Value.initInteger(99), a.value);
}

test "reset! - arity error" {
    var a = Atom{ .value = Value.nil_val };
    const args = [_]Value{Value.initAtom(&a)};
    const result = resetBangFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "swap! - with builtin_fn" {
    // Simulate (swap! a inc-like-fn) using a builtin that adds 1
    const predicates = @import("predicates.zig");
    _ = predicates; // Not needed — use a simple identity function

    // Use a hand-crafted builtin that increments
    const Helpers = struct {
        fn incFn(_: Allocator, fn_args: []const Value) anyerror!Value {
            if (fn_args.len != 1) return error.ArityError;
            return switch (fn_args[0].tag()) {
                .integer => Value.initInteger(fn_args[0].asInteger() + 1),
                else => error.TypeError,
            };
        }
    };

    var a = Atom{ .value = Value.initInteger(10) };
    const args = [_]Value{ Value.initAtom(&a), Value.initBuiltinFn(&Helpers.incFn) };
    const result = try swapBangFn(testing.allocator, &args);
    try testing.expectEqual(Value.initInteger(11), result);
    try testing.expectEqual(Value.initInteger(11), a.value);
}

test "swap! - with extra args" {
    const Helpers = struct {
        fn addFn(_: Allocator, fn_args: []const Value) anyerror!Value {
            if (fn_args.len != 2) return error.ArityError;
            return Value.initInteger(fn_args[0].asInteger() + fn_args[1].asInteger());
        }
    };

    var a = Atom{ .value = Value.initInteger(10) };
    const args = [_]Value{ Value.initAtom(&a), Value.initBuiltinFn(&Helpers.addFn), Value.initInteger(5) };
    const result = try swapBangFn(testing.allocator, &args);
    try testing.expectEqual(Value.initInteger(15), result);
    try testing.expectEqual(Value.initInteger(15), a.value);
}

test "swap! - error on fn_val without env" {
    // When macro_eval_env is not set (test env), callFnVal returns EvalError
    const Fn = value_mod.Fn;
    var a = Atom{ .value = Value.initInteger(1) };
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const args = [_]Value{ Value.initAtom(&a), Value.initFn(&fn_obj) };
    const result = swapBangFn(testing.allocator, &args);
    try testing.expectError(error.EvalError, result);
}

// === reset-vals! / swap-vals! tests ===

test "reset-vals! - returns [old new]" {
    var a = Atom{ .value = Value.initInteger(1) };
    const args = [_]Value{ Value.initAtom(&a), Value.initInteger(99) };
    const result = try resetValsFn(testing.allocator, &args);
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().items.len);
    try testing.expectEqual(Value.initInteger(1), result.asVector().items[0]);
    try testing.expectEqual(Value.initInteger(99), result.asVector().items[1]);
    try testing.expectEqual(Value.initInteger(99), a.value);
    testing.allocator.free(result.asVector().items);
    testing.allocator.destroy(result.asVector());
}

test "reset-vals! - arity error" {
    var a = Atom{ .value = Value.nil_val };
    const args = [_]Value{Value.initAtom(&a)};
    const result = resetValsFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "swap-vals! - with builtin_fn returns [old new]" {
    const Helpers = struct {
        fn incFn(_: Allocator, fn_args: []const Value) anyerror!Value {
            if (fn_args.len != 1) return error.ArityError;
            return switch (fn_args[0].tag()) {
                .integer => Value.initInteger(fn_args[0].asInteger() + 1),
                else => error.TypeError,
            };
        }
    };

    var a = Atom{ .value = Value.initInteger(10) };
    const args = [_]Value{ Value.initAtom(&a), Value.initBuiltinFn(&Helpers.incFn) };
    const result = try swapValsFn(testing.allocator, &args);
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 2), result.asVector().items.len);
    try testing.expectEqual(Value.initInteger(10), result.asVector().items[0]);
    try testing.expectEqual(Value.initInteger(11), result.asVector().items[1]);
    try testing.expectEqual(Value.initInteger(11), a.value);
    testing.allocator.free(result.asVector().items);
    testing.allocator.destroy(result.asVector());
}

test "swap-vals! - arity error" {
    var a = Atom{ .value = Value.nil_val };
    const args = [_]Value{Value.initAtom(&a)};
    const result = swapValsFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

// === Volatile tests ===

test "volatile! - create and deref" {
    const args = [_]Value{Value.initInteger(42)};
    const result = try volatileFn(testing.allocator, &args);
    defer testing.allocator.destroy(result.asVolatile());
    try testing.expect(result.tag() == .volatile_ref);

    const deref_args = [_]Value{result};
    const val = try derefFn(testing.allocator, &deref_args);
    try testing.expectEqual(Value.initInteger(42), val);
}

test "volatile! - arity error" {
    const result = volatileFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "vreset! - sets new value" {
    var v = Volatile{ .value = Value.initInteger(1) };
    const args = [_]Value{ Value.initVolatile(&v), Value.initInteger(99) };
    const result = try vresetBangFn(testing.allocator, &args);
    try testing.expectEqual(Value.initInteger(99), result);
    try testing.expectEqual(Value.initInteger(99), v.value);
}

test "vreset! - arity error" {
    var v = Volatile{ .value = Value.nil_val };
    const args = [_]Value{Value.initVolatile(&v)};
    const result = vresetBangFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "vreset! - type error on non-volatile" {
    const args = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const result = vresetBangFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "volatile? - returns true for volatile" {
    var v = Volatile{ .value = Value.nil_val };
    const args = [_]Value{Value.initVolatile(&v)};
    const result = try volatilePred(testing.allocator, &args);
    try testing.expectEqual(Value.true_val, result);
}

test "volatile? - returns false for non-volatile" {
    const args = [_]Value{Value.initInteger(42)};
    const result = try volatilePred(testing.allocator, &args);
    try testing.expectEqual(Value.false_val, result);
}
