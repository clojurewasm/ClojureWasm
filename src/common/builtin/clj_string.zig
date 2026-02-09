// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// clojure.string namespace builtins — join, split, upper-case, lower-case, trim, etc.
//
// String manipulation functions registered in the clojure.string namespace.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const PersistentVector = value_mod.PersistentVector;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../error.zig");
const matcher_mod = @import("../regex/matcher.zig");
const CompiledRegex = @import("../regex/regex.zig").CompiledRegex;
const bootstrap = @import("../bootstrap.zig");

/// (clojure.string/join coll)
/// (clojure.string/join separator coll)
/// Returns a string of all elements in coll, separated by separator.
pub fn joinFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to join", .{args.len});

    const sep: []const u8 = if (args.len == 2) blk: {
        if (args[0].tag() == .string) break :blk args[0].asString();
        if (args[0].tag() == .char) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(args[0].asChar(), &buf) catch 0;
            const s = try allocator.dupe(u8, buf[0..len]);
            break :blk s;
        }
        // Convert anything else via str semantics
        const s = try valueToStr(allocator, args[0]);
        break :blk s;
    } else "";

    const coll = if (args.len == 2) args[1] else args[0];
    const items: []const Value = switch (coll.tag()) {
        .vector => coll.asVector().items,
        .list => coll.asList().items,
        .nil => return Value.initString(allocator, ""),
        .lazy_seq => blk: {
            const realized = try coll.asLazySeq().realize(allocator);
            break :blk switch (realized.tag()) {
                .list => realized.asList().items,
                .nil => return Value.initString(allocator, ""),
                else => return Value.initString(allocator, ""),
            };
        },
        .cons => blk: {
            var elems: std.ArrayList(Value) = .empty;
            var cur = coll;
            while (true) {
                if (cur.tag() == .cons) {
                    try elems.append(allocator, cur.asCons().first);
                    cur = cur.asCons().rest;
                } else if (cur.tag() == .lazy_seq) {
                    cur = try cur.asLazySeq().realize(allocator);
                } else if (cur.tag() == .list) {
                    for (cur.asList().items) |item| try elems.append(allocator, item);
                    break;
                } else break;
            }
            break :blk elems.items;
        },
        .set => coll.asSet().items,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "join expects a collection, got {s}", .{@tagName(coll.tag())}),
    };

    if (items.len == 0) return Value.initString(allocator, "");

    // Build result using Writer.Allocating
    var aw: Writer.Allocating = .init(allocator);
    for (items, 0..) |item, i| {
        if (i > 0 and sep.len > 0) {
            try aw.writer.writeAll(sep);
        }
        const s = try valueToStr(allocator, item);
        try aw.writer.writeAll(s);
    }

    return Value.initString(allocator, try aw.toOwnedSlice());
}

/// (clojure.string/split s re)
/// (clojure.string/split s re limit)
/// Splits string on a regular expression. Returns a vector of strings.
pub fn splitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to split", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "split expects a string, got {s}", .{@tagName(args[0].tag())});

    const s = args[0].asString();
    const limit: i64 = if (args.len == 3) blk: {
        if (args[2].tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "split limit expects an integer, got {s}", .{@tagName(args[2].tag())});
        break :blk args[2].asInteger();
    } else 0;

    // Use regex matching for regex patterns, literal for strings
    if (args[1].tag() == .regex) {
        return splitWithRegex(allocator, s, args[1], limit);
    } else if (args[1].tag() == .string) {
        return splitWithString(allocator, s, args[1].asString(), limit);
    }
    return err.setErrorFmt(.eval, .type_error, .{}, "split pattern expects a string or regex, got {s}", .{@tagName(args[1].tag())});
}

fn splitWithString(allocator: Allocator, s: []const u8, pattern: []const u8, limit: i64) anyerror!Value {
    if (pattern.len == 0) {
        var chars: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + cp_len, s.len);
            try chars.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[i..end])));
            i = end;
        }
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = try chars.toOwnedSlice(allocator) };
        return Value.initVector(vec);
    }

    var parts: std.ArrayList(Value) = .empty;
    var start: usize = 0;
    var count: i64 = 1;
    while (start <= s.len) {
        if (limit > 0 and count >= limit) {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..])));
            break;
        }
        if (std.mem.indexOfPos(u8, s, start, pattern)) |pos| {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..pos])));
            start = pos + pattern.len;
            count += 1;
        } else {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..])));
            break;
        }
    }

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = try parts.toOwnedSlice(allocator) };
    return Value.initVector(vec);
}

fn splitWithRegex(allocator: Allocator, s: []const u8, regex_val: Value, limit: i64) anyerror!Value {
    const compiled: *const CompiledRegex = @ptrCast(@alignCast(regex_val.asRegex().compiled));
    var m = try matcher_mod.Matcher.init(allocator, compiled, s);
    defer m.deinit();

    var parts: std.ArrayList(Value) = .empty;
    var start: usize = 0;
    var count: i64 = 1;

    while (start <= s.len) {
        if (limit > 0 and count >= limit) {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..])));
            break;
        }
        if (try m.find(start)) |result| {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..result.start])));
            start = if (result.end > result.start) result.end else result.end + 1;
            count += 1;
        } else {
            try parts.append(allocator, Value.initString(allocator, try allocator.dupe(u8, s[start..])));
            break;
        }
    }

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = try parts.toOwnedSlice(allocator) };
    return Value.initVector(vec);
}

/// (clojure.string/upper-case s)
pub fn upperCaseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to upper-case", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "upper-case expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return Value.initString(allocator, result);
}

/// (clojure.string/lower-case s)
pub fn lowerCaseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to lower-case", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "lower-case expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return Value.initString(allocator, result);
}

/// (clojure.string/trim s)
pub fn trimFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to trim", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "trim expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const left = trimLeftUnicode(s);
    const right = trimRightUnicode(left);
    return Value.initString(allocator, right);
}

/// (clojure.string/includes? s substr)
/// True if s includes substr.
pub fn includesFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to includes?", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "includes? expects a string, got {s}", .{@tagName(args[0].tag())});
    if (args[1].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "includes? substring expects a string, got {s}", .{@tagName(args[1].tag())});
    return Value.initBoolean(std.mem.indexOf(u8, args[0].asString(), args[1].asString()) != null);
}

/// (clojure.string/starts-with? s substr)
/// True if s starts with substr.
pub fn startsWithFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to starts-with?", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "starts-with? expects a string, got {s}", .{@tagName(args[0].tag())});
    if (args[1].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "starts-with? substring expects a string, got {s}", .{@tagName(args[1].tag())});
    return Value.initBoolean(std.mem.startsWith(u8, args[0].asString(), args[1].asString()));
}

/// (clojure.string/ends-with? s substr)
/// True if s ends with substr.
pub fn endsWithFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ends-with?", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "ends-with? expects a string, got {s}", .{@tagName(args[0].tag())});
    if (args[1].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "ends-with? substring expects a string, got {s}", .{@tagName(args[1].tag())});
    return Value.initBoolean(std.mem.endsWith(u8, args[0].asString(), args[1].asString()));
}

/// (clojure.string/replace s match replacement)
/// Replaces all instances of match with replacement in s.
/// match can be: string, char, or regex.
/// replacement can be: string, char, or function (for regex match).
pub fn replaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to replace", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "replace expects a string, got {s}", .{@tagName(args[0].tag())});

    const s = args[0].asString();

    return switch (args[1].tag()) {
        .char => switch (args[2].tag()) {
            .char => replaceChar(allocator, s, args[1].asChar(), args[2].asChar()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace with char match expects char replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        .string => switch (args[2].tag()) {
            .string => replaceString(allocator, s, args[1].asString(), args[2].asString()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace with string match expects string replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        .regex => switch (args[2].tag()) {
            .string => replaceRegexStr(allocator, s, args[1], args[2].asString()),
            .fn_val, .builtin_fn => replaceRegexFn(allocator, s, args[1], args[2], false),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace with regex expects string or fn replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "replace match expects a string, char, or regex, got {s}", .{@tagName(args[1].tag())}),
    };
}

fn replaceChar(allocator: Allocator, s: []const u8, from: u21, to: u21) anyerror!Value {
    var aw: Writer.Allocating = .init(allocator);
    var from_buf: [4]u8 = undefined;
    const from_len = std.unicode.utf8Encode(from, &from_buf) catch return error.ValueError;
    var to_buf: [4]u8 = undefined;
    const to_len = std.unicode.utf8Encode(to, &to_buf) catch return error.ValueError;
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        if (cp_len == from_len and std.mem.eql(u8, s[i..end], from_buf[0..from_len])) {
            try aw.writer.writeAll(to_buf[0..to_len]);
        } else {
            try aw.writer.writeAll(s[i..end]);
        }
        i = end;
    }
    return Value.initString(allocator, try aw.toOwnedSlice());
}

fn replaceString(allocator: Allocator, s: []const u8, match: []const u8, replacement: []const u8) anyerror!Value {
    if (match.len == 0) return Value.initString(allocator, s);
    var aw: Writer.Allocating = .init(allocator);
    var start: usize = 0;
    while (start < s.len) {
        if (std.mem.indexOfPos(u8, s, start, match)) |pos| {
            try aw.writer.writeAll(s[start..pos]);
            try aw.writer.writeAll(replacement);
            start = pos + match.len;
        } else {
            try aw.writer.writeAll(s[start..]);
            break;
        }
    }
    return Value.initString(allocator, try aw.toOwnedSlice());
}

fn replaceRegexStr(allocator: Allocator, s: []const u8, regex_val: Value, replacement: []const u8) anyerror!Value {
    const compiled: *const CompiledRegex = @ptrCast(@alignCast(regex_val.asRegex().compiled));
    var m = try matcher_mod.Matcher.init(allocator, compiled, s);
    defer m.deinit();
    var aw: Writer.Allocating = .init(allocator);
    var start: usize = 0;
    while (start <= s.len) {
        if (try m.find(start)) |result| {
            try aw.writer.writeAll(s[start..result.start]);
            try aw.writer.writeAll(replacement);
            start = if (result.end > result.start) result.end else result.end + 1;
        } else {
            try aw.writer.writeAll(s[start..]);
            break;
        }
    }
    return Value.initString(allocator, try aw.toOwnedSlice());
}

fn replaceRegexFn(allocator: Allocator, s: []const u8, regex_val: Value, fn_val: Value, first_only: bool) anyerror!Value {
    const compiled: *const CompiledRegex = @ptrCast(@alignCast(regex_val.asRegex().compiled));
    var m = try matcher_mod.Matcher.init(allocator, compiled, s);
    defer m.deinit();
    var aw: Writer.Allocating = .init(allocator);
    var start: usize = 0;
    while (start <= s.len) {
        if (try m.find(start)) |result| {
            try aw.writer.writeAll(s[start..result.start]);
            // Build match argument for fn
            const match_val = try matchResultToValue(allocator, result, s);
            const call_args = [_]Value{match_val};
            const replacement_val = try bootstrap.callFnVal(allocator, fn_val, &call_args);
            if (replacement_val.tag() == .string) {
                try aw.writer.writeAll(replacement_val.asString());
            } else {
                const str_val = try valueToStr(allocator, replacement_val);
                try aw.writer.writeAll(str_val);
            }
            start = if (result.end > result.start) result.end else result.end + 1;
            if (first_only) {
                try aw.writer.writeAll(s[start..]);
                break;
            }
        } else {
            try aw.writer.writeAll(s[start..]);
            break;
        }
    }
    return Value.initString(allocator, try aw.toOwnedSlice());
}

fn matchResultToValue(allocator: Allocator, result: matcher_mod.MatchResult, input: []const u8) !Value {
    if (result.groups.len <= 1) {
        return Value.initString(allocator, input[result.start..result.end]);
    }
    const items = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            items[i] = Value.initString(allocator, span.text(input));
        } else {
            items[i] = Value.nil_val;
        }
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items };
    return Value.initVector(vec);
}

/// (clojure.string/replace-first s match replacement)
/// Replaces the first instance of match with replacement in s.
/// match can be: string, char, or regex.
/// replacement can be: string, char, or function (for regex match).
pub fn replaceFirstFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to replace-first", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "replace-first expects a string, got {s}", .{@tagName(args[0].tag())});

    const s = args[0].asString();

    return switch (args[1].tag()) {
        .char => switch (args[2].tag()) {
            .char => replaceFirstChar(allocator, s, args[1].asChar(), args[2].asChar()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace-first with char match expects char replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        .string => switch (args[2].tag()) {
            .string => replaceFirstString(allocator, s, args[1].asString(), args[2].asString()),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace-first with string match expects string replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        .regex => switch (args[2].tag()) {
            .string => replaceFirstRegexStr(allocator, s, args[1], args[2].asString()),
            .fn_val, .builtin_fn => replaceRegexFn(allocator, s, args[1], args[2], true),
            else => err.setErrorFmt(.eval, .type_error, .{}, "replace-first with regex expects string or fn replacement, got {s}", .{@tagName(args[2].tag())}),
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "replace-first match expects a string, char, or regex, got {s}", .{@tagName(args[1].tag())}),
    };
}

fn replaceFirstChar(allocator: Allocator, s: []const u8, from: u21, to: u21) anyerror!Value {
    var from_buf: [4]u8 = undefined;
    const from_len = std.unicode.utf8Encode(from, &from_buf) catch return error.ValueError;
    var to_buf: [4]u8 = undefined;
    const to_len = std.unicode.utf8Encode(to, &to_buf) catch return error.ValueError;
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        if (cp_len == from_len and std.mem.eql(u8, s[i..end], from_buf[0..from_len])) {
            var aw: Writer.Allocating = .init(allocator);
            try aw.writer.writeAll(s[0..i]);
            try aw.writer.writeAll(to_buf[0..to_len]);
            try aw.writer.writeAll(s[end..]);
            return Value.initString(allocator, try aw.toOwnedSlice());
        }
        i = end;
    }
    return Value.initString(allocator, s);
}

fn replaceFirstString(allocator: Allocator, s: []const u8, match: []const u8, replacement: []const u8) anyerror!Value {
    if (match.len == 0) return Value.initString(allocator, s);
    if (std.mem.indexOf(u8, s, match)) |pos| {
        var aw: Writer.Allocating = .init(allocator);
        try aw.writer.writeAll(s[0..pos]);
        try aw.writer.writeAll(replacement);
        try aw.writer.writeAll(s[pos + match.len ..]);
        return Value.initString(allocator, try aw.toOwnedSlice());
    }
    return Value.initString(allocator, s);
}

fn replaceFirstRegexStr(allocator: Allocator, s: []const u8, regex_val: Value, replacement: []const u8) anyerror!Value {
    const compiled: *const CompiledRegex = @ptrCast(@alignCast(regex_val.asRegex().compiled));
    var m = try matcher_mod.Matcher.init(allocator, compiled, s);
    defer m.deinit();
    if (try m.find(0)) |result| {
        var aw: Writer.Allocating = .init(allocator);
        try aw.writer.writeAll(s[0..result.start]);
        try aw.writer.writeAll(replacement);
        try aw.writer.writeAll(s[result.end..]);
        return Value.initString(allocator, try aw.toOwnedSlice());
    }
    return Value.initString(allocator, s);
}

/// (clojure.string/capitalize s)
/// Converts first character to upper-case, all other characters to lower-case.
pub fn capitalizeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to capitalize", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "capitalize expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    if (s.len == 0) return args[0];
    const result = try allocator.alloc(u8, s.len);
    result[0] = std.ascii.toUpper(s[0]);
    for (s[1..], 1..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return Value.initString(allocator, result);
}

/// (clojure.string/split-lines s)
/// Splits s on \n or \r\n. Returns a vector of strings.
pub fn splitLinesFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to split-lines", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "split-lines expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();

    var parts = std.ArrayList(Value).empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value.initString(allocator, part));
            start = i + 1;
        } else if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value.initString(allocator, part));
            start = i + 2;
            i += 1; // skip \n
        } else if (s[i] == '\r') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value.initString(allocator, part));
            start = i + 1;
        }
        i += 1;
    }
    // Add remaining
    const part = try allocator.dupe(u8, s[start..]);
    try parts.append(allocator, Value.initString(allocator, part));

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = try parts.toOwnedSlice(allocator) };
    return Value.initVector(vec);
}

/// (clojure.string/index-of s value)
/// (clojure.string/index-of s value from-index)
/// Returns the index of value (string or char) in s, optionally starting from from-index.
pub fn indexOfFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to index-of", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "index-of expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const sub: []const u8 = if (args[1].tag() == .string) args[1].asString() else if (args[1].tag() == .char) blk: {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(args[1].asChar(), &buf) catch return error.ValueError;
        break :blk try allocator.dupe(u8, buf[0..len]);
    } else return err.setErrorFmt(.eval, .type_error, .{}, "index-of expects a string or char, got {s}", .{@tagName(args[1].tag())});
    const from: usize = if (args.len == 3) blk: {
        if (args[2].tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "index-of from-index expects an integer, got {s}", .{@tagName(args[2].tag())});
        const idx = args[2].asInteger();
        break :blk if (idx < 0) 0 else @intCast(idx);
    } else 0;
    if (from > s.len) return Value.nil_val;
    if (std.mem.indexOfPos(u8, s, from, sub)) |pos| {
        return Value.initInteger(@intCast(pos));
    }
    return Value.nil_val;
}

/// (clojure.string/last-index-of s value)
/// (clojure.string/last-index-of s value from-index)
/// Returns the last index of value (string or char) in s, optionally searching backward from from-index.
pub fn lastIndexOfFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to last-index-of", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "last-index-of expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const sub: []const u8 = if (args[1].tag() == .string) args[1].asString() else if (args[1].tag() == .char) blk: {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(args[1].asChar(), &buf) catch return error.ValueError;
        break :blk try allocator.dupe(u8, buf[0..len]);
    } else return err.setErrorFmt(.eval, .type_error, .{}, "last-index-of expects a string or char, got {s}", .{@tagName(args[1].tag())});
    const search_end: usize = if (args.len == 3) blk: {
        if (args[2].tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "last-index-of from-index expects an integer, got {s}", .{@tagName(args[2].tag())});
        const idx = args[2].asInteger();
        const end: usize = if (idx < 0) 0 else @intCast(idx);
        break :blk @min(end + sub.len, s.len);
    } else s.len;
    if (std.mem.lastIndexOf(u8, s[0..search_end], sub)) |pos| {
        return Value.initInteger(@intCast(pos));
    }
    return Value.nil_val;
}

/// (clojure.string/blank? s)
/// True if s is nil, empty, or contains only whitespace.
pub fn blankFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to blank?", .{args.len});
    return switch (args[0].tag()) {
        .nil => Value.true_val,
        .string => Value.initBoolean(std.mem.trim(u8, args[0].asString(), " \t\n\r\x0b\x0c").len == 0),
        else => err.setErrorFmt(.eval, .type_error, .{}, "blank? expects a string or nil, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (clojure.string/reverse s)
/// Returns s with its characters reversed.
pub fn reverseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reverse", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "reverse expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    if (s.len == 0) return args[0];
    const result = try allocator.alloc(u8, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        // Copy the bytes of this codepoint in original order to preserve UTF-8
        @memcpy(result[s.len - end .. s.len - i], s[i..end]);
        i = end;
    }
    return Value.initString(allocator, result);
}

/// (clojure.string/trim-newline s)
/// Removes all trailing newline (\n) and carriage return (\r) characters from s.
pub fn trimNewlineFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to trim-newline", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "trim-newline expects a string, got {s}", .{@tagName(args[0].tag())});
    const s = args[0].asString();
    const trimmed = std.mem.trimRight(u8, s, "\r\n");
    return Value.initString(allocator, trimmed);
}

/// (clojure.string/triml s)
/// Removes whitespace from the left side of s.
pub fn trimlFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to triml", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "triml expects a string, got {s}", .{@tagName(args[0].tag())});
    return Value.initString(allocator, trimLeftUnicode(args[0].asString()));
}

/// (clojure.string/trimr s)
/// Removes whitespace from the right side of s.
pub fn trimrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to trimr", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "trimr expects a string, got {s}", .{@tagName(args[0].tag())});
    return Value.initString(allocator, trimRightUnicode(args[0].asString()));
}

const Writer = std.Io.Writer;

// Helper: convert a Value to its string representation for join
// Uses str semantics (nil -> "", strings unquoted)
fn valueToStr(allocator: Allocator, val: Value) anyerror![]const u8 {
    return switch (val.tag()) {
        .string => val.asString(),
        .nil => "",
        else => blk: {
            var aw: Writer.Allocating = .init(allocator);
            val.formatStr(&aw.writer) catch return error.TypeError;
            break :blk try aw.toOwnedSlice();
        },
    };
}

/// (clojure.string/escape s cmap)
/// Return a new string, using cmap to escape each character ch from s
/// as follows: if (cmap ch) is non-nil, use it as replacement, otherwise use ch.
pub fn escapeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to escape", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "escape expects a string, got {s}", .{@tagName(args[0].tag())});
    if (args[1].tag() != .map) return err.setErrorFmt(.eval, .type_error, .{}, "escape expects a map, got {s}", .{@tagName(args[1].tag())});

    const s = args[0].asString();
    const cmap = args[1].asMap();
    var aw: Writer.Allocating = .init(allocator);

    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        // Decode the codepoint to match as a char key
        const cp = std.unicode.utf8Decode(s[i..end]) catch {
            try aw.writer.writeAll(s[i..end]);
            i = end;
            continue;
        };
        const char_key = Value.initChar(cp);
        // Look up in cmap
        if (cmap.get(char_key)) |replacement| {
            if (replacement.tag() == .string) {
                try aw.writer.writeAll(replacement.asString());
            } else if (replacement.tag() == .char) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(replacement.asChar(), &buf) catch 0;
                try aw.writer.writeAll(buf[0..len]);
            } else {
                const str_val = try valueToStr(allocator, replacement);
                try aw.writer.writeAll(str_val);
            }
        } else {
            try aw.writer.writeAll(s[i..end]);
        }
        i = end;
    }

    return Value.initString(allocator, try aw.toOwnedSlice());
}

/// (clojure.string/re-quote-replacement replacement)
/// Given a replacement string, returns a string that will produce the
/// replacement when passed to replace/replace-first.
pub fn reQuoteReplacementFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to re-quote-replacement", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "re-quote-replacement expects a string, got {s}", .{@tagName(args[0].tag())});
    // In JVM Clojure, this escapes $ and \ for Matcher.appendReplacement.
    // Since our replacement is literal, just return the string as-is.
    return args[0];
}

// Unicode whitespace helper: matches Character.isWhitespace in Java
fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        // Unicode space separators (Zs category) used by Java
        0x00A0, // NO-BREAK SPACE — Java isWhitespace returns false for this, but Character.isSpaceChar returns true
        => false,
        0x2000...0x200A, // EN QUAD through HAIR SPACE (includes EN SPACE 0x2002)
        0x1680, // OGHAM SPACE MARK
        0x2028, // LINE SEPARATOR
        0x2029, // PARAGRAPH SEPARATOR
        0x205F, // MEDIUM MATHEMATICAL SPACE
        0x3000, // IDEOGRAPHIC SPACE
        => true,
        else => false,
    };
}

fn trimLeftUnicode(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        const end = @min(i + cp_len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        i = end;
    }
    return s[i..];
}

fn trimRightUnicode(s: []const u8) []const u8 {
    var i: usize = s.len;
    while (i > 0) {
        // Walk backward through UTF-8 continuation bytes
        var start = i - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        const cp = std.unicode.utf8Decode(s[start..i]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        i = start;
    }
    return s[0..i];
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "join", .func = &joinFn, .doc = "Returns a string of all elements in coll, as with (apply str coll), separated by an optional separator.", .arglists = "([coll] [separator coll])", .added = "1.2" },
    .{ .name = "split", .func = &splitFn, .doc = "Splits string on a regular expression. Returns a vector of the parts.", .arglists = "([s re])", .added = "1.2" },
    .{ .name = "upper-case", .func = &upperCaseFn, .doc = "Converts string to all upper-case.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "lower-case", .func = &lowerCaseFn, .doc = "Converts string to all lower-case.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "trim", .func = &trimFn, .doc = "Removes whitespace from both ends of string.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "includes?", .func = &includesFn, .doc = "True if s includes substr.", .arglists = "([s substr])", .added = "1.8" },
    .{ .name = "starts-with?", .func = &startsWithFn, .doc = "True if s starts with substr.", .arglists = "([s substr])", .added = "1.8" },
    .{ .name = "ends-with?", .func = &endsWithFn, .doc = "True if s ends with substr.", .arglists = "([s substr])", .added = "1.8" },
    .{ .name = "replace", .func = &replaceFn, .doc = "Replaces all instance of match with replacement in s.", .arglists = "([s match replacement])", .added = "1.2" },
    .{ .name = "blank?", .func = &blankFn, .doc = "True if s is nil, empty, or contains only whitespace.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "reverse", .func = &reverseFn, .doc = "Returns s with its characters reversed.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "trim-newline", .func = &trimNewlineFn, .doc = "Removes all trailing newline \\n and carriage return \\r characters from s.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "triml", .func = &trimlFn, .doc = "Removes whitespace from the left side of string.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "trimr", .func = &trimrFn, .doc = "Removes whitespace from the right side of string.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "capitalize", .func = &capitalizeFn, .doc = "Converts first character of the string to upper-case, all other characters to lower-case.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "split-lines", .func = &splitLinesFn, .doc = "Splits s on \\n or \\r\\n.", .arglists = "([s])", .added = "1.2" },
    .{ .name = "index-of", .func = &indexOfFn, .doc = "Return index of value (string) in s, optionally searching forward from from-index. Return nil if value not found.", .arglists = "([s value] [s value from-index])", .added = "1.8" },
    .{ .name = "last-index-of", .func = &lastIndexOfFn, .doc = "Return last index of value (string) in s, optionally searching backward from from-index. Return nil if value not found.", .arglists = "([s value] [s value from-index])", .added = "1.8" },
    .{ .name = "replace-first", .func = &replaceFirstFn, .doc = "Replaces the first instance of match with replacement in s.", .arglists = "([s match replacement])", .added = "1.2" },
    .{ .name = "escape", .func = &escapeFn, .doc = "Return a new string, using cmap to escape each character ch from s.", .arglists = "([s cmap])", .added = "1.2" },
    .{ .name = "re-quote-replacement", .func = &reQuoteReplacementFn, .doc = "Given a replacement string that will be used in a call to replace, returns a string that will produce the exact same replacement.", .arglists = "([replacement])", .added = "1.5" },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "join with separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initString(alloc, "a"), Value.initString(alloc, "b"), Value.initString(alloc, "c") };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try joinFn(alloc, &.{ Value.initString(alloc, ", "), Value.initVector(vec) });
    try testing.expectEqualStrings("a, b, c", result.asString());
}

test "join without separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ Value.initString(alloc, "a"), Value.initString(alloc, "b") };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try joinFn(alloc, &.{Value.initVector(vec)});
    try testing.expectEqualStrings("ab", result.asString());
}

test "upper-case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try upperCaseFn(alloc, &.{Value.initString(alloc, "hello")});
    try testing.expectEqualStrings("HELLO", result.asString());
}

test "lower-case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try lowerCaseFn(alloc, &.{Value.initString(alloc, "HELLO")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "trim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try trimFn(alloc, &.{Value.initString(alloc, "  hello  ")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "trim newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try trimFn(alloc, &.{Value.initString(alloc, "\n hello \t")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "split basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try splitFn(alloc, &.{ Value.initString(alloc, "a,b,c"), Value.initString(alloc, ",") });
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expectEqualStrings("a", result.asVector().items[0].asString());
    try testing.expectEqualStrings("b", result.asVector().items[1].asString());
    try testing.expectEqualStrings("c", result.asVector().items[2].asString());
}

test "includes? found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try includesFn(alloc, &.{ Value.initString(alloc, "hello world"), Value.initString(alloc, "world") });
    try testing.expectEqual(true, result.asBoolean());
}

test "includes? not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try includesFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz") });
    try testing.expectEqual(false, result.asBoolean());
}

test "starts-with?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const t = try startsWithFn(alloc, &.{ Value.initString(alloc, "hello world"), Value.initString(alloc, "hello") });
    try testing.expectEqual(true, t.asBoolean());
    const f = try startsWithFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz") });
    try testing.expectEqual(false, f.asBoolean());
}

test "ends-with?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const t = try endsWithFn(alloc, &.{ Value.initString(alloc, "hello world"), Value.initString(alloc, "world") });
    try testing.expectEqual(true, t.asBoolean());
    const f = try endsWithFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz") });
    try testing.expectEqual(false, f.asBoolean());
}

test "replace string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try replaceFn(alloc, &.{ Value.initString(alloc, "hello world"), Value.initString(alloc, "world"), Value.initString(alloc, "zig") });
    try testing.expectEqualStrings("hello zig", result.asString());
}

test "replace all occurrences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try replaceFn(alloc, &.{ Value.initString(alloc, "aabaa"), Value.initString(alloc, "a"), Value.initString(alloc, "x") });
    try testing.expectEqualStrings("xxbxx", result.asString());
}

test "blank? true cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(true, (try blankFn(alloc, &.{Value.nil_val})).asBoolean());
    try testing.expectEqual(true, (try blankFn(alloc, &.{Value.initString(alloc, "")})).asBoolean());
    try testing.expectEqual(true, (try blankFn(alloc, &.{Value.initString(alloc, "  \t\n")})).asBoolean());
}

test "blank? false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqual(false, (try blankFn(alloc, &.{Value.initString(alloc, "a")})).asBoolean());
}

test "reverse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try reverseFn(alloc, &.{Value.initString(alloc, "hello")});
    try testing.expectEqualStrings("olleh", result.asString());
}

test "trim-newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try trimNewlineFn(alloc, &.{Value.initString(alloc, "hello\r\n")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "triml" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try trimlFn(alloc, &.{Value.initString(alloc, "  hello  ")});
    try testing.expectEqualStrings("hello  ", result.asString());
}

test "trimr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try trimrFn(alloc, &.{Value.initString(alloc, "  hello  ")});
    try testing.expectEqualStrings("  hello", result.asString());
}

test "capitalize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try capitalizeFn(alloc, &.{Value.initString(alloc, "hello WORLD")});
    try testing.expectEqualStrings("Hello world", r1.asString());
    const r2 = try capitalizeFn(alloc, &.{Value.initString(alloc, "")});
    try testing.expectEqualStrings("", r2.asString());
    const r3 = try capitalizeFn(alloc, &.{Value.initString(alloc, "a")});
    try testing.expectEqualStrings("A", r3.asString());
}

test "split-lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try splitLinesFn(alloc, &.{Value.initString(alloc, "a\nb\r\nc")});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expectEqualStrings("a", result.asVector().items[0].asString());
    try testing.expectEqualStrings("b", result.asVector().items[1].asString());
    try testing.expectEqualStrings("c", result.asVector().items[2].asString());
}

test "index-of" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try indexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "ll") });
    try testing.expectEqual(@as(i64, 2), r1.asInteger());
    const r2 = try indexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz") });
    try testing.expect(r2.tag() == .nil);
    const r3 = try indexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "l"), Value.initInteger(3) });
    try testing.expectEqual(@as(i64, 3), r3.asInteger());
}

test "last-index-of" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try lastIndexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "l") });
    try testing.expectEqual(@as(i64, 3), r1.asInteger());
    const r2 = try lastIndexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz") });
    try testing.expect(r2.tag() == .nil);
    const r3 = try lastIndexOfFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "l"), Value.initInteger(2) });
    try testing.expectEqual(@as(i64, 2), r3.asInteger());
}

test "replace-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try replaceFirstFn(alloc, &.{ Value.initString(alloc, "aabaa"), Value.initString(alloc, "a"), Value.initString(alloc, "x") });
    try testing.expectEqualStrings("xabaa", r1.asString());
    const r2 = try replaceFirstFn(alloc, &.{ Value.initString(alloc, "hello"), Value.initString(alloc, "xyz"), Value.initString(alloc, "!") });
    try testing.expectEqualStrings("hello", r2.asString());
}

test "builtins table has 21 entries" {
    try testing.expectEqual(21, builtins.len);
}
