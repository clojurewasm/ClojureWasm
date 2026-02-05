// Atom and Volatile builtins — atom, deref, swap!, reset!, volatile!, vreset!, volatile?
//
// Atoms provide mutable reference semantics in Clojure.
// Volatiles provide non-atomic mutable references (thread-local mutation).
// No watchers/validators in this minimal implementation.

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
    return Value{ .atom = a };
}

/// (deref ref) => val  — works on atoms, volatiles, delays, vars
pub fn derefFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to deref", .{args.len});
    return switch (args[0]) {
        .atom => |a| a.value,
        .volatile_ref => |v| v.value,
        .var_ref => |v| v.deref(),
        .reduced => |r| r.value,
        .delay => |d| forceDelay(allocator, d),
        else => err.setErrorFmt(.eval, .type_error, .{}, "deref expects an atom or volatile, got {s}", .{@tagName(args[0])}),
    };
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
        return d.cached orelse Value.nil;
    }
    const thunk = d.fn_val orelse return Value.nil;
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
    return Value{ .delay = d };
}

/// (reset! atom new-val) => new-val
pub fn resetBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset!", .{args.len});
    return switch (args[0]) {
        .atom => |a| {
            a.value = args[1];
            return args[1];
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "reset! expects an atom, got {s}", .{@tagName(args[0])}),
    };
}

/// (swap! atom f) => (f @atom)
/// (swap! atom f x y ...) => (f @atom x y ...)
/// Supports builtin_fn directly and fn_val via call_fn dispatcher.
pub fn swapBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap!", .{args.len});
    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "swap! expects an atom, got {s}", .{@tagName(args[0])}),
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

    atom_ptr.value = new_val;
    return new_val;
}

/// (reset-vals! atom new-val) => [old-val new-val]
pub fn resetValsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reset-vals!", .{args.len});
    return switch (args[0]) {
        .atom => |a| {
            const old = a.value;
            a.value = args[1];
            const items = try allocator.alloc(Value, 2);
            items[0] = old;
            items[1] = args[1];
            const vec = try allocator.create(value_mod.PersistentVector);
            vec.* = .{ .items = items };
            return Value{ .vector = vec };
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "reset-vals! expects an atom, got {s}", .{@tagName(args[0])}),
    };
}

/// (swap-vals! atom f) => [old-val new-val]
/// (swap-vals! atom f x y ...) => [old-val (f @atom x y ...)]
pub fn swapValsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to swap-vals!", .{args.len});
    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "swap-vals! expects an atom, got {s}", .{@tagName(args[0])}),
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
    return Value{ .vector = vec };
}

/// (volatile! val) => #<volatile val>
pub fn volatileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to volatile!", .{args.len});
    const v = try allocator.create(Volatile);
    v.* = .{ .value = args[0] };
    return Value{ .volatile_ref = v };
}

/// (vreset! vol new-val) => new-val
pub fn vresetBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vreset!", .{args.len});
    return switch (args[0]) {
        .volatile_ref => |v| {
            v.value = args[1];
            return args[1];
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "vreset! expects a volatile, got {s}", .{@tagName(args[0])}),
    };
}

/// (volatile? x) => true if x is a volatile
pub fn volatilePred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to volatile?", .{args.len});
    return Value{ .boolean = args[0] == .volatile_ref };
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
};

// === Tests ===

const testing = std.testing;

test "atom - create and deref" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = try atomFn(testing.allocator, &args);
    defer testing.allocator.destroy(result.atom);
    try testing.expect(result == .atom);

    const deref_args = [_]Value{result};
    const val = try derefFn(testing.allocator, &deref_args);
    try testing.expectEqual(Value{ .integer = 42 }, val);
}

test "atom - arity error" {
    const result = atomFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "deref - type error on non-atom" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = derefFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "reset! - sets new value" {
    var a = Atom{ .value = .{ .integer = 1 } };
    const args = [_]Value{ .{ .atom = &a }, .{ .integer = 99 } };
    const result = try resetBangFn(testing.allocator, &args);
    try testing.expectEqual(Value{ .integer = 99 }, result);
    try testing.expectEqual(Value{ .integer = 99 }, a.value);
}

test "reset! - arity error" {
    var a = Atom{ .value = .nil };
    const args = [_]Value{.{ .atom = &a }};
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
            return switch (fn_args[0]) {
                .integer => |n| Value{ .integer = n + 1 },
                else => error.TypeError,
            };
        }
    };

    var a = Atom{ .value = .{ .integer = 10 } };
    const args = [_]Value{ .{ .atom = &a }, .{ .builtin_fn = &Helpers.incFn } };
    const result = try swapBangFn(testing.allocator, &args);
    try testing.expectEqual(Value{ .integer = 11 }, result);
    try testing.expectEqual(Value{ .integer = 11 }, a.value);
}

test "swap! - with extra args" {
    const Helpers = struct {
        fn addFn(_: Allocator, fn_args: []const Value) anyerror!Value {
            if (fn_args.len != 2) return error.ArityError;
            return Value{ .integer = fn_args[0].integer + fn_args[1].integer };
        }
    };

    var a = Atom{ .value = .{ .integer = 10 } };
    const args = [_]Value{ .{ .atom = &a }, .{ .builtin_fn = &Helpers.addFn }, .{ .integer = 5 } };
    const result = try swapBangFn(testing.allocator, &args);
    try testing.expectEqual(Value{ .integer = 15 }, result);
    try testing.expectEqual(Value{ .integer = 15 }, a.value);
}

test "swap! - error on fn_val without env" {
    // When macro_eval_env is not set (test env), callFnVal returns EvalError
    const Fn = value_mod.Fn;
    var a = Atom{ .value = .{ .integer = 1 } };
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const args = [_]Value{ .{ .atom = &a }, .{ .fn_val = &fn_obj } };
    const result = swapBangFn(testing.allocator, &args);
    try testing.expectError(error.EvalError, result);
}

// === reset-vals! / swap-vals! tests ===

test "reset-vals! - returns [old new]" {
    var a = Atom{ .value = .{ .integer = 1 } };
    const args = [_]Value{ .{ .atom = &a }, .{ .integer = 99 } };
    const result = try resetValsFn(testing.allocator, &args);
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, result.vector.items[0]);
    try testing.expectEqual(Value{ .integer = 99 }, result.vector.items[1]);
    try testing.expectEqual(Value{ .integer = 99 }, a.value);
    testing.allocator.free(result.vector.items);
    testing.allocator.destroy(result.vector);
}

test "reset-vals! - arity error" {
    var a = Atom{ .value = .nil };
    const args = [_]Value{.{ .atom = &a }};
    const result = resetValsFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "swap-vals! - with builtin_fn returns [old new]" {
    const Helpers = struct {
        fn incFn(_: Allocator, fn_args: []const Value) anyerror!Value {
            if (fn_args.len != 1) return error.ArityError;
            return switch (fn_args[0]) {
                .integer => |n| Value{ .integer = n + 1 },
                else => error.TypeError,
            };
        }
    };

    var a = Atom{ .value = .{ .integer = 10 } };
    const args = [_]Value{ .{ .atom = &a }, .{ .builtin_fn = &Helpers.incFn } };
    const result = try swapValsFn(testing.allocator, &args);
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 2), result.vector.items.len);
    try testing.expectEqual(Value{ .integer = 10 }, result.vector.items[0]);
    try testing.expectEqual(Value{ .integer = 11 }, result.vector.items[1]);
    try testing.expectEqual(Value{ .integer = 11 }, a.value);
    testing.allocator.free(result.vector.items);
    testing.allocator.destroy(result.vector);
}

test "swap-vals! - arity error" {
    var a = Atom{ .value = .nil };
    const args = [_]Value{.{ .atom = &a }};
    const result = swapValsFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

// === Volatile tests ===

test "volatile! - create and deref" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = try volatileFn(testing.allocator, &args);
    defer testing.allocator.destroy(result.volatile_ref);
    try testing.expect(result == .volatile_ref);

    const deref_args = [_]Value{result};
    const val = try derefFn(testing.allocator, &deref_args);
    try testing.expectEqual(Value{ .integer = 42 }, val);
}

test "volatile! - arity error" {
    const result = volatileFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "vreset! - sets new value" {
    var v = Volatile{ .value = .{ .integer = 1 } };
    const args = [_]Value{ .{ .volatile_ref = &v }, .{ .integer = 99 } };
    const result = try vresetBangFn(testing.allocator, &args);
    try testing.expectEqual(Value{ .integer = 99 }, result);
    try testing.expectEqual(Value{ .integer = 99 }, v.value);
}

test "vreset! - arity error" {
    var v = Volatile{ .value = .nil };
    const args = [_]Value{.{ .volatile_ref = &v }};
    const result = vresetBangFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "vreset! - type error on non-volatile" {
    const args = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const result = vresetBangFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

test "volatile? - returns true for volatile" {
    var v = Volatile{ .value = .nil };
    const args = [_]Value{.{ .volatile_ref = &v }};
    const result = try volatilePred(testing.allocator, &args);
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "volatile? - returns false for non-volatile" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = try volatilePred(testing.allocator, &args);
    try testing.expectEqual(Value{ .boolean = false }, result);
}
