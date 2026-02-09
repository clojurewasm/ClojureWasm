// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// String builtins — str, pr-str
//
// str: Non-readable string conversion. Concatenates arguments without separator.
//      nil produces empty string, strings are unquoted.
// pr-str: Readable string representation. Arguments separated by space.
//         Strings are quoted, chars use backslash notation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Writer = std.Io.Writer;
const collections = @import("collections.zig");
const err = @import("../runtime/error.zig");
const keyword_intern = @import("../runtime/keyword_intern.zig");

/// (str) => ""
/// (str x) => string representation of x (non-readable)
/// (str x y ...) => concatenation of all args (no separator)
pub fn strFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initString(allocator, "");

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
    return Value.initString(allocator, owned);
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
    switch (v.tag()) {
        .nil => return Value.initString(allocator, ""),
        .string => return v, // Already a string — zero-copy return
        .boolean => {
            // Static literal + single dupe (no formatting overhead)
            const s: []const u8 = if (v.asBoolean()) "true" else "false";
            const owned = try allocator.dupe(u8, s);
            return Value.initString(allocator, owned);
        },
        .integer => {
            // Stack buffer + single dupe: avoids Writer's alloc/realloc cycles
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v.asInteger()}) catch unreachable;
            const owned = try allocator.dupe(u8, s);
            return Value.initString(allocator, owned);
        },
        .keyword => {
            // Direct construction: compute exact length, single alloc, @memcpy.
            // Avoids Writer overhead for ":ns/name" or ":name" formatting.
            const kw = v.asKeyword();
            if (kw.ns) |ns| {
                const len = 1 + ns.len + 1 + kw.name.len;
                const owned = try allocator.alloc(u8, len);
                owned[0] = ':';
                @memcpy(owned[1 .. 1 + ns.len], ns);
                owned[1 + ns.len] = '/';
                @memcpy(owned[2 + ns.len ..], kw.name);
                return Value.initString(allocator, owned);
            } else {
                const len = 1 + kw.name.len;
                const owned = try allocator.alloc(u8, len);
                owned[0] = ':';
                @memcpy(owned[1..], kw.name);
                return Value.initString(allocator, owned);
            }
        },
        else => {
            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try v.formatStr(&aw.writer);
            const owned = try aw.toOwnedSlice();
            return Value.initString(allocator, owned);
        },
    }
}

/// (pr-str) => ""
/// (pr-str x) => readable representation of x
/// (pr-str x y ...) => readable representations separated by space
pub fn prStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initString(allocator, "");

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
    return Value.initString(allocator, owned);
}

/// (subs s start), (subs s start end) — returns substring.
pub fn subsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to subs", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects a string, got {s}", .{@tagName(args[0].tag())}),
    };
    const start_i = switch (args[1].tag()) {
        .integer => args[1].asInteger(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects an integer start, got {s}", .{@tagName(args[1].tag())}),
    };
    if (start_i < 0 or @as(usize, @intCast(start_i)) > s.len) return err.setErrorFmt(.eval, .index_error, .{}, "String index out of range: {d}", .{start_i});
    const start: usize = @intCast(start_i);

    const end: usize = if (args.len == 3) blk: {
        const end_i = switch (args[2].tag()) {
            .integer => args[2].asInteger(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "subs expects an integer end, got {s}", .{@tagName(args[2].tag())}),
        };
        if (end_i < start_i or @as(usize, @intCast(end_i)) > s.len) return err.setErrorFmt(.eval, .index_error, .{}, "String index out of range: {d}", .{end_i});
        break :blk @intCast(end_i);
    } else s.len;

    const slice = s[start..end];
    const owned = try allocator.alloc(u8, slice.len);
    @memcpy(owned, slice);
    return Value.initString(allocator, owned);
}

/// (name x) — returns the name part of a string, symbol, or keyword.
pub fn nameFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to name", .{args.len});
    return switch (args[0].tag()) {
        .string => args[0],
        .keyword => Value.initString(allocator, args[0].asKeyword().name),
        .symbol => Value.initString(allocator, args[0].asSymbol().name),
        else => err.setErrorFmt(.eval, .type_error, .{}, "name expects a string, keyword, or symbol, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (namespace x) — returns the namespace part of a symbol or keyword, or nil.
pub fn namespaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to namespace", .{args.len});
    return switch (args[0].tag()) {
        .keyword => if (args[0].asKeyword().ns) |ns| Value.initString(allocator, ns) else Value.nil_val,
        .symbol => if (args[0].asSymbol().ns) |ns| Value.initString(allocator, ns) else Value.nil_val,
        else => err.setErrorFmt(.eval, .type_error, .{}, "namespace expects a keyword or symbol, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (keyword x), (keyword ns name) — coerce to keyword.
pub fn keywordFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        const result: Value = switch (args[0].tag()) {
            .keyword => args[0],
            .string => Value.initKeyword(allocator, .{ .name = args[0].asString(), .ns = null }),
            .symbol => Value.initKeyword(allocator, .{ .name = args[0].asSymbol().name, .ns = args[0].asSymbol().ns }),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword expects a string, keyword, or symbol, got {s}", .{@tagName(args[0].tag())}),
        };
        keyword_intern.intern(result.asKeyword().ns, result.asKeyword().name);
        return result;
    } else if (args.len == 2) {
        const ns_str: ?[]const u8 = switch (args[0].tag()) {
            .string => args[0].asString(),
            .nil => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword namespace expects a string or nil, got {s}", .{@tagName(args[0].tag())}),
        };
        const name_str: []const u8 = switch (args[1].tag()) {
            .string => args[1].asString(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "keyword name expects a string, got {s}", .{@tagName(args[1].tag())}),
        };
        keyword_intern.intern(ns_str, name_str);
        return Value.initKeyword(allocator, .{ .name = name_str, .ns = ns_str });
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to keyword", .{args.len});
}

/// (find-keyword name), (find-keyword ns name) — find interned keyword.
/// Returns nil if the keyword has not been interned.
pub fn findKeywordFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        // (find-keyword :foo) or (find-keyword 'foo) or (find-keyword "foo")
        const ns: ?[]const u8 = switch (args[0].tag()) {
            .keyword => args[0].asKeyword().ns,
            .symbol => args[0].asSymbol().ns,
            .string => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword expects a string, keyword, or symbol, got {s}", .{@tagName(args[0].tag())}),
        };
        const name: []const u8 = switch (args[0].tag()) {
            .keyword => args[0].asKeyword().name,
            .symbol => args[0].asSymbol().name,
            .string => args[0].asString(),
            else => unreachable,
        };
        if (keyword_intern.contains(ns, name)) {
            return Value.initKeyword(allocator, .{ .ns = ns, .name = name });
        }
        return Value.nil_val;
    } else if (args.len == 2) {
        // (find-keyword "ns" "name")
        const ns_str: ?[]const u8 = switch (args[0].tag()) {
            .string => args[0].asString(),
            .nil => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword namespace expects a string, got {s}", .{@tagName(args[0].tag())}),
        };
        const name_str: []const u8 = switch (args[1].tag()) {
            .string => args[1].asString(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "find-keyword name expects a string, got {s}", .{@tagName(args[1].tag())}),
        };
        if (keyword_intern.contains(ns_str, name_str)) {
            return Value.initKeyword(allocator, .{ .ns = ns_str, .name = name_str });
        }
        return Value.nil_val;
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-keyword", .{args.len});
}

/// (symbol x), (symbol ns name) — coerce to symbol.
pub fn symbolFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) {
        return switch (args[0].tag()) {
            .symbol => args[0],
            .string => Value.initSymbol(allocator, .{ .name = args[0].asString(), .ns = null }),
            .keyword => Value.initSymbol(allocator, .{ .name = args[0].asKeyword().name, .ns = args[0].asKeyword().ns }),
            else => err.setErrorFmt(.eval, .type_error, .{}, "symbol expects a string, keyword, or symbol, got {s}", .{@tagName(args[0].tag())}),
        };
    } else if (args.len == 2) {
        const ns_str: ?[]const u8 = switch (args[0].tag()) {
            .string => args[0].asString(),
            .nil => null,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "symbol namespace expects a string or nil, got {s}", .{@tagName(args[0].tag())}),
        };
        const name_str: []const u8 = switch (args[1].tag()) {
            .string => args[1].asString(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "symbol name expects a string, got {s}", .{@tagName(args[1].tag())}),
        };
        return Value.initSymbol(allocator, .{ .name = name_str, .ns = ns_str });
    }
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to symbol", .{args.len});
}

/// (print-str) => ""
/// (print-str x) => non-readable representation of x
/// (print-str x y ...) => non-readable representations separated by space
pub fn printStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.initString(allocator, "");

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
    return Value.initString(allocator, owned);
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
    return Value.initString(allocator, owned);
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
    return Value.initString(allocator, owned);
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try strFn(alloc, &.{});
    try testing.expectEqualStrings("", result.asString());
}

test "str - nil returns empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.nil_val};
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("", result.asString());
}

test "str - string returns same string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello")};
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("hello", result.asString());
}

test "str - integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initInteger(42)};
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("42", result.asString());
}

test "str - boolean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initBoolean(true)};
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("true", result.asString());
}

test "str - keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initKeyword(alloc, .{ .name = "foo", .ns = null })};
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings(":foo", result.asString());
}

test "str - multi-arg concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, " + "),
        Value.initInteger(2),
    };
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("1 + 2", result.asString());
}

test "str - nil in multi-arg is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initString(alloc, "a"),
        Value.nil_val,
        Value.initString(alloc, "b"),
    };
    const result = try strFn(alloc, &args);
    try testing.expectEqualStrings("ab", result.asString());
}

test "pr-str - no args returns empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try prStrFn(alloc, &.{});
    try testing.expectEqualStrings("", result.asString());
}

test "pr-str - string is quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello")};
    const result = try prStrFn(alloc, &args);
    try testing.expectEqualStrings("\"hello\"", result.asString());
}

test "pr-str - nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.nil_val};
    const result = try prStrFn(alloc, &args);
    try testing.expectEqualStrings("nil", result.asString());
}

test "pr-str - multi-arg space separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
        Value.nil_val,
    };
    const result = try prStrFn(alloc, &args);
    try testing.expectEqualStrings("1 \"hello\" nil", result.asString());
}

// --- subs tests ---

test "subs with start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try subsFn(alloc, &.{
        Value.initString(alloc, "hello world"),
        Value.initInteger(6),
    });
    try testing.expectEqualStrings("world", result.asString());
}

test "subs with start and end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try subsFn(alloc, &.{
        Value.initString(alloc, "hello world"),
        Value.initInteger(0),
        Value.initInteger(5),
    });
    try testing.expectEqualStrings("hello", result.asString());
}

test "subs out of bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectError(error.IndexError, subsFn(alloc, &.{
        Value.initString(alloc, "hi"),
        Value.initInteger(10),
    }));
}

// --- name/namespace tests ---

test "name of keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try nameFn(alloc, &.{Value.initKeyword(alloc, .{ .name = "foo", .ns = "bar" })});
    try testing.expectEqualStrings("foo", result.asString());
}

test "name of string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try nameFn(alloc, &.{Value.initString(alloc, "hello")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "namespace of keyword with ns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try namespaceFn(alloc, &.{Value.initKeyword(alloc, .{ .name = "foo", .ns = "bar" })});
    try testing.expectEqualStrings("bar", result.asString());
}

test "namespace of keyword without ns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try namespaceFn(alloc, &.{Value.initKeyword(alloc, .{ .name = "foo", .ns = null })});
    try testing.expect(result.isNil());
}

// --- keyword/symbol coercion tests ---

test "keyword from string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try keywordFn(alloc, &.{Value.initString(alloc, "foo")});
    try testing.expect(result.tag() == .keyword);
    try testing.expectEqualStrings("foo", result.asKeyword().name);
    try testing.expect(result.asKeyword().ns == null);
}

test "keyword with ns and name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try keywordFn(alloc, &.{
        Value.initString(alloc, "my.ns"),
        Value.initString(alloc, "foo"),
    });
    try testing.expect(result.tag() == .keyword);
    try testing.expectEqualStrings("foo", result.asKeyword().name);
    try testing.expectEqualStrings("my.ns", result.asKeyword().ns.?);
}

test "symbol from string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try symbolFn(alloc, &.{Value.initString(alloc, "bar")});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("bar", result.asSymbol().name);
    try testing.expect(result.asSymbol().ns == null);
}

test "symbol with ns and name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try symbolFn(alloc, &.{
        Value.initString(alloc, "my.ns"),
        Value.initString(alloc, "bar"),
    });
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("bar", result.asSymbol().name);
    try testing.expectEqualStrings("my.ns", result.asSymbol().ns.?);
}

// --- print-str tests ---

test "print-str - no args returns empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try printStrFn(alloc, &.{});
    try testing.expectEqualStrings("", result.asString());
}

test "print-str - string is unquoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello")};
    const result = try printStrFn(alloc, &args);
    try testing.expectEqualStrings("hello", result.asString());
}

test "print-str - multi-arg space separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
    };
    const result = try printStrFn(alloc, &args);
    try testing.expectEqualStrings("1 hello", result.asString());
}

// --- prn-str tests ---

test "prn-str - no args returns newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try prnStrFn(alloc, &.{});
    try testing.expectEqualStrings("\n", result.asString());
}

test "prn-str - string is quoted with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello")};
    const result = try prnStrFn(alloc, &args);
    try testing.expectEqualStrings("\"hello\"\n", result.asString());
}

test "prn-str - multi-arg space separated with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initInteger(1),
        Value.nil_val,
    };
    const result = try prnStrFn(alloc, &args);
    try testing.expectEqualStrings("1 nil\n", result.asString());
}

// --- println-str tests ---

test "println-str - no args returns newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try printlnStrFn(alloc, &.{});
    try testing.expectEqualStrings("\n", result.asString());
}

test "println-str - string is unquoted with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{Value.initString(alloc, "hello")};
    const result = try printlnStrFn(alloc, &args);
    try testing.expectEqualStrings("hello\n", result.asString());
}

test "println-str - multi-arg space separated with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]Value{
        Value.initInteger(1),
        Value.initString(alloc, "hello"),
    };
    const result = try printlnStrFn(alloc, &args);
    try testing.expectEqualStrings("1 hello\n", result.asString());
}

test "str - large string over 4KB" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Build a 5000-char string via str concatenation
    const chunk = "a" ** 100; // 100 bytes
    var args: [60]Value = undefined;
    for (&args) |*a| {
        a.* = Value.initString(alloc, chunk);
    }
    const result = try strFn(alloc, &args);
    try testing.expectEqual(@as(usize, 6000), result.asString().len);
}
