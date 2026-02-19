// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Unicode codepoint utilities for UTF-8 strings.
//!
//! CW strings are UTF-8 encoded. Java's String API uses codepoint indices
//! (well, actually UTF-16 code units, but for BMP characters they're equivalent).
//! These utilities provide codepoint-based operations on UTF-8 strings.

const std = @import("std");

/// Count the number of Unicode codepoints in a UTF-8 string.
/// For ASCII-only strings this equals the byte length (fast path).
pub fn codepointCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Get the byte offset of the nth codepoint (0-indexed).
/// Returns null if index >= codepoint count.
pub fn codepointByteOffset(s: []const u8, codepoint_idx: usize) ?usize {
    var byte_offset: usize = 0;
    var cp_idx: usize = 0;
    while (byte_offset < s.len) {
        if (cp_idx == codepoint_idx) return byte_offset;
        const len = std.unicode.utf8ByteSequenceLength(s[byte_offset]) catch return null;
        byte_offset += len;
        cp_idx += 1;
    }
    // Allow index == count (one past end, for substring end)
    if (cp_idx == codepoint_idx) return byte_offset;
    return null;
}

/// Get the codepoint at a given codepoint index (0-indexed).
/// Returns null if index is out of range.
pub fn codepointAt(s: []const u8, codepoint_idx: usize) ?u21 {
    const offset = codepointByteOffset(s, codepoint_idx) orelse return null;
    if (offset >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[offset]) catch return null;
    if (offset + len > s.len) return null;
    return std.unicode.utf8Decode(s[offset..][0..len]) catch null;
}

/// Extract a substring by codepoint indices [begin, end).
/// Returns null if indices are out of range or begin > end.
pub fn codepointSlice(s: []const u8, begin: usize, end: usize) ?[]const u8 {
    if (begin > end) return null;
    const begin_offset = codepointByteOffset(s, begin) orelse return null;
    const end_offset = codepointByteOffset(s, end) orelse return null;
    if (begin_offset > s.len or end_offset > s.len) return null;
    return s[begin_offset..end_offset];
}

/// Extract a substring from begin codepoint index to end of string.
pub fn codepointSliceFrom(s: []const u8, begin: usize) ?[]const u8 {
    const begin_offset = codepointByteOffset(s, begin) orelse return null;
    if (begin_offset > s.len) return null;
    return s[begin_offset..];
}

/// Find the codepoint index of the first occurrence of needle in haystack.
/// Returns -1 if not found (matching Java's String.indexOf behavior).
pub fn codepointIndexOf(haystack: []const u8, needle: []const u8) i64 {
    const byte_pos = std.mem.indexOf(u8, haystack, needle) orelse return -1;
    // Count codepoints in haystack[0..byte_pos]
    return @intCast(codepointCount(haystack[0..byte_pos]));
}

/// Check if a string is pure ASCII (fast path optimization).
pub fn isAscii(s: []const u8) bool {
    for (s) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

// Tests
const testing = std.testing;

test "codepointCount — ASCII" {
    try testing.expectEqual(@as(usize, 5), codepointCount("hello"));
    try testing.expectEqual(@as(usize, 0), codepointCount(""));
}

test "codepointCount — Japanese" {
    try testing.expectEqual(@as(usize, 3), codepointCount("あいう"));
}

test "codepointCount — emoji" {
    try testing.expectEqual(@as(usize, 3), codepointCount("🎉🎊🎈"));
}

test "codepointCount — mixed" {
    try testing.expectEqual(@as(usize, 6), codepointCount("abcあいう"));
}

test "codepointAt — ASCII" {
    try testing.expectEqual(@as(u21, 'h'), codepointAt("hello", 0).?);
    try testing.expectEqual(@as(u21, 'o'), codepointAt("hello", 4).?);
    try testing.expect(codepointAt("hello", 5) == null);
}

test "codepointAt — Japanese" {
    try testing.expectEqual(@as(u21, 'あ'), codepointAt("あいう", 0).?);
    try testing.expectEqual(@as(u21, 'い'), codepointAt("あいう", 1).?);
    try testing.expectEqual(@as(u21, 'う'), codepointAt("あいう", 2).?);
    try testing.expect(codepointAt("あいう", 3) == null);
}

test "codepointAt — emoji" {
    try testing.expectEqual(@as(u21, 0x1F389), codepointAt("🎉🎊", 0).?); // party popper
    try testing.expectEqual(@as(u21, 0x1F38A), codepointAt("🎉🎊", 1).?); // confetti ball
}

test "codepointSlice — ASCII" {
    try testing.expectEqualStrings("ell", codepointSlice("hello", 1, 4).?);
    try testing.expectEqualStrings("hello", codepointSlice("hello", 0, 5).?);
}

test "codepointSlice — Japanese" {
    try testing.expectEqualStrings("いう", codepointSlice("あいう", 1, 3).?);
    try testing.expectEqualStrings("あ", codepointSlice("あいう", 0, 1).?);
}

test "codepointSliceFrom — Japanese" {
    try testing.expectEqualStrings("いう", codepointSliceFrom("あいう", 1).?);
}

test "codepointIndexOf — ASCII" {
    try testing.expectEqual(@as(i64, 2), codepointIndexOf("hello", "ll"));
    try testing.expectEqual(@as(i64, -1), codepointIndexOf("hello", "xyz"));
}

test "codepointIndexOf — Japanese" {
    try testing.expectEqual(@as(i64, 1), codepointIndexOf("あいう", "い"));
    try testing.expectEqual(@as(i64, 0), codepointIndexOf("あいう", "あ"));
}

test "codepointByteOffset — past end" {
    // Index == count is allowed (for substring end)
    try testing.expectEqual(@as(usize, 5), codepointByteOffset("hello", 5).?);
    try testing.expect(codepointByteOffset("hello", 6) == null);
}

test "isAscii" {
    try testing.expect(isAscii("hello"));
    try testing.expect(!isAscii("あ"));
    try testing.expect(isAscii(""));
}
