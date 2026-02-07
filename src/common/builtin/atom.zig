// Atom and Volatile builtins — atom, deref, swap!, reset!, volatile!, vreset!, volatile?
//
// Atoms provide mutable reference semantics in Clojure.
// Volatiles provide non-atomic mutable references (thread-local mutation).
// Watchers and validators supported via add-watch, remove-watch, set-validator!, get-validator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Atom = value_mod.Atom;
const Volatile = value_mod.Volatile;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const bootstrap = @import("../bootstrap.zig");
const err = @import("../error.zig");

/// (atom val) => #<atom val>
pub fn atomFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to atom", .{args.len});
    const a = try allocator.create(Atom);
    a.* = .{ .value = args[0] };
    return Value.initAtom(a);
}

/// (deref ref) => val  — works on atoms, volatiles, delays, vars, promises
pub fn derefFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to deref", .{args.len});
    return switch (args[0].tag()) {
        .atom => derefAtom(allocator, args[0].asAtom()),
        .volatile_ref => args[0].asVolatile().value,
        .var_ref => args[0].asVarRef().deref(),
        .reduced => args[0].asReduced().value,
        .delay => forceDelay(allocator, args[0].asDelay()),
        else => err.setErrorFmt(.eval, .type_error, .{}, "deref expects an atom or volatile, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// Deref an atom, with special handling for promise atoms.
/// Promise atoms contain a map with :__promise key; deref returns :val from the map.
fn derefAtom(allocator: Allocator, a: *Atom) Value {
    if (a.value.tag() == .map) {
        const promise_key = Value.initKeyword(allocator, .{ .ns = null, .name = "__promise" });
        if (a.value.asMap().get(promise_key) != null) {
            const val_key = Value.initKeyword(allocator, .{ .ns = null, .name = "val" });
            return a.value.asMap().get(val_key) orelse Value.nil_val;
        }
    }
    return a.value;
}

/// Force a Delay value: evaluate thunk on first access, cache result.
/// Exception caching: if thunk throws, the exception is cached and re-thrown
/// on subsequent force calls (JVM Delay semantics).
pub fn forceDelay(allocator: Allocator, d: *value_mod.Delay) anyerror!Value {
    if (d.realized) {
        if (d.error_cached) |cached_ex| {
            // Re-throw the cached exception
            bootstrap.last_thrown_exception = cached_ex;
            return error.UserException;
        }
        return d.cached orelse Value.nil_val;
    }
    const thunk = d.fn_val orelse return Value.nil_val;
    const result = bootstrap.callFnVal(allocator, thunk, &.{}) catch |e| {
        // Cache the exception value for re-throwing on subsequent calls
        d.realized = true;
        d.fn_val = null;
        if (e == error.UserException) {
            d.error_cached = bootstrap.last_thrown_exception;
        }
        return e;
    };
    d.cached = result;
    d.fn_val = null;
    d.realized = true;
    return result;
}

/// (__delay-create thunk-fn) => delay value
pub fn delayCreateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __delay-create", .{args.len});
    const d = try allocator.create(value_mod.Delay);
    d.* = .{ .fn_val = args[0], .cached = null, .error_cached = null, .realized = false };
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
};

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
