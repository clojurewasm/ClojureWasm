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

test "builtins table has 5 entries" {
    try testing.expectEqual(5, builtins.len);
}
