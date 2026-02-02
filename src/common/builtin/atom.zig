// Atom builtins — atom, deref, swap!, reset!
//
// Atoms provide mutable reference semantics in Clojure.
// No watchers/validators in this minimal implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Atom = value_mod.Atom;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;

/// (atom val) => #<atom val>
pub fn atomFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const a = try allocator.create(Atom);
    a.* = .{ .value = args[0] };
    return Value{ .atom = a };
}

/// (deref atom) => val
pub fn derefFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| a.value,
        else => error.TypeError,
    };
}

/// (reset! atom new-val) => new-val
pub fn resetBangFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| {
            a.value = args[1];
            return args[1];
        },
        else => error.TypeError,
    };
}

/// (swap! atom f) => (f @atom)
/// (swap! atom f x y ...) => (f @atom x y ...)
/// Currently only supports builtin_fn as f. fn_val requires evaluator context.
pub fn swapBangFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return error.TypeError,
    };

    const fn_val = args[1];
    const extra_args = args[2..];

    // Build call args: [current-val, extra-args...]
    const total = 1 + extra_args.len;
    var call_args: [256]Value = undefined;
    if (total > call_args.len) return error.ArityError;
    call_args[0] = atom_ptr.value;
    for (extra_args, 0..) |arg, i| {
        call_args[1 + i] = arg;
    }

    const new_val = switch (fn_val) {
        .builtin_fn => |f| f(allocator, call_args[0..total]) catch |e| return e,
        else => return error.TypeError, // fn_val not yet supported
    };

    atom_ptr.value = new_val;
    return new_val;
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

test "swap! - type error on fn_val" {
    const Fn = value_mod.Fn;
    var a = Atom{ .value = .{ .integer = 1 } };
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const args = [_]Value{ .{ .atom = &a }, .{ .fn_val = &fn_obj } };
    const result = swapBangFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}
