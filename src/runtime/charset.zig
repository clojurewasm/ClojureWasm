// SPDX-License-Identifier: EPL-2.0
//! UTF-8 charset helpers per ADR-0014 (cw v1 internal string is
//! UTF-8). Namespace-neutral implementation per F-009.
//!
//! cw v1 stores all strings as `[]const u8` byte slices in UTF-8.
//! Clojure-level `count` / `subs` / `nth` over strings need
//! codepoint-aware indexing because users expect "あいう" to be
//! 3 chars, not 9. This file provides the bytes ↔ codepoint mapping.
//!
//! Surfaces (Phase 6+):
//!   - `lang/primitive/string.zig` — clojure.core `count` / `subs` /
//!     `nth` over string. Lands at 6.9 alongside clojure.string.
//!   - `runtime/java/nio/charset/Charset.zig` — Phase 14+ surface
//!     for `Charset.forName("UTF-8")` etc. The Java legacy
//!     `String#charAt` semantics (UTF-16 code unit) is **not**
//!     supported in cw v1; Java surface returns codepoint-based
//!     positions instead (ADR-0014 D-014a).

const std = @import("std");

pub const Utf8Error = error{InvalidUtf8};

/// Count codepoints in `s`. Returns `InvalidUtf8` on malformed
/// input — std.unicode.utf8CountCodepoints already does the
/// validation pass.
pub fn codepointCount(s: []const u8) Utf8Error!usize {
    return std.unicode.utf8CountCodepoints(s) catch error.InvalidUtf8;
}

/// Codepoint at index `i` (0-based). `InvalidUtf8` on malformed
/// input; `error.IndexOutOfBounds` when `i >= codepointCount(s)`.
pub fn codepointAt(s: []const u8, i: usize) (Utf8Error || error{IndexOutOfBounds})!u21 {
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var n: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        if (n == i) return cp;
        n += 1;
    }
    return error.IndexOutOfBounds;
}

/// Byte slice from codepoint index `start` (inclusive) to `end`
/// (exclusive). Returns the empty slice when `start == end`.
pub fn substring(s: []const u8, start: usize, end: usize) Utf8Error![]const u8 {
    std.debug.assert(start <= end);
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var n: usize = 0;
    var byte_start: usize = 0;
    var byte_end: usize = s.len;
    var found_start = false;
    while (true) {
        if (n == start) {
            byte_start = iter.i;
            found_start = true;
        }
        if (n == end) {
            byte_end = iter.i;
            break;
        }
        if (iter.nextCodepoint() == null) {
            if (!found_start) byte_start = iter.i;
            byte_end = iter.i;
            break;
        }
        n += 1;
    }
    return s[byte_start..byte_end];
}

/// Allocate a new UTF-8 byte slice with every ASCII lowercase
/// codepoint replaced by its uppercase pair. Non-ASCII codepoints
/// pass through verbatim. Per Phase 6.9 cycle 1, full Unicode case
/// folding (Latin Extended, Greek, Cyrillic, …) is tracked at debt
/// D-057 and lands when `clojure.string` graduates to JVM-conformance
/// (Phase 11+). Caller owns the returned slice.
pub fn upperCaseAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    @memcpy(out, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

/// ASCII case-fold mirror of `upperCaseAlloc`. Same Phase-11 Unicode
/// caveat applies (D-057).
pub fn lowerCaseAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    @memcpy(out, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// JVM `Character.isWhitespace` mirror — recognises ASCII space, tab,
/// CR, LF, FF, VT (matches `std.ascii.isWhitespace`) plus the Unicode
/// SPACE_SEPARATOR / LINE_SEPARATOR / PARAGRAPH_SEPARATOR codepoints
/// (U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000).
/// Excludes U+00A0 NO-BREAK SPACE per JVM convention. Returns true on
/// an empty string (vacuous truth — `blank?` callers special-case this
/// at the source level if they need to).
pub fn isAllWhitespace(s: []const u8) !bool {
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (!isWhitespaceCodepoint(cp)) return false;
    }
    return true;
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return switch (cp) {
        // ASCII whitespace (matches std.ascii.isWhitespace).
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        // Unicode SPACE_SEPARATOR / LINE_SEPARATOR / PARAGRAPH_SEPARATOR
        // categories recognised by JVM Character.isWhitespace. Excludes
        // U+00A0 / U+2007 / U+202F (NO-BREAK / FIGURE / NARROW NO-BREAK
        // SPACE) — JVM treats those as non-whitespace.
        0x1680, 0x2028, 0x2029, 0x205F, 0x3000 => true,
        0x2000...0x2006 => true,
        0x2008...0x200A => true,
        else => false,
    };
}

/// Slice off leading whitespace codepoints per `isAllWhitespace`'s
/// predicate (JVM `Character.isWhitespace` mirror). Returns a byte
/// sub-slice of `s` — no allocation. On malformed UTF-8 returns the
/// input unchanged.
pub fn trimLeft(s: []const u8) []const u8 {
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (true) {
        const before = iter.i;
        const cp = iter.nextCodepoint() orelse return s[before..];
        if (!isWhitespaceCodepoint(cp)) return s[before..];
    }
}

/// Mirror of `trimLeft` for the trailing edge. Iterates the entire
/// string once forward, tracking the byte position just past the
/// most recent non-whitespace codepoint. O(n) but allocation-free.
pub fn trimRight(s: []const u8) []const u8 {
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var end_byte: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        if (!isWhitespaceCodepoint(cp)) end_byte = iter.i;
    }
    return s[0..end_byte];
}

/// `trimLeft` + `trimRight`. Returns a byte sub-slice; no allocation.
pub fn trim(s: []const u8) []const u8 {
    return trimRight(trimLeft(s));
}

/// `clojure.string/trim-newline` mirror — strip ONLY trailing `\r`
/// and `\n` (ASCII line terminators), not the broader Unicode
/// whitespace set. Byte-level scan; no codepoint iteration needed
/// because `\r` (0x0D) and `\n` (0x0A) are single-byte UTF-8
/// codepoints.
pub fn trimNewlineRight(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[0..end];
}

/// Codepoint index of the first occurrence of `needle` in `haystack`,
/// or `null` if absent. Both must be valid UTF-8. Per cw v1
/// DIVERGENCE D1 the unit is codepoint, not byte / UTF-16 code unit
/// (the JVM `String.indexOf` UTF-16 quirk does not apply here).
/// Empty `needle` matches at codepoint 0.
pub fn codepointIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = haystack, .i = 0 };
    var cp_pos: usize = 0;
    var byte_pos: usize = 0;
    while (byte_pos + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[byte_pos..][0..needle.len], needle))
            return cp_pos;
        if (iter.nextCodepoint() == null) return null;
        byte_pos = iter.i;
        cp_pos += 1;
    }
    return null;
}

/// Codepoint index of the LAST occurrence of `needle` in `haystack`.
/// Implementation: forward scan tracking the most recent match
/// position (O(n·m) worst case — fine at clojure.string scale).
pub fn codepointLastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) {
        // JVM `lastIndexOf("")` returns the string length; in cw v1
        // codepoint units that's `codepointCount(haystack)`.
        return codepointCount(haystack) catch return null;
    }
    var last: ?usize = null;
    var iter = std.unicode.Utf8Iterator{ .bytes = haystack, .i = 0 };
    var cp_pos: usize = 0;
    var byte_pos: usize = 0;
    while (byte_pos < haystack.len) {
        if (byte_pos + needle.len <= haystack.len and
            std.mem.eql(u8, haystack[byte_pos..][0..needle.len], needle))
        {
            last = cp_pos;
        }
        if (iter.nextCodepoint() == null) return last;
        byte_pos = iter.i;
        cp_pos += 1;
    }
    return last;
}

/// Replace every non-overlapping `needle` with `replacement` (string ⇒
/// string semantics). Allocates a fresh slice on `alloc`; on `needle`
/// match the substitution does NOT recurse (a la JVM
/// `String.replace` — replacement bytes are not re-scanned). Empty
/// `needle` returns a copy of `haystack` (matches JVM behaviour of
/// not infinite-looping on empty needle).
pub fn replaceAllStringAlloc(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return try alloc.dupe(u8, haystack);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and
            std.mem.eql(u8, haystack[i..][0..needle.len], needle))
        {
            try out.appendSlice(alloc, replacement);
            i += needle.len;
        } else {
            try out.append(alloc, haystack[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Replace the FIRST occurrence of `needle` with `replacement`.
/// Allocation rules match `replaceAllStringAlloc`.
pub fn replaceFirstStringAlloc(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return try alloc.dupe(u8, haystack);
    const hit = std.mem.find(u8, haystack, needle) orelse return try alloc.dupe(u8, haystack);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, haystack[0..hit]);
    try out.appendSlice(alloc, replacement);
    try out.appendSlice(alloc, haystack[hit + needle.len ..]);
    return try out.toOwnedSlice(alloc);
}

/// Reverse the codepoint order of `s`, returning a fresh UTF-8 byte
/// slice. Surrogate pairs do not exist in UTF-8, so single-codepoint
/// reverse is the natural semantics (JVM `StringBuilder.reverse()`
/// has UTF-16 surrogate-aware code; cw v1 sidesteps the issue).
pub fn reverseCodepointsAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    errdefer alloc.free(out);
    // Walk forward, copy each codepoint's bytes into the tail of `out`
    // such that earlier codepoints end up later. One forward pass.
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var write_end: usize = s.len;
    var prev_i: usize = 0;
    while (iter.nextCodepoint()) |_| {
        const cp_bytes = s[prev_i..iter.i];
        write_end -= cp_bytes.len;
        @memcpy(out[write_end..][0..cp_bytes.len], cp_bytes);
        prev_i = iter.i;
    }
    return out;
}

// --- tests ---

const testing = std.testing;

test "codepointCount on ASCII matches byte length" {
    try testing.expectEqual(@as(usize, 5), try codepointCount("hello"));
}

test "codepointCount on multibyte UTF-8" {
    try testing.expectEqual(@as(usize, 3), try codepointCount("あいう"));
    try testing.expectEqual(@as(usize, 5), try codepointCount("aあbいc"));
}

test "codepointAt returns the right codepoint at an offset" {
    const s = "aあbいc";
    try testing.expectEqual(@as(u21, 'a'), try codepointAt(s, 0));
    try testing.expectEqual(@as(u21, 0x3042), try codepointAt(s, 1)); // あ
    try testing.expectEqual(@as(u21, 'b'), try codepointAt(s, 2));
    try testing.expectEqual(@as(u21, 0x3044), try codepointAt(s, 3)); // い
    try testing.expectEqual(@as(u21, 'c'), try codepointAt(s, 4));
}

test "codepointAt out-of-bounds raises" {
    try testing.expectError(error.IndexOutOfBounds, codepointAt("ab", 5));
}

test "upperCaseAlloc folds ASCII codepoints" {
    const out = try upperCaseAlloc(testing.allocator, "Hello World");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("HELLO WORLD", out);
}

test "upperCaseAlloc passes non-ASCII through" {
    const out = try upperCaseAlloc(testing.allocator, "あいう");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("あいう", out);
}

test "lowerCaseAlloc folds ASCII codepoints" {
    const out = try lowerCaseAlloc(testing.allocator, "HELLO");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "isAllWhitespace true on empty string" {
    try testing.expect(try isAllWhitespace(""));
}

test "isAllWhitespace true on ASCII whitespace mix" {
    try testing.expect(try isAllWhitespace("  \t\n"));
}

test "isAllWhitespace true on Unicode ideographic space" {
    try testing.expect(try isAllWhitespace("\u{3000}\u{3000}"));
}

test "isAllWhitespace false on non-whitespace mixed in" {
    try testing.expect(!try isAllWhitespace("  hi  "));
}

test "isAllWhitespace false on NO-BREAK SPACE (JVM divergence)" {
    try testing.expect(!try isAllWhitespace("\u{00A0}"));
}

test "trimLeft strips ASCII spaces" {
    try testing.expectEqualStrings("hi  ", trimLeft("  hi  "));
}

test "trimLeft strips Unicode ideographic space" {
    try testing.expectEqualStrings("hi", trimLeft("\u{3000}\u{3000}hi"));
}

test "trimRight strips trailing whitespace" {
    try testing.expectEqualStrings("  hi", trimRight("  hi  "));
}

test "trim handles both ends" {
    try testing.expectEqualStrings("hi", trim("\t\n hi \r\n"));
}

test "trim on all-whitespace returns empty" {
    try testing.expectEqualStrings("", trim("   \t\n"));
}

test "trimNewlineRight strips only \\r and \\n" {
    try testing.expectEqualStrings("line", trimNewlineRight("line\r\n"));
    try testing.expectEqualStrings("  hi  ", trimNewlineRight("  hi  "));
}

test "codepointIndexOf finds ASCII substring" {
    try testing.expectEqual(@as(?usize, 6), codepointIndexOf("hello world", "world"));
    try testing.expectEqual(@as(?usize, null), codepointIndexOf("hello", "x"));
    try testing.expectEqual(@as(?usize, 0), codepointIndexOf("hello", ""));
}

test "codepointIndexOf returns codepoint index for multi-byte (D1)" {
    try testing.expectEqual(@as(?usize, 2), codepointIndexOf("あbいc", "い"));
}

test "codepointLastIndexOf finds last occurrence" {
    try testing.expectEqual(@as(?usize, 6), codepointLastIndexOf("hello hello", "hello"));
    try testing.expectEqual(@as(?usize, null), codepointLastIndexOf("hello", "x"));
}

test "replaceAllStringAlloc replaces every occurrence" {
    const out = try replaceAllStringAlloc(testing.allocator, "hello world", "l", "L");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("heLLo worLd", out);
}

test "replaceAllStringAlloc returns copy when needle empty" {
    const out = try replaceAllStringAlloc(testing.allocator, "hi", "", "x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi", out);
}

test "replaceFirstStringAlloc replaces only first" {
    const out = try replaceFirstStringAlloc(testing.allocator, "hello world", "l", "L");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("heLlo world", out);
}

test "reverseCodepointsAlloc reverses ASCII" {
    const out = try reverseCodepointsAlloc(testing.allocator, "hello");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("olleh", out);
}

test "reverseCodepointsAlloc reverses by codepoint not byte" {
    const out = try reverseCodepointsAlloc(testing.allocator, "あいう");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ういあ", out);
}

test "substring slices on codepoint boundaries" {
    const s = "aあbいc";
    try testing.expectEqualStrings("a", try substring(s, 0, 1));
    try testing.expectEqualStrings("あb", try substring(s, 1, 3));
    try testing.expectEqualStrings("いc", try substring(s, 3, 5));
    try testing.expectEqualStrings("", try substring(s, 2, 2));
}
