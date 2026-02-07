// System builtins — nano-time, current-time-millis, getenv, exit
//
// These map to Java's System/ methods via internal names (__nano-time etc.).
// The Analyzer rewrite (System/nanoTime → __nano-time) is a separate task.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");

// ============================================================
// Builtins
// ============================================================

/// (__nano-time) => integer
/// Returns nanosecond timestamp (monotonic clock).
pub fn nanoTimeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to System/nanoTime", .{args.len});
    const ns: i128 = std.time.nanoTimestamp();
    // Clojure returns long (64-bit), truncate i128 to i64
    const truncated: i64 = @intCast(@as(i128, @rem(ns, std.math.maxInt(i64))));
    return Value.initInteger(truncated);
}

/// (__current-time-millis) => integer
/// Returns milliseconds since epoch (wall clock).
pub fn currentTimeMillisFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to System/currentTimeMillis", .{args.len});
    const ms = std.time.milliTimestamp();
    return Value.initInteger(ms);
}

/// (__getenv key) => string or nil
/// Returns the value of the environment variable, or nil if not set.
pub fn getenvFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to System/getenv", .{args.len});
    const key = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "System/getenv expects a string, got {s}", .{@tagName(args[0].tag())}),
    };

    // Need null-terminated key for posix getenv
    const key_z = try allocator.alloc(u8, key.len + 1);
    defer allocator.free(key_z);
    @memcpy(key_z[0..key.len], key);
    key_z[key.len] = 0;

    const result = std.posix.getenv(key_z[0..key.len]);
    if (result) |val| {
        const owned = try allocator.alloc(u8, val.len);
        @memcpy(owned, val);
        return Value.initString(allocator, owned);
    }
    return Value.nil_val;
}

/// (__exit n) => (does not return)
/// Exits the process with the given exit code.
pub fn exitFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to System/exit", .{args.len});
    const code = switch (args[0].tag()) {
        .integer => args[0].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "System/exit expects an integer, got {s}", .{@tagName(args[0].tag())}),
    };
    const exit_code: u8 = if (code >= 0 and code <= 255)
        @intCast(code)
    else
        1;
    std.process.exit(exit_code);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "__nano-time",
        .func = &nanoTimeFn,
        .doc = "Returns the current value of the running JVM's high-resolution time source, in nanoseconds.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "__current-time-millis",
        .func = &currentTimeMillisFn,
        .doc = "Returns the current time in milliseconds.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "__getenv",
        .func = &getenvFn,
        .doc = "Returns the value of the environment variable named by key, or nil.",
        .arglists = "([key])",
        .added = "1.0",
    },
    .{
        .name = "__exit",
        .func = &exitFn,
        .doc = "Terminates the currently running process with the given status code.",
        .arglists = "([status])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "nano-time returns positive integer" {
    const result = try nanoTimeFn(testing.allocator, &.{});
    try testing.expect(result.tag() == .integer);
    // Timestamp should be positive (though technically could wrap)
    try testing.expect(result.asInteger() > 0);
}

test "nano-time arity error" {
    const args = [_]Value{Value.initInteger(1)};
    const result = nanoTimeFn(testing.allocator, &args);
    try testing.expectError(error.ArityError, result);
}

test "current-time-millis returns positive integer" {
    const result = try currentTimeMillisFn(testing.allocator, &.{});
    try testing.expect(result.tag() == .integer);
    // Should be a reasonable epoch millis (> year 2020)
    try testing.expect(result.asInteger() > 1577836800000);
}

test "getenv - existing variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // PATH should always exist
    const args = [_]Value{Value.initString(alloc, "PATH")};
    const result = try getenvFn(alloc, &args);
    try testing.expect(result.tag() == .string);
    try testing.expect(result.asString().len > 0);
}

test "getenv - non-existing variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "CLJW_NONEXISTENT_VAR_12345")};
    const result = try getenvFn(alloc, &args);
    try testing.expect(result.isNil());
}

test "getenv - arity error" {
    const result = getenvFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "getenv - type error" {
    const args = [_]Value{Value.initInteger(42)};
    const result = getenvFn(testing.allocator, &args);
    try testing.expectError(error.TypeError, result);
}

// Note: exit cannot be tested (it terminates the process)
test "exit - arity error" {
    const result = exitFn(testing.allocator, &.{});
    try testing.expectError(error.ArityError, result);
}

test "exit - type error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "not a number")};
    const result = exitFn(alloc, &args);
    try testing.expectError(error.TypeError, result);
}
