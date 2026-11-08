// SPDX-License-Identifier: EPL-2.0
//! Capture groups beyond the former 7-group inline cap: the Pike VM sizes its
//! capture slots per program (`match.zig:slotCount`), so wide, nested and
//! optional groups must all report exact spans, and the compiler bounds the
//! group count with a dedicated `TooManyGroups` error.

const std = @import("std");
const compile = @import("compile.zig");
const match = @import("match.zig");

const testing = std.testing;

/// Group `g`'s text in `input`, or null when the group did not participate.
fn groupText(r: match.MatchResult, input: []const u8, g: usize) ?[]const u8 {
    const span = r.group(g) orelse return null;
    return input[span.start..span.end];
}

fn expectGroups(r: match.MatchResult, input: []const u8, want: []const ?[]const u8) !void {
    for (want, 1..) |w, g| {
        const got = groupText(r, input, g);
        if (w) |ws| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(ws, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

// emmy/complex/impl.cljc:149: 8 capturing groups (one past the old cap),
// several optional.
const emmy = "([+-]?\\d+(\\.\\d*)?([Ee][+-]?\\d+)?)(\\s?([+-])?\\s?([+-]?\\d+(\\.\\d*)?([Ee][+-]?\\d+)?)[Ii])?";

test "8 groups compile (was the first rejected count)" {
    var prog = try compile.compile(testing.allocator, "(a)(b)(c)(d)(e)(f)(g)(h)", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 8), prog.capture_count);
    const input = "abcdefgh";
    const r = (try match.matchFull(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try expectGroups(r, input, &.{ "a", "b", "c", "d", "e", "f", "g", "h" });
}

test "40 groups: every span reported by find and matchFull" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    for (0..40) |i| {
        const ch: u8 = 'a' + @as(u8, @intCast(i % 26));
        try src.appendSlice(testing.allocator, &.{ '(', ch, ')' });
        try input.append(testing.allocator, ch);
    }
    var prog = try compile.compile(testing.allocator, src.items, .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 40), prog.capture_count);

    const f = (try match.find(testing.allocator, &prog, input.items)).?;
    defer f.deinit(testing.allocator);
    const m = (try match.matchFull(testing.allocator, &prog, input.items)).?;
    defer m.deinit(testing.allocator);
    for (0..40) |i| {
        try testing.expectEqualStrings(input.items[i .. i + 1], groupText(f, input.items, i + 1).?);
        try testing.expectEqualStrings(input.items[i .. i + 1], groupText(m, input.items, i + 1).?);
    }
}

test "nested groups beyond 8 keep their spans" {
    // ((((((((((x))))))))))y : 10 nested groups, all spanning "x".
    var prog = try compile.compile(testing.allocator, "((((((((((x))))))))))(y)", .{});
    defer prog.deinit(testing.allocator);
    const input = "zxy";
    const r = (try match.find(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try expectGroups(r, input, &.{ "x", "x", "x", "x", "x", "x", "x", "x", "x", "x", "y" });
}

test "Emmy complex pattern: 1+2i" {
    var prog = try compile.compile(testing.allocator, emmy, .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 8), prog.capture_count);
    const input = "1+2i";
    const r = (try match.matchFull(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try expectGroups(r, input, &.{ "1", null, null, "+2i", "+", "2", null, null });
}

test "Emmy complex pattern: -3.5e2 - 4I" {
    var prog = try compile.compile(testing.allocator, emmy, .{});
    defer prog.deinit(testing.allocator);
    const input = "-3.5e2 - 4I";
    const r = (try match.matchFull(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try expectGroups(r, input, &.{ "-3.5e2", ".5", "e2", " - 4I", "-", "4", null, null });
}

test "Emmy complex pattern: 7 leaves the optional imaginary groups unset" {
    var prog = try compile.compile(testing.allocator, emmy, .{});
    defer prog.deinit(testing.allocator);
    const input = "7";
    const r = (try match.matchFull(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try expectGroups(r, input, &.{ "7", null, null, null, null, null, null, null });
}

test "findAll over a 9-group pattern owns per-match captures" {
    var prog = try compile.compile(testing.allocator, "(a)(b)(c)(d)(e)(f)(g)(h)(\\d)", .{});
    defer prog.deinit(testing.allocator);
    const input = "abcdefgh1 abcdefgh2";
    var out: std.ArrayList(match.MatchResult) = .empty;
    defer {
        for (out.items) |m| m.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try match.findAll(testing.allocator, &prog, input, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("1", groupText(out.items[0], input, 9).?);
    try testing.expectEqualStrings("2", groupText(out.items[1], input, 9).?);
}

test "a positive lookahead's group beyond 8 threads into the result" {
    var prog = try compile.compile(testing.allocator, "(a)(b)(c)(d)(e)(f)(g)(h)(?=(i))", .{});
    defer prog.deinit(testing.allocator);
    const input = "abcdefghi";
    const r = (try match.find(testing.allocator, &prog, input)).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), r.end);
    try testing.expectEqualStrings("i", groupText(r, input, 9).?);
}

test "group-count bound: MAX_CAPTURE_GROUPS compile, one more is TooManyGroups" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..compile.MAX_CAPTURE_GROUPS) |_| try src.appendSlice(testing.allocator, "()");
    var prog = try compile.compile(testing.allocator, src.items, .{});
    prog.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "()");
    try testing.expectError(error.TooManyGroups, compile.compile(testing.allocator, src.items, .{}));
    // A named group counts toward the same bound (MAX unnamed + 1 named).
    src.items.len -= 2;
    try testing.expectEqual(compile.MAX_CAPTURE_GROUPS, @as(u16, @intCast(src.items.len / 2)));
    try src.appendSlice(testing.allocator, "(?<n>x)");
    try testing.expectError(error.TooManyGroups, compile.compile(testing.allocator, src.items, .{}));
}

test "a pattern without groups carries no capture slots" {
    var prog = try compile.compile(testing.allocator, "abc", .{});
    defer prog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), match.slotCount(&prog));
    const r = (try match.find(testing.allocator, &prog, "xabc")).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.captures.slots.len);
    try testing.expect(r.group(1) == null);
}
