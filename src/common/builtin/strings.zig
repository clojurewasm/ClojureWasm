// String builtins — str, pr-str
//
// str: Non-readable string conversion. Concatenates arguments without separator.
//      nil produces empty string, strings are unquoted.
// pr-str: Readable string representation. Arguments separated by space.
//         Strings are quoted, chars use backslash notation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;
const collections = @import("collections.zig");
const err = @import("../error.zig");
const keyword_intern = @import("../keyword_intern.zig");

/// (str) => ""
/// (str x) => string representation of x (non-readable)
/// (str x y ...) => concatenation of all args (no separator)
pub fn strFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value{ .string = "" };

    // Single arg fast path
    if (args.len == 1) {
        return strSingle(allocator, args[0]);
    }

    // Multi-arg: concatenate with dynamic writer
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (args) |arg| {
        const v = try collections.realizeValue(allocator, arg);
        try v.formatStr(&aw.writer);
    }
    const owned = try aw.toOwnedSlice();
    return Value{ .string = owned };
}

/// Convert a single value to its string representation.
///
/// Type-specific fast paths (24C.3): The generic path uses Writer.Allocating
/// which involves dynamic buffer management (multiple alloc/realloc/free cycles).
/// For common types (nil, string, boolean, integer, keyword), we bypass the
/// writer entirely and use stack buffers or direct construction with a single
/// allocation. This reduced string_ops from 398ms to 28ms (14x speedup), with
/// system time dropping from 312ms to 2ms (allocator overhead eliminated).
fn strSingle(allocator: Allocator, val: Value) anyerror!Value {
    // Realize lazy seqs/cons before string conversion
    const v = try collections.realizeValue(allocator, val);
    switch (v) {
        .nil => return Value{ .string = "" },
        .string => return v, // Already a string — zero-copy return
        .boolean => |b| {
            // Static literal + single dupe (no formatting overhead)
            const s: []const u8 = if (b) "true" else "false";
            const owned = try allocator.dupe(u8, s);
            return Value{ .string = owned };
        },
        .integer => |n| {
            // Stack buffer + single dupe: avoids Writer's alloc/realloc cycles
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            const owned = try allocator.dupe(u8, s);
            return Value{ .string = owned };
        },
        .keyword => |kw| {
            // Direct construction: compute exact length, single alloc, @memcpy.
            // Avoids Writer overhead for ":ns/name" or ":name" formatting.
            if (kw.ns) |ns| {
                const len = 1 + ns.len + 1 + kw.name.len;
                const owned = try allocator.alloc(u8, len);
                owned[0] = ':';
                @memcpy(owned[1 .. 1 + ns.len], ns);
                owned[1 + ns.len] = '/';
                @memcpy(owned[2 + ns.len ..], kw.name);
                return Value{ .string = owned };
            } else {
                const len = 1 + kw.name.len;
                const owned = try allocator.alloc(u8, len);
                owned[0] = ':';
                @memcpy(owned[1..], kw.name);
                return Value{ .string = owned };
            }
        },
        else => {
            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try v.formatStr(&aw.writer);
            const owned = try aw.toOwnedSlice();
            return Value{ .string = owned };
        },
    }
}

/// (pr-str) => ""
/// (pr-str x) => readable representation of x
/// (pr-str x y ...) => readable representations separated by space
pub fn prStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value{ .string = "" };

    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(" ");
        const v = try collections.realizeValue(allocator, arg);
        try v.formatPrStr(&aw.writer);
    }
    const owned = try aw.toOwnedSlice();
    return Value{ .string = owned };
}

/// (subs s start), (subs s start end) — returns substring.
pub fn subsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subs", .{args.len});
    const s = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects a string, got {s}", .{@tagName(args[0])}),
    };
    const start_i = switch (args[1]) {
        .integer => |i| i,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects an integer start, got {s}", .{@tagName(args[1])}),
    };
    if (start_i < 0 or @as(usize, @intCast(start_i)) > s.len) return err.setErrorFmt(.eval, .index_error, .{}, "String index out of range: {d}", .{start_i});
    const start: usize = @intCast(start_i);

    const end: usize = if (args.len == 3) blk: {
        const end_i = switch (args[2]) {
            .integer => |i| i,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects an integer end, got {s}", .{@tagName(args[2])}),
        };
        if (end_i < start_i or @as(usize, @intCast(end_i)) > s.len) return err.setErrorFmt(.eval, .index_error, .{}, "String index out of range: {d}", .{end_i});
        break :blk @intCast(end_i);
    } else s.len;

    const slice = s[start..end];
    const owned = try allocator.alloc(u8, slice.len);
    @memcpy(owned, slice);
    return Value{ .string = owned };
}

/// (name x) — returns the name part of a string, symbol, or keyword.
pub fn nameFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to name", .{args.len});
    return switch (args[0]) {
        .string => args[0],
        .keyword => |k| Value{ .string = k.name },
        .symbol => |s| Value{ .string = s.name },
        else => err.setErrorFmt(.eval, .type_error, .{}, "name expects a string, keyword, or symbol, got {s}", .{@tagName(args[0])}),
    };
}

/// (namespace x) — returns the namespace part of a symbol or keyword, or nil.
pub fn namespaceFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to namespace", .{args.len});
    return switch (args[0]) {
        .keyword => |k| if (k.ns) |ns| Value{ .string = ns } else Value.nil,
        .symbol => |s| if (s.ns) |ns| Value{ .string = ns } else Value.nil,
        else => err.setErrorFmt(.eval, .type_error, .{}, "namespace expects a keyword or symbol, got {s}", .{@tagName(args[0])}),
    };
}

/// (keyword x), (keyword ns name) — coerce to keyword.
pub fn keywordFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        const result: Value = switch (args[0]) {
            .keyword => args[0],
            .string => |s| .{ .keyword = .{ .name = s, .ns = null } },
            .symbol => |sym| .{ .keyword = .{ .name = sym.name, .ns = sym.ns } },
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword expects a string, keyword, or symbol, got {s}", .{@tagName(args[0])}),
        };
        keyword_intern.intern(result.keyword.ns, result.keyword.name);
        return result;
    } else if (args.len == 2) {
        const ns_str = switch (args[0]) {
            .string => |s| s,
            .nil => @as(?[]const u8, null),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword namespace expects a string or nil, got {s}", .{@tagName(args[0])}),
        };
        const name_str = switch (args[1]) {
            .string => |s| s,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword name expects a string, got {s}", .{@tagName(args[1])}),
        };
        keyword_intern.intern(ns_str, name_str);
        return Value{ .keyword = .{ .name = name_str, .ns = ns_str } };
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keyword", .{args.len});
}

/// (find-keyword name), (find-keyword ns name) — find interned keyword.
/// Returns nil if the keyword has not been interned.
pub fn findKeywordFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        // (find-keyword :foo) or (find-keyword 'foo) or (find-keyword "foo")
        const ns: ?[]const u8 = switch (args[0]) {
            .keyword => |k| k.ns,
            .symbol => |s| s.ns,
            .string => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword expects a string, keyword, or symbol, got {s}", .{@tagName(args[0])}),
        };
        const name: []const u8 = switch (args[0]) {
            .keyword => |k| k.name,
            .symbol => |s| s.name,
            .string => |s| s,
            else => unreachable,
        };
        if (keyword_intern.contains(ns, name)) {
            return Value{ .keyword = .{ .ns = ns, .name = name } };
        }
        return .nil;
    } else if (args.len == 2) {
        // (find-keyword "ns" "name")
        const ns_str: ?[]const u8 = switch (args[0]) {
            .string => |s| s,
            .nil => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword namespace expects a string, got {s}", .{@tagName(args[0])}),
        };
        const name_str: []const u8 = switch (args[1]) {
            .string => |s| s,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword name expects a string, got {s}", .{@tagName(args[1])}),
        };
        if (keyword_intern.contains(ns_str, name_str)) {
            return Value{ .keyword = .{ .ns = ns_str, .name = name_str } };
        }
        return .nil;
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-keyword", .{args.len});
}

/// (symbol x), (symbol ns name) — coerce to symbol.
pub fn symbolFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        return switch (args[0]) {
            .symbol => args[0],
            .string => |s| Value{ .symbol = .{ .name = s, .ns = null } },
            .keyword => |k| Value{ .symbol = .{ .name = k.name, .ns = k.ns } },
            else => err.setErrorFmt(.eval, .type_error, .{}, "symbol expects a string, keyword, or symbol, got {s}", .{@tagName(args[0])}),
        };
    } else if (args.len == 2) {
        const ns_str = switch (args[0]) {
            .string => |s| s,
            .nil => @as(?[]const u8, null),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "symbol namespace expects a string or nil, got {s}", .{@tagName(args[0])}),
        };
        const name_str = switch (args[1]) {
            .string => |s| s,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "symbol name expects a string, got {s}", .{@tagName(args[1])}),
        };
        return Value{ .symbol = .{ .name = name_str, .ns = ns_str } };
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to symbol", .{args.len});
}

/// (print-str) => ""
/// (print-str x) => non-readable representation of x
/// (print-str x y ...) => non-readable representations separated by space
pub fn printStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value{ .string = "" };

    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(" ");
        try arg.formatPrStr(&aw.writer);
    }
    const owned = try aw.toOwnedSlice();
    return Value{ .string = owned };
}

/// (prn-str) => "\n"
/// (prn-str x) => readable representation of x + newline
/// (prn-str x y ...) => readable representations separated by space + newline
pub fn prnStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(" ");
        try arg.formatPrStr(&aw.writer);
    }
    try aw.writer.writeAll("\n");
    const owned = try aw.toOwnedSlice();
    return Value{ .string = owned };
}

/// (println-str) => "\n"
/// (println-str x) => non-readable representation of x + newline
/// (println-str x y ...) => non-readable representations separated by space + newline
pub fn printlnStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    value_mod.setPrintAllocator(allocator);
    value_mod.setPrintReadably(false);
    defer {
        value_mod.setPrintAllocator(null);
        value_mod.setPrintReadably(true);
    }
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(" ");
        try arg.formatPrStr(&aw.writer);
    }
    try aw.writer.writeAll("\n");
    const owned = try aw.toOwnedSlice();
    return Value{ .string = owned };
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "str",
        .func = &strFn,
        .doc = "With no args, returns the empty string. With one arg x, returns x.toString(). With more than one arg, returns the concatenation of the str values of the args.",
        .arglists = "([] [x] [x & ys])",
        .added = "1.0",
    },
    .{
        .name = "pr-str",
        .func = &prStrFn,
        .doc = "pr to a string, returning it. Prints any object to the string readable.",
        .arglists = "([& xs])",
        .added = "1.0",
    },
    .{
        .name = "print-str",
        .func = &printStrFn,
        .doc = "print to a string, returning it.",
        .arglists = "([& xs])",
        .added = "1.0",
    },
    .{
        .name = "prn-str",
        .func = &prnStrFn,
        .doc = "prn to a string, returning it.",
        .arglists = "([& xs])",
        .added = "1.0",
    },
    .{
        .name = "println-str",
        .func = &printlnStrFn,
        .doc = "println to a string, returning it.",
        .arglists = "([& xs])",
        .added = "1.0",
    },
    .{
        .name = "subs",
        .func = &subsFn,
        .doc = "Returns the substring of s beginning at start inclusive, and ending at end (defaults to length of string), exclusive.",
        .arglists = "([s start] [s start end])",
        .added = "1.0",
    },
    .{
        .name = "name",
        .func = &nameFn,
        .doc = "Returns the name String of a string, symbol or keyword.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "namespace",
        .func = &namespaceFn,
        .doc = "Returns the namespace String of a symbol or keyword, or nil if not present.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "keyword",
        .func = &keywordFn,
        .doc = "Returns a Keyword with the given namespace and name.",
        .arglists = "([name] [ns name])",
        .added = "1.0",
    },
    .{
        .name = "symbol",
        .func = &symbolFn,
        .doc = "Returns a Symbol with the given namespace and name.",
        .arglists = "([name] [ns name])",
        .added = "1.0",
    },
    .{
        .name = "find-keyword",
        .func = &findKeywordFn,
        .doc = "Returns a Keyword with the given namespace and name if one is already interned. Otherwise returns nil.",
        .arglists = "([name] [ns name])",
        .added = "1.3",
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

// --- subs tests ---

test "subs with start" {
    const result = try subsFn(testing.allocator, &.{
        Value{ .string = "hello world" },
        Value{ .integer = 6 },
    });
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("world", result.string);
}

test "subs with start and end" {
    const result = try subsFn(testing.allocator, &.{
        Value{ .string = "hello world" },
        Value{ .integer = 0 },
        Value{ .integer = 5 },
    });
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("hello", result.string);
}

test "subs out of bounds" {
    try testing.expectError(error.IndexError, subsFn(testing.allocator, &.{
        Value{ .string = "hi" },
        Value{ .integer = 10 },
    }));
}

// --- name/namespace tests ---

test "name of keyword" {
    const result = try nameFn(testing.allocator, &.{Value{ .keyword = .{ .name = "foo", .ns = "bar" } }});
    try testing.expectEqualStrings("foo", result.string);
}

test "name of string" {
    const result = try nameFn(testing.allocator, &.{Value{ .string = "hello" }});
    try testing.expectEqualStrings("hello", result.string);
}

test "namespace of keyword with ns" {
    const result = try namespaceFn(testing.allocator, &.{Value{ .keyword = .{ .name = "foo", .ns = "bar" } }});
    try testing.expectEqualStrings("bar", result.string);
}

test "namespace of keyword without ns" {
    const result = try namespaceFn(testing.allocator, &.{Value{ .keyword = .{ .name = "foo", .ns = null } }});
    try testing.expect(result == .nil);
}

// --- keyword/symbol coercion tests ---

test "keyword from string" {
    const result = try keywordFn(testing.allocator, &.{Value{ .string = "foo" }});
    try testing.expect(result == .keyword);
    try testing.expectEqualStrings("foo", result.keyword.name);
    try testing.expect(result.keyword.ns == null);
}

test "keyword with ns and name" {
    const result = try keywordFn(testing.allocator, &.{
        Value{ .string = "my.ns" },
        Value{ .string = "foo" },
    });
    try testing.expect(result == .keyword);
    try testing.expectEqualStrings("foo", result.keyword.name);
    try testing.expectEqualStrings("my.ns", result.keyword.ns.?);
}

test "symbol from string" {
    const result = try symbolFn(testing.allocator, &.{Value{ .string = "bar" }});
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("bar", result.symbol.name);
    try testing.expect(result.symbol.ns == null);
}

test "symbol with ns and name" {
    const result = try symbolFn(testing.allocator, &.{
        Value{ .string = "my.ns" },
        Value{ .string = "bar" },
    });
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("bar", result.symbol.name);
    try testing.expectEqualStrings("my.ns", result.symbol.ns.?);
}

// --- print-str tests ---

test "print-str - no args returns empty string" {
    const result = try printStrFn(testing.allocator, &.{});
    try testing.expectEqualStrings("", result.string);
}

test "print-str - string is unquoted" {
    const args = [_]Value{.{ .string = "hello" }};
    const result = try printStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("hello", result.string);
}

test "print-str - multi-arg space separated" {
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
    };
    const result = try printStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("1 hello", result.string);
}

// --- prn-str tests ---

test "prn-str - no args returns newline" {
    const result = try prnStrFn(testing.allocator, &.{});
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("\n", result.string);
}

test "prn-str - string is quoted with newline" {
    const args = [_]Value{.{ .string = "hello" }};
    const result = try prnStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("\"hello\"\n", result.string);
}

test "prn-str - multi-arg space separated with newline" {
    const args = [_]Value{
        .{ .integer = 1 },
        .nil,
    };
    const result = try prnStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("1 nil\n", result.string);
}

// --- println-str tests ---

test "println-str - no args returns newline" {
    const result = try printlnStrFn(testing.allocator, &.{});
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("\n", result.string);
}

test "println-str - string is unquoted with newline" {
    const args = [_]Value{.{ .string = "hello" }};
    const result = try printlnStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("hello\n", result.string);
}

test "println-str - multi-arg space separated with newline" {
    const args = [_]Value{
        .{ .integer = 1 },
        .{ .string = "hello" },
    };
    const result = try printlnStrFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqualStrings("1 hello\n", result.string);
}

test "str - large string over 4KB" {
    // Build a 5000-char string via str concatenation
    const chunk = "a" ** 100; // 100 bytes
    var args: [60]Value = undefined;
    for (&args) |*a| {
        a.* = Value{ .string = chunk };
    }
    const result = try strFn(testing.allocator, &args);
    defer testing.allocator.free(result.string);
    try testing.expectEqual(@as(usize, 6000), result.string.len);
}
