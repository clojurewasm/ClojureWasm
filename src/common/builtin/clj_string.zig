// clojure.string namespace builtins — join, split, upper-case, lower-case, trim
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

/// (clojure.string/join coll)
/// (clojure.string/join separator coll)
/// Returns a string of all elements in coll, separated by separator.
pub fn joinFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    const sep: []const u8 = if (args.len == 2) blk: {
        if (args[0] != .string) return error.TypeError;
        break :blk args[0].string;
    } else "";

    const coll = if (args.len == 2) args[1] else args[0];
    const items = switch (coll) {
        .vector => |v| v.items,
        .list => |l| l.items,
        .nil => return Value{ .string = "" },
        else => return error.TypeError,
    };

    if (items.len == 0) return Value{ .string = "" };

    // Build result using Writer.Allocating
    var aw: Writer.Allocating = .init(allocator);
    for (items, 0..) |item, i| {
        if (i > 0 and sep.len > 0) {
            try aw.writer.writeAll(sep);
        }
        const s = try valueToStr(allocator, item);
        try aw.writer.writeAll(s);
    }

    return Value{ .string = try aw.toOwnedSlice() };
}

/// (clojure.string/split s re-or-str)
/// Splits string on a string pattern. Returns a vector of strings.
/// (Simplified: string pattern only, not regex.)
pub fn splitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string and args[1] != .regex) return error.TypeError;

    const s = args[0].string;
    const pattern = if (args[1] == .string) args[1].string else args[1].regex.source;

    if (pattern.len == 0) {
        // Split into individual characters
        var chars = std.ArrayList(Value).empty;
        var i: usize = 0;
        while (i < s.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + cp_len, s.len);
            const char_str = try allocator.dupe(u8, s[i..end]);
            try chars.append(allocator, Value{ .string = char_str });
            i = end;
        }
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = try chars.toOwnedSlice(allocator) };
        return Value{ .vector = vec };
    }

    var parts = std.ArrayList(Value).empty;
    var start: usize = 0;
    while (start <= s.len) {
        if (std.mem.indexOfPos(u8, s, start, pattern)) |pos| {
            const part = try allocator.dupe(u8, s[start..pos]);
            try parts.append(allocator, Value{ .string = part });
            start = pos + pattern.len;
        } else {
            const part = try allocator.dupe(u8, s[start..]);
            try parts.append(allocator, Value{ .string = part });
            break;
        }
    }

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = try parts.toOwnedSlice(allocator) };
    return Value{ .vector = vec };
}

/// (clojure.string/upper-case s)
pub fn upperCaseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return Value{ .string = result };
}

/// (clojure.string/lower-case s)
pub fn lowerCaseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return Value{ .string = result };
}

/// (clojure.string/trim s)
pub fn trimFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const trimmed = std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
    return Value{ .string = trimmed };
}

/// (clojure.string/includes? s substr)
/// True if s includes substr.
pub fn includesFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    return Value{ .boolean = std.mem.indexOf(u8, args[0].string, args[1].string) != null };
}

/// (clojure.string/starts-with? s substr)
/// True if s starts with substr.
pub fn startsWithFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    return Value{ .boolean = std.mem.startsWith(u8, args[0].string, args[1].string) };
}

/// (clojure.string/ends-with? s substr)
/// True if s ends with substr.
pub fn endsWithFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    return Value{ .boolean = std.mem.endsWith(u8, args[0].string, args[1].string) };
}

/// (clojure.string/replace s match replacement)
/// Replaces all instances of match with replacement in s.
pub fn replaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    if (args[2] != .string) return error.TypeError;

    const s = args[0].string;
    const match = args[1].string;
    const replacement = args[2].string;

    if (match.len == 0) return args[0]; // no-op for empty match

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
    } else {
        // If start == s.len exactly after last match, nothing left to write
    }

    return Value{ .string = try aw.toOwnedSlice() };
}

/// (clojure.string/replace-first s match replacement)
/// Replaces the first instance of match with replacement in s.
pub fn replaceFirstFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    if (args[2] != .string) return error.TypeError;

    const s = args[0].string;
    const match = args[1].string;
    const replacement = args[2].string;

    if (match.len == 0) return args[0];

    if (std.mem.indexOf(u8, s, match)) |pos| {
        var aw: Writer.Allocating = .init(allocator);
        try aw.writer.writeAll(s[0..pos]);
        try aw.writer.writeAll(replacement);
        try aw.writer.writeAll(s[pos + match.len ..]);
        return Value{ .string = try aw.toOwnedSlice() };
    }
    return args[0];
}

/// (clojure.string/capitalize s)
/// Converts first character to upper-case, all other characters to lower-case.
pub fn capitalizeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    if (s.len == 0) return args[0];
    const result = try allocator.alloc(u8, s.len);
    result[0] = std.ascii.toUpper(s[0]);
    for (s[1..], 1..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return Value{ .string = result };
}

/// (clojure.string/split-lines s)
/// Splits s on \n or \r\n. Returns a vector of strings.
pub fn splitLinesFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;

    var parts = std.ArrayList(Value).empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value{ .string = part });
            start = i + 1;
        } else if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value{ .string = part });
            start = i + 2;
            i += 1; // skip \n
        } else if (s[i] == '\r') {
            const part = try allocator.dupe(u8, s[start..i]);
            try parts.append(allocator, Value{ .string = part });
            start = i + 1;
        }
        i += 1;
    }
    // Add remaining
    const part = try allocator.dupe(u8, s[start..]);
    try parts.append(allocator, Value{ .string = part });

    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = try parts.toOwnedSlice(allocator) };
    return Value{ .vector = vec };
}

/// (clojure.string/index-of s value)
/// (clojure.string/index-of s value from-index)
/// Returns the index of value in s, optionally starting from from-index.
pub fn indexOfFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    const s = args[0].string;
    const sub = args[1].string;
    const from: usize = if (args.len == 3) blk: {
        if (args[2] != .integer) return error.TypeError;
        const idx = args[2].integer;
        break :blk if (idx < 0) 0 else @intCast(idx);
    } else 0;
    if (from > s.len) return Value.nil;
    if (std.mem.indexOfPos(u8, s, from, sub)) |pos| {
        return Value{ .integer = @intCast(pos) };
    }
    return Value.nil;
}

/// (clojure.string/last-index-of s value)
/// (clojure.string/last-index-of s value from-index)
/// Returns the last index of value in s, optionally searching backward from from-index.
pub fn lastIndexOfFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    const s = args[0].string;
    const sub = args[1].string;
    const search_end: usize = if (args.len == 3) blk: {
        if (args[2] != .integer) return error.TypeError;
        const idx = args[2].integer;
        const end: usize = if (idx < 0) 0 else @intCast(idx);
        break :blk @min(end + sub.len, s.len);
    } else s.len;
    if (std.mem.lastIndexOf(u8, s[0..search_end], sub)) |pos| {
        return Value{ .integer = @intCast(pos) };
    }
    return Value.nil;
}

/// (clojure.string/blank? s)
/// True if s is nil, empty, or contains only whitespace.
pub fn blankFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => Value{ .boolean = true },
        .string => |s| Value{ .boolean = std.mem.trim(u8, s, " \t\n\r\x0b\x0c").len == 0 },
        else => error.TypeError,
    };
}

/// (clojure.string/reverse s)
/// Returns s with its characters reversed.
pub fn reverseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
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
    return Value{ .string = result };
}

/// (clojure.string/trim-newline s)
/// Removes all trailing newline (\n) and carriage return (\r) characters from s.
pub fn trimNewlineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const trimmed = std.mem.trimRight(u8, s, "\r\n");
    return Value{ .string = trimmed };
}

/// (clojure.string/triml s)
/// Removes whitespace from the left side of s.
pub fn trimlFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const trimmed = std.mem.trimLeft(u8, s, " \t\n\r\x0b\x0c");
    return Value{ .string = trimmed };
}

/// (clojure.string/trimr s)
/// Removes whitespace from the right side of s.
pub fn trimrFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string;
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r\x0b\x0c");
    return Value{ .string = trimmed };
}

const Writer = std.Io.Writer;

// Helper: convert a Value to its string representation for join
// Uses str semantics (nil -> "", strings unquoted)
fn valueToStr(allocator: Allocator, val: Value) anyerror![]const u8 {
    return switch (val) {
        .string => |s| s,
        .nil => "",
        else => blk: {
            var aw: Writer.Allocating = .init(allocator);
            val.formatStr(&aw.writer) catch return error.TypeError;
            break :blk try aw.toOwnedSlice();
        },
    };
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
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "join with separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try joinFn(alloc, &.{ .{ .string = ", " }, .{ .vector = vec } });
    try testing.expectEqualStrings("a, b, c", result.string);
}

test "join without separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const vec = try alloc.create(PersistentVector);
    vec.* = .{ .items = &items };

    const result = try joinFn(alloc, &.{.{ .vector = vec }});
    try testing.expectEqualStrings("ab", result.string);
}

test "upper-case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try upperCaseFn(arena.allocator(), &.{.{ .string = "hello" }});
    try testing.expectEqualStrings("HELLO", result.string);
}

test "lower-case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try lowerCaseFn(arena.allocator(), &.{.{ .string = "HELLO" }});
    try testing.expectEqualStrings("hello", result.string);
}

test "trim" {
    const result = try trimFn(undefined, &.{.{ .string = "  hello  " }});
    try testing.expectEqualStrings("hello", result.string);
}

test "trim newlines" {
    const result = try trimFn(undefined, &.{.{ .string = "\n hello \t" }});
    try testing.expectEqualStrings("hello", result.string);
}

test "split basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try splitFn(alloc, &.{ .{ .string = "a,b,c" }, .{ .string = "," } });
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try testing.expectEqualStrings("a", result.vector.items[0].string);
    try testing.expectEqualStrings("b", result.vector.items[1].string);
    try testing.expectEqualStrings("c", result.vector.items[2].string);
}

test "includes? found" {
    const result = try includesFn(undefined, &.{ .{ .string = "hello world" }, .{ .string = "world" } });
    try testing.expectEqual(true, result.boolean);
}

test "includes? not found" {
    const result = try includesFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "xyz" } });
    try testing.expectEqual(false, result.boolean);
}

test "starts-with?" {
    const t = try startsWithFn(undefined, &.{ .{ .string = "hello world" }, .{ .string = "hello" } });
    try testing.expectEqual(true, t.boolean);
    const f = try startsWithFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "xyz" } });
    try testing.expectEqual(false, f.boolean);
}

test "ends-with?" {
    const t = try endsWithFn(undefined, &.{ .{ .string = "hello world" }, .{ .string = "world" } });
    try testing.expectEqual(true, t.boolean);
    const f = try endsWithFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "xyz" } });
    try testing.expectEqual(false, f.boolean);
}

test "replace string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try replaceFn(arena.allocator(), &.{ .{ .string = "hello world" }, .{ .string = "world" }, .{ .string = "zig" } });
    try testing.expectEqualStrings("hello zig", result.string);
}

test "replace all occurrences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try replaceFn(arena.allocator(), &.{ .{ .string = "aabaa" }, .{ .string = "a" }, .{ .string = "x" } });
    try testing.expectEqualStrings("xxbxx", result.string);
}

test "blank? true cases" {
    try testing.expectEqual(true, (try blankFn(undefined, &.{.nil})).boolean);
    try testing.expectEqual(true, (try blankFn(undefined, &.{.{ .string = "" }})).boolean);
    try testing.expectEqual(true, (try blankFn(undefined, &.{.{ .string = "  \t\n" }})).boolean);
}

test "blank? false" {
    try testing.expectEqual(false, (try blankFn(undefined, &.{.{ .string = "a" }})).boolean);
}

test "reverse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try reverseFn(arena.allocator(), &.{.{ .string = "hello" }});
    try testing.expectEqualStrings("olleh", result.string);
}

test "trim-newline" {
    const result = try trimNewlineFn(undefined, &.{.{ .string = "hello\r\n" }});
    try testing.expectEqualStrings("hello", result.string);
}

test "triml" {
    const result = try trimlFn(undefined, &.{.{ .string = "  hello  " }});
    try testing.expectEqualStrings("hello  ", result.string);
}

test "trimr" {
    const result = try trimrFn(undefined, &.{.{ .string = "  hello  " }});
    try testing.expectEqualStrings("  hello", result.string);
}

test "capitalize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r1 = try capitalizeFn(arena.allocator(), &.{.{ .string = "hello WORLD" }});
    try testing.expectEqualStrings("Hello world", r1.string);
    const r2 = try capitalizeFn(arena.allocator(), &.{.{ .string = "" }});
    try testing.expectEqualStrings("", r2.string);
    const r3 = try capitalizeFn(arena.allocator(), &.{.{ .string = "a" }});
    try testing.expectEqualStrings("A", r3.string);
}

test "split-lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try splitLinesFn(alloc, &.{.{ .string = "a\nb\r\nc" }});
    try testing.expect(result == .vector);
    try testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try testing.expectEqualStrings("a", result.vector.items[0].string);
    try testing.expectEqualStrings("b", result.vector.items[1].string);
    try testing.expectEqualStrings("c", result.vector.items[2].string);
}

test "index-of" {
    const r1 = try indexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "ll" } });
    try testing.expectEqual(@as(i64, 2), r1.integer);
    const r2 = try indexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "xyz" } });
    try testing.expect(r2 == .nil);
    const r3 = try indexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "l" }, .{ .integer = 3 } });
    try testing.expectEqual(@as(i64, 3), r3.integer);
}

test "last-index-of" {
    const r1 = try lastIndexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "l" } });
    try testing.expectEqual(@as(i64, 3), r1.integer);
    const r2 = try lastIndexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "xyz" } });
    try testing.expect(r2 == .nil);
    const r3 = try lastIndexOfFn(undefined, &.{ .{ .string = "hello" }, .{ .string = "l" }, .{ .integer = 2 } });
    try testing.expectEqual(@as(i64, 2), r3.integer);
}

test "replace-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r1 = try replaceFirstFn(arena.allocator(), &.{ .{ .string = "aabaa" }, .{ .string = "a" }, .{ .string = "x" } });
    try testing.expectEqualStrings("xabaa", r1.string);
    const r2 = try replaceFirstFn(arena.allocator(), &.{ .{ .string = "hello" }, .{ .string = "xyz" }, .{ .string = "!" } });
    try testing.expectEqualStrings("hello", r2.string);
}

test "builtins table has 19 entries" {
    try testing.expectEqual(19, builtins.len);
}
