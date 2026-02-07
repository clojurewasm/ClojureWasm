// Regex builtins — re-pattern, re-find, re-matches, re-seq

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Pattern = value_mod.Pattern;
const PersistentList = @import("../collections.zig").PersistentList;
const PersistentVector = @import("../collections.zig").PersistentVector;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const regex_mod = @import("../regex/regex.zig");
const CompiledRegex = regex_mod.CompiledRegex;
const matcher_mod = @import("../regex/matcher.zig");
const MatchResult = matcher_mod.MatchResult;
const Matcher = matcher_mod.Matcher;
const err = @import("../error.zig");

/// Helper: get or compile a Pattern from a Value (string or regex)
fn getCompiledPattern(allocator: Allocator, val: Value) !*const CompiledRegex {
    return switch (val.tag()) {
        .regex => @ptrCast(@alignCast(val.asRegex().compiled)),
        .string => {
            const compiled = try allocator.create(CompiledRegex);
            compiled.* = try matcher_mod.compile(allocator, val.asString());
            return compiled;
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "re-find/re-matches pattern expects a regex or string, got {s}", .{@tagName(val.tag())}),
    };
}

/// Convert a match result to a Clojure value.
/// No capture groups → string. With groups → vector of [match, group1, ...].
fn matchResultToValue(allocator: Allocator, result: MatchResult, input: []const u8) !Value {
    if (result.groups.len <= 1) {
        // No capture groups: return matched string
        const text = input[result.start..result.end];
        return Value.initString(allocator, text);
    }

    // Has capture groups: return [whole-match, group1, group2, ...]
    const items = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            items[i] = Value.initString(allocator, span.text(input));
        } else {
            items[i] = Value.nil_val;
        }
    }
    const vec = try allocator.create(PersistentVector);
    vec.* = .{ .items = items, .meta = null };
    return Value.initVector(vec);
}

/// (re-pattern s) — compile string to Pattern; if already Pattern, return as-is
pub fn rePatternFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to re-pattern", .{args.len});
    return switch (args[0].tag()) {
        .regex => args[0], // already a Pattern
        .string => {
            const s = args[0].asString();
            const compiled = try allocator.create(CompiledRegex);
            compiled.* = matcher_mod.compile(allocator, s) catch return error.ValueError;
            const pat = try allocator.create(Pattern);
            pat.* = .{
                .source = s,
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return Value.initRegex(pat);
        },
        else => err.setErrorFmt(.eval, .type_error, .{}, "re-pattern expects a string, got {s}", .{@tagName(args[0].tag())}),
    };
}

/// (re-find pattern s) — find first match in string
pub fn reFindFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to re-find", .{args.len});

    const compiled = try getCompiledPattern(allocator, args[0]);
    const input = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "re-find expects a string as second argument, got {s}", .{@tagName(args[1].tag())}),
    };

    const result = try matcher_mod.findFirst(allocator, compiled, input) orelse {
        return Value.nil_val;
    };
    return matchResultToValue(allocator, result, input);
}

/// (re-matches pattern s) — match entire string
pub fn reMatchesFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to re-matches", .{args.len});

    const compiled = try getCompiledPattern(allocator, args[0]);
    const input = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "re-matches expects a string as second argument, got {s}", .{@tagName(args[1].tag())}),
    };

    var m = try Matcher.init(allocator, compiled, input);
    defer m.deinit();

    const result = try m.fullMatch() orelse {
        return Value.nil_val;
    };
    return matchResultToValue(allocator, result, input);
}

/// (re-seq pattern s) — list of all matches
pub fn reSeqFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to re-seq", .{args.len});

    const compiled = try getCompiledPattern(allocator, args[0]);
    const input = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "re-seq expects a string as second argument, got {s}", .{@tagName(args[1].tag())}),
    };

    var results: std.ArrayListUnmanaged(Value) = .empty;

    var m = try Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var pos: usize = 0;
    while (pos <= input.len) {
        const result = try m.find(pos) orelse break;
        const val = try matchResultToValue(allocator, result, input);
        try results.append(allocator, val);
        // Advance position (prevent infinite loop on zero-width match)
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const l = try allocator.create(PersistentList);
    l.* = .{ .items = try results.toOwnedSlice(allocator), .meta = null };
    return Value.initList(l);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "re-pattern",
        .func = &rePatternFn,
        .doc = "Returns an instance of java.util.regex.Pattern, for use, e.g. in re-seq.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "re-find",
        .func = &reFindFn,
        .doc = "Returns the next regex match, if any, of string to pattern.",
        .arglists = "([re s])",
        .added = "1.0",
    },
    .{
        .name = "re-matches",
        .func = &reMatchesFn,
        .doc = "Returns the match, if any, of string to pattern.",
        .arglists = "([re s])",
        .added = "1.0",
    },
    .{
        .name = "re-seq",
        .func = &reSeqFn,
        .doc = "Returns a lazy sequence of successive matches of pattern in string.",
        .arglists = "([re s])",
        .added = "1.0",
    },
};

// === Tests ===

const testing = std.testing;

test "re-pattern - string to pattern" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = [_]Value{Value.initString(allocator, "\\d+")};
    const result = try rePatternFn(allocator, &args);
    try testing.expect(result.tag() == .regex);
    try testing.expectEqualStrings("\\d+", result.asRegex().source);
}

test "re-pattern - pattern passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a pattern first
    const create_args = [_]Value{Value.initString(allocator, "abc")};
    const pat = try rePatternFn(allocator, &create_args);

    // Pass it through re-pattern — should return same value
    const args = [_]Value{pat};
    const result = try rePatternFn(allocator, &args);
    try testing.expect(result.tag() == .regex);
}

test "re-find - simple match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "\\d+")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "abc123def") };
    const result = try reFindFn(allocator, &args);
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("123", result.asString());
}

test "re-find - no match returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "\\d+")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "abc") };
    const result = try reFindFn(allocator, &args);
    try testing.expect(result.isNil());
}

test "re-find - with capture groups returns vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "(\\d+)-(\\d+)")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "x12-34y") };
    const result = try reFindFn(allocator, &args);
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expectEqualStrings("12-34", result.asVector().items[0].asString());
    try testing.expectEqualStrings("12", result.asVector().items[1].asString());
    try testing.expectEqualStrings("34", result.asVector().items[2].asString());
}

test "re-matches - full match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "\\d+")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "123") };
    const result = try reMatchesFn(allocator, &args);
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("123", result.asString());
}

test "re-matches - partial match returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "\\d+")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "abc123") };
    const result = try reMatchesFn(allocator, &args);
    try testing.expect(result.isNil());
}

test "re-seq - all matches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pat_args = [_]Value{Value.initString(allocator, "\\d+")};
    const pat = try rePatternFn(allocator, &pat_args);

    const args = [_]Value{ pat, Value.initString(allocator, "a1b22c333") };
    const result = try reSeqFn(allocator, &args);
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expectEqualStrings("1", result.asList().items[0].asString());
    try testing.expectEqualStrings("22", result.asList().items[1].asString());
    try testing.expectEqualStrings("333", result.asList().items[2].asString());
}
