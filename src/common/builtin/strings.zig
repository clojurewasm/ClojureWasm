// String builtins — str, pr-str
//
// str: Non-readable string conversion. Concatenates arguments without separator.
//      nil produces empty string, strings are unquoted.
// pr-str: Readable string representation. Arguments separated by space.
//         Strings are quoted, chars use backslash notation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;

/// (str) => ""
/// (str x) => string representation of x (non-readable)
/// (str x y ...) => concatenation of all args (no separator)
pub fn strFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value{ .string = "" };

    // Single arg fast path
    if (args.len == 1) {
        return strSingle(allocator, args[0]);
    }

    // Multi-arg: concatenate into buffer
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args) |arg| {
        arg.formatStr(&w) catch return error.StringTooLong;
    }
    const result = w.buffered();
    const owned = try allocator.alloc(u8, result.len);
    @memcpy(owned, result);
    return Value{ .string = owned };
}

fn strSingle(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .nil => return Value{ .string = "" },
        .string => return val, // already a string, return as-is
        else => {
            var buf: [4096]u8 = undefined;
            var w: Writer = .fixed(&buf);
            val.formatStr(&w) catch return error.StringTooLong;
            const result = w.buffered();
            const owned = try allocator.alloc(u8, result.len);
            @memcpy(owned, result);
            return Value{ .string = owned };
        },
    }
}

/// (pr-str) => ""
/// (pr-str x) => readable representation of x
/// (pr-str x y ...) => readable representations separated by space
pub fn prStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value{ .string = "" };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(" ") catch return error.StringTooLong;
        arg.formatPrStr(&w) catch return error.StringTooLong;
    }
    const result = w.buffered();
    const owned = try allocator.alloc(u8, result.len);
    @memcpy(owned, result);
    return Value{ .string = owned };
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "str",
        .kind = .runtime_fn,
        .func = &strFn,
        .doc = "With no args, returns the empty string. With one arg x, returns x.toString(). With more than one arg, returns the concatenation of the str values of the args.",
        .arglists = "([] [x] [x & ys])",
        .added = "1.0",
    },
    .{
        .name = "pr-str",
        .kind = .runtime_fn,
        .func = &prStrFn,
        .doc = "pr to a string, returning it. Prints any object to the string readable.",
        .arglists = "([& xs])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "str - no args returns empty string" {
    const result = try strFn(testing.allocator, &.{});
    try testing.expectEqualStrings("", result.string);
}

test "str - nil returns empty string" {
    const args = [_]Value{.nil};
    const result = try strFn(testing.allocator, &args);
    try testing.expectEqualStrings("", result.string);
}

test "str - string returns same string" {
    const args = [_]Value{.{ .string = "hello" }};
    const result = try strFn(testing.allocator, &args);
    try testing.expectEqualStrings("hello", result.string);
}

test "str - integer" {
    const args = [_]Value{.{ .integer = 42 }};
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("42", result.string);
}

test "str - boolean" {
    const args = [_]Value{.{ .boolean = true }};
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("true", result.string);
}

test "str - keyword" {
    const args = [_]Value{.{ .keyword = .{ .name = "foo", .ns = null } }};
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings(":foo", result.string);
}

test "str - multi-arg concatenation" {
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = " + " },
        .{ .integer = 2 },
    };
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("1 + 2", result.string);
}

test "str - nil in multi-arg is empty" {
    const args = [_]Value{
        .{ .string = "a" },
        .nil,
        .{ .string = "b" },
    };
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("ab", result.string);
}

test "pr-str - no args returns empty string" {
    const result = try prStrFn(testing.allocator, &.{});
    try testing.expectEqualStrings("", result.string);
}

test "pr-str - string is quoted" {
    const args = [_]Value{.{ .string = "hello" }};
    const result = try prStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("\"hello\"", result.string);
}

test "pr-str - nil" {
    const args = [_]Value{.nil};
    const result = try prStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("nil", result.string);
}

test "pr-str - multi-arg space separated" {
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
        .nil,
    };
    const result = try prStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("1 \"hello\" nil", result.string);
}
