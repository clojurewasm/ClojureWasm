// SPDX-License-Identifier: EPL-2.0
//! UTF-8 charset helpers per ADR-0014 (cw v1 internal string is
//! UTF-8). Namespace-neutral implementation per F-009.
//!
//! cw v1 stores all strings as `[]const u8` byte slices in UTF-8.
//! Clojure-level `count` / `subs` / `nth` over strings need
//! codepoint-aware indexing because users expect "あいう" to be
//! 3 chars, not 9. This file provides the bytes ↔ codepoint mapping.
//!
//! Surfaces:
//!   - `lang/primitive/string.zig` — clojure.core `count` / `subs` /
//!     `nth` over string (shipped, alongside clojure.string).
//!   - `runtime/java/nio/charset/Charset.zig` — future surface for
//!     `Charset.forName("UTF-8")` etc. (not yet present). The Java
//!     legacy `String#charAt` semantics (UTF-16 code unit) is **not**
//!     supported in cw v1; Java surface returns codepoint-based
//!     positions instead (ADR-0014).

const std = @import("std");
const unicode_case = @import("unicode_case.zig");
const unicode_category = @import("unicode_category.zig");

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

/// True when every byte is < 0x80 (vectorised by the optimiser).
fn isAllAscii(s: []const u8) bool {
    var acc: u8 = 0;
    for (s) |c| acc |= c;
    return acc < 0x80;
}

/// Allocate the FULL-Unicode uppercase of `s` (JVM String.toUpperCase
/// semantics, D-057): SpecialCasing 1:n expansions (ß→SS, ﬁ→FI, ŉ→ʼN)
/// then the simple map, via the generated `unicode_case` tables. The
/// result may be LONGER than the input (1:n), so it grows an ArrayList.
/// Caller owns the returned slice.
pub fn upperCaseAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // PERF: an all-ASCII input folds byte-for-byte (every ASCII codepoint's
    // full Unicode mapping is its ASCII fold, one byte to one byte), so skip
    // the per-codepoint table walk. [refs: O-071]
    if (isAllAscii(s)) {
        const buf = try alloc.alloc(u8, s.len);
        for (s, buf) |c, *o| o.* = std.ascii.toUpper(c);
        return buf;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        var buf: [3]u21 = undefined;
        for (unicode_case.toUpperFull(cp, &buf)) |mapped| {
            try appendCodepoint(&out, alloc, mapped);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// FULL-Unicode lowercase (JVM String.toLowerCase, D-057), including the
/// one CONDITIONAL SpecialCasing rule String.toLowerCase applies:
/// **Final_Sigma** — Σ lowers to ς when preceded by a cased codepoint and
/// not followed by one ("ΣΟΦΟΣ" → "σοφος" with a final ς). "Cased" uses
/// the table's has-a-mapping approximation (full General_Category data is
/// not carried — covers Greek/Latin, the rule's real population).
pub fn lowerCaseAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // PERF: all-ASCII fast path; no Σ can occur in ASCII. [refs: O-071]
    if (isAllAscii(s)) {
        const buf = try alloc.alloc(u8, s.len);
        for (s, buf) |c, *o| o.* = std.ascii.toLower(c);
        return buf;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var prev_cased = false;
    while (iter.nextCodepoint()) |cp| {
        if (cp == 0x3A3) { // Σ — the Final_Sigma condition
            var look = iter; // value copy: peek the next codepoint
            const next_cased = if (look.nextCodepoint()) |nc| unicode_case.isCased(nc) else false;
            const sigma: u21 = if (prev_cased and !next_cased) 0x3C2 else 0x3C3;
            try appendCodepoint(&out, alloc, sigma);
        } else {
            var buf: [3]u21 = undefined;
            for (unicode_case.toLowerFull(cp, &buf)) |mapped| {
                try appendCodepoint(&out, alloc, mapped);
            }
        }
        prev_cased = unicode_case.isCased(cp);
    }
    return out.toOwnedSlice(alloc);
}

fn appendCodepoint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) !void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch return error.InvalidUtf8;
    try out.appendSlice(alloc, b[0..n]);
}

/// JVM `Character.isWhitespace` mirror over every codepoint of `s` —
/// see `isWhitespaceCodepoint` for the formula (Zs/Zl/Zp minus the
/// no-break spaces, plus the ASCII controls). Returns true on an empty
/// string (vacuous truth — `blank?` callers special-case this at the
/// source level if they need to).
pub fn isAllWhitespace(s: []const u8) !bool {
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (!isWhitespaceCodepoint(cp)) return false;
    }
    return true;
}

pub fn isWhitespaceCodepoint(cp: u21) bool {
    // JVM Character.isWhitespace: Zs minus the no-break spaces
    // (U+00A0 / U+2007 / U+202F), Zl, Zp, plus \t \n \v \f \r and the
    // 0x1C-0x1F file/group/record/unit separators.
    return switch (cp) {
        '\t', '\n', 0x0B, 0x0C, '\r', 0x1C...0x1F => true,
        0xA0, 0x2007, 0x202F => false,
        else => switch (unicode_category.categoryOf(cp)) {
            CAT.Zs, CAT.Zl, CAT.Zp => true,
            else => false,
        },
    };
}

// Single-codepoint character classification + case folding, shared by the
// `java.lang.Character` static surface (runtime/java/lang/Character.zig).
// Full-Unicode: the JVM classification formulas evaluated over the
// generated General_Category / contributory-property tables
// (unicode_category.zig, UCD 16.0.0) — the same data the JVM reads.

/// JVM Character.getType() category byte values (the subset the
/// classification formulas below reference).
const CAT = struct {
    const Lu = 1;
    const Ll = 2;
    const Lt = 3;
    const Lm = 4;
    const Lo = 5;
    const Mn = 6;
    const Mc = 8;
    const Nd = 9;
    const Nl = 10;
    const Zs = 12;
    const Zl = 13;
    const Zp = 14;
    const Cf = 16;
    const Pc = 23;
    const Sc = 26;
};

/// JVM Character.getType() byte value (0 = UNASSIGNED).
pub fn categoryOf(cp: u21) u5 {
    return unicode_category.categoryOf(cp);
}

/// JVM Character.getDirectionality() byte value (-1 = UNDEFINED).
pub fn directionalityOf(cp: u21) i8 {
    return unicode_category.directionalityOf(cp);
}

/// JVM `Character.isDigit` mirror: DECIMAL_DIGIT_NUMBER (Nd).
pub fn isDigitCodepoint(cp: u21) bool {
    return unicode_category.categoryOf(cp) == CAT.Nd;
}

/// JVM `Character.isLetter` mirror: Lu / Ll / Lt / Lm / Lo (Nl is NOT a
/// letter — `(Character/isLetter \Ⅰ)` is false on the JVM too).
pub fn isLetterCodepoint(cp: u21) bool {
    return switch (unicode_category.categoryOf(cp)) {
        CAT.Lu, CAT.Ll, CAT.Lt, CAT.Lm, CAT.Lo => true,
        else => false,
    };
}

/// JVM `Character.isTitleCase` mirror: TITLECASE_LETTER (Lt).
pub fn isTitleCaseCodepoint(cp: u21) bool {
    return unicode_category.categoryOf(cp) == CAT.Lt;
}

/// JVM `Character.isSpaceChar` mirror: Zs / Zl / Zp (NBSP included,
/// unlike isWhitespace).
pub fn isSpaceCharCodepoint(cp: u21) bool {
    return switch (unicode_category.categoryOf(cp)) {
        CAT.Zs, CAT.Zl, CAT.Zp => true,
        else => false,
    };
}

/// JVM `Character.isDefined` mirror: assigned (category != Cn).
pub fn isDefinedCodepoint(cp: u21) bool {
    return unicode_category.categoryOf(cp) != 0;
}

/// JVM `Character.isMirrored` mirror (Bidi_Mirrored property).
pub fn isMirroredCodepoint(cp: u21) bool {
    return unicode_category.isMirrored(cp);
}

/// JVM `Character.isIdeographic` mirror (Unicode Ideographic property).
pub fn isIdeographicCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.ideographic, cp);
}

/// JVM `Character.isAlphabetic` mirror: letters, LETTER_NUMBER, or the
/// Other_Alphabetic contributory property.
pub fn isAlphabeticCodepoint(cp: u21) bool {
    if (isLetterCodepoint(cp)) return true;
    if (unicode_category.categoryOf(cp) == CAT.Nl) return true;
    return unicode_category.hasProp(.other_alphabetic, cp);
}

/// JVM `Character.isJavaIdentifierStart` mirror: letters, Nl, currency
/// symbols (Sc), connector punctuation (Pc).
pub fn isJavaIdentifierStartCodepoint(cp: u21) bool {
    return switch (unicode_category.categoryOf(cp)) {
        CAT.Lu, CAT.Ll, CAT.Lt, CAT.Lm, CAT.Lo, CAT.Nl, CAT.Sc, CAT.Pc => true,
        else => false,
    };
}

/// JVM `Character.isJavaIdentifierPart` mirror: letters, Nl, Sc, Pc, Nd,
/// combining/non-spacing marks (Mc/Mn), or identifier-ignorable.
pub fn isJavaIdentifierPartCodepoint(cp: u21) bool {
    return switch (unicode_category.categoryOf(cp)) {
        CAT.Lu, CAT.Ll, CAT.Lt, CAT.Lm, CAT.Lo, CAT.Nl, CAT.Sc, CAT.Pc, CAT.Nd, CAT.Mc, CAT.Mn => true,
        else => isIdentifierIgnorableCodepoint(cp),
    };
}

/// JVM `Character.isUnicodeIdentifierStart` mirror: letters, Nl, or
/// Other_ID_Start.
pub fn isUnicodeIdentifierStartCodepoint(cp: u21) bool {
    if (isLetterCodepoint(cp)) return true;
    if (unicode_category.categoryOf(cp) == CAT.Nl) return true;
    return unicode_category.hasProp(.other_id_start, cp);
}

/// JVM `Character.isUnicodeIdentifierPart` mirror: letters, Nl, Nd,
/// Mc/Mn, Pc, identifier-ignorable, Other_ID_Start, Other_ID_Continue.
pub fn isUnicodeIdentifierPartCodepoint(cp: u21) bool {
    switch (unicode_category.categoryOf(cp)) {
        CAT.Lu, CAT.Ll, CAT.Lt, CAT.Lm, CAT.Lo, CAT.Nl, CAT.Nd, CAT.Mc, CAT.Mn, CAT.Pc => return true,
        else => {},
    }
    if (isIdentifierIgnorableCodepoint(cp)) return true;
    if (unicode_category.hasProp(.other_id_start, cp)) return true;
    return unicode_category.hasProp(.other_id_continue, cp);
}

/// JVM `Character.isIdentifierIgnorable` mirror: the non-whitespace ISO
/// controls (0x00-0x08 / 0x0E-0x1B / 0x7F-0x9F) plus format chars (Cf).
pub fn isIdentifierIgnorableCodepoint(cp: u21) bool {
    return switch (cp) {
        0x00...0x08, 0x0E...0x1B, 0x7F...0x9F => true,
        else => unicode_category.categoryOf(cp) == CAT.Cf,
    };
}

// JVM `Character.isEmoji*` family (JDK 21) — direct reads of the UCD
// emoji-data.txt properties, generated alongside the contributory ones.
pub fn isEmojiCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.emoji, cp);
}
pub fn isEmojiPresentationCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.emoji_presentation, cp);
}
pub fn isEmojiModifierCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.emoji_modifier, cp);
}
pub fn isEmojiModifierBaseCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.emoji_modifier_base, cp);
}
pub fn isEmojiComponentCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.emoji_component, cp);
}
pub fn isExtendedPictographicCodepoint(cp: u21) bool {
    return unicode_category.hasProp(.extended_pictographic, cp);
}

/// JVM `Character.toUpperCase` mirror — the SIMPLE 1:1 Unicode map (D-057:
/// ä→Ä, σ→Σ; ß stays ß — SpecialCasing 1:n belongs to STRING upper-case
/// only, the JVM full-vs-simple split).
pub fn toUpperCodepoint(cp: u21) u21 {
    return unicode_case.toUpperSimple(cp);
}

/// JVM `Character.toLowerCase` mirror — the SIMPLE 1:1 Unicode map.
pub fn toLowerCodepoint(cp: u21) u21 {
    return unicode_case.toLowerSimple(cp);
}

/// JVM `Character.isUpperCase` mirror: UPPERCASE_LETTER (Lu) or the
/// Other_Uppercase contributory property (Roman numerals Ⅰ, circled Ⓐ).
pub fn isUpperCodepoint(cp: u21) bool {
    return unicode_category.categoryOf(cp) == CAT.Lu or
        unicode_category.hasProp(.other_uppercase, cp);
}

/// JVM `Character.isLowerCase` mirror: LOWERCASE_LETTER (Ll) or the
/// Other_Lowercase contributory property (feminine ordinal ª, modifier ⁱ).
pub fn isLowerCodepoint(cp: u21) bool {
    return unicode_category.categoryOf(cp) == CAT.Ll or
        unicode_category.hasProp(.other_lowercase, cp);
}

/// JVM `Character.toTitleCase` mirror — the SIMPLE 1:1 titlecase map
/// (explicit Lt digraph mappings, falling back to the simple uppercase).
pub fn toTitleCodepoint(cp: u21) u21 {
    return unicode_case.toTitleSimple(cp);
}

/// JVM `Character.isLetterOrDigit` mirror (ASCII; D-057 Unicode caveat).
pub fn isLetterOrDigitCodepoint(cp: u21) bool {
    return isLetterCodepoint(cp) or isDigitCodepoint(cp);
}

/// JVM `Character.forDigit` mirror — the char for digit value `d` in
/// `radix` (`0`-`9` then `a`-`z`), or the null char (codepoint 0) when
/// `d` is at least `radix` or radix is outside 2..36.
pub fn forDigit(d: u8, radix: u8) u21 {
    if (radix < 2 or radix > 36 or d >= radix) return 0;
    return if (d < 10) '0' + @as(u21, d) else 'a' + @as(u21, d) - 10;
}

/// The 10-35 letter-digit value of `cp` (a-z / A-Z and their fullwidth
/// forms ａ-ｚ / Ａ-Ｚ — the JVM Character.digit letter set), or null.
fn letterDigitValue(cp: u21) ?u8 {
    return switch (cp) {
        'a'...'z' => @intCast(cp - 'a' + 10),
        'A'...'Z' => @intCast(cp - 'A' + 10),
        0xFF41...0xFF5A => @intCast(cp - 0xFF41 + 10), // ａ-ｚ
        0xFF21...0xFF3A => @intCast(cp - 0xFF21 + 10), // Ａ-Ｚ
        else => null,
    };
}

/// JVM `Character.digit` mirror — the value of `cp` as a digit in `radix`:
/// any Unicode decimal digit (Nd: `\٥` → 5), then a-z/A-Z (incl. the
/// fullwidth forms) = 10-35. `null` if `cp` is not such a digit or its
/// value is ≥ radix. `(Character/digit \f 16)` → 15; `\z 16` → null.
pub fn digitValue(cp: u21, radix: u8) ?u8 {
    const v: u8 = unicode_category.decimalDigitValue(cp) orelse
        (letterDigitValue(cp) orelse return null);
    return if (v < radix) v else null;
}

/// JVM `Character.getNumericValue` mirror: decimal digits and a-z/A-Z
/// (incl. fullwidth) as in `digitValue`, plus non-decimal numerics via the
/// UCD Numeric_Value (Ⅶ → 7); -2 for fractional values (½); -1 when the
/// codepoint has no numeric value.
pub fn numericValueOf(cp: u21) i32 {
    if (unicode_category.decimalDigitValue(cp)) |v| return v;
    if (letterDigitValue(cp)) |v| return v;
    if (unicode_category.numericValue(cp)) |v| return v;
    return -1;
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
/// `String.replace` — replacement bytes are not re-scanned). An empty
/// `needle` matches at every codepoint boundary, including both ends.
pub fn replaceAllStringAlloc(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, replacement);
        var iter = std.unicode.Utf8Iterator{ .bytes = haystack, .i = 0 };
        var byte_start: usize = 0;
        while (iter.nextCodepoint()) |_| {
            try out.appendSlice(alloc, haystack[byte_start..iter.i]);
            try out.appendSlice(alloc, replacement);
            byte_start = iter.i;
        }
        return try out.toOwnedSlice(alloc);
    }
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
    if (needle.len == 0) {
        var out = try alloc.alloc(u8, replacement.len + haystack.len);
        @memcpy(out[0..replacement.len], replacement);
        @memcpy(out[replacement.len..], haystack);
        return out;
    }
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

/// Replace codepoint `match_cp` with `repl_cp` in `s`, returning a fresh
/// UTF-8 byte slice. When `first_only` is true only the first occurrence
/// is replaced (JVM `String.replace(char,char)` replaces all; Clojure
/// `replace-first` replaces one — both share this impl). Caller owns the
/// returned slice. Neutral impl per F-009: `clojure.string/replace`'s
/// char path AND `java.lang.String#replace(char,char)` both wrap it.
pub fn replaceCharAlloc(alloc: std.mem.Allocator, s: []const u8, match_cp: u21, repl_cp: u21, first_only: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var prev_i: usize = 0;
    var replaced_any = false;
    while (iter.nextCodepoint()) |cp| {
        const cp_bytes = s[prev_i..iter.i];
        if (cp == match_cp and !(first_only and replaced_any)) {
            var enc_buf: [4]u8 = undefined;
            const enc_len = try std.unicode.utf8Encode(repl_cp, &enc_buf);
            try out.appendSlice(alloc, enc_buf[0..enc_len]);
            replaced_any = true;
        } else {
            try out.appendSlice(alloc, cp_bytes);
        }
        prev_i = iter.i;
    }
    return try out.toOwnedSlice(alloc);
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

test "replaceAllStringAlloc inserts at every boundary when needle empty" {
    const out = try replaceAllStringAlloc(testing.allocator, "hi", "", "x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("xhxix", out);
}

test "replaceFirstStringAlloc inserts before input when needle empty" {
    const out = try replaceFirstStringAlloc(testing.allocator, "hi", "", "x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("xhi", out);
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

test "replaceCharAlloc replaces every occurrence (all)" {
    const out = try replaceCharAlloc(testing.allocator, "abcabc", 'b', 'B', false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aBcaBc", out);
}

test "replaceCharAlloc first_only replaces just the first" {
    const out = try replaceCharAlloc(testing.allocator, "abcabc", 'b', 'B', true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aBcabc", out);
}

test "replaceCharAlloc handles multibyte codepoints" {
    const out = try replaceCharAlloc(testing.allocator, "aあbあc", 0x3042, 'X', false); // あ → X
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aXbXc", out);
}

test "replaceCharAlloc no match returns a copy" {
    const out = try replaceCharAlloc(testing.allocator, "abc", 'z', 'Z', false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc", out);
}

test "classification is full-Unicode (JVM formulas over UCD tables)" {
    try testing.expect(isLetterCodepoint(0xE9)); // é
    try testing.expect(isLetterCodepoint(0x3042)); // あ
    try testing.expect(!isLetterCodepoint(0x2160)); // Ⅰ is Nl, not a letter
    try testing.expect(isDigitCodepoint(0x665)); // ٥
    try testing.expect(isUpperCodepoint(0x2160)); // Ⅰ — Other_Uppercase
    try testing.expect(isLowerCodepoint(0xAA)); // ª — Other_Lowercase
    try testing.expect(isTitleCaseCodepoint(0x1C5)); // ǅ
    try testing.expectEqual(@as(u21, 0x1C5), toTitleCodepoint(0x1C6)); // ǆ→ǅ
    try testing.expect(isSpaceCharCodepoint(0xA0)); // NBSP is Zs …
    try testing.expect(!isWhitespaceCodepoint(0xA0)); // … but not whitespace
    try testing.expect(isWhitespaceCodepoint(0x1C)); // file separator
    try testing.expect(isDefinedCodepoint('a'));
    try testing.expect(!isDefinedCodepoint(0x378));
    try testing.expect(isMirroredCodepoint('('));
    try testing.expect(!isMirroredCodepoint('a'));
    try testing.expect(isIdeographicCodepoint(0x4E00)); // 一
    try testing.expect(isAlphabeticCodepoint(0x2160)); // Nl counts
    try testing.expect(isJavaIdentifierStartCodepoint('$'));
    try testing.expect(!isJavaIdentifierStartCodepoint('1'));
    try testing.expect(isJavaIdentifierPartCodepoint('1'));
    try testing.expect(!isUnicodeIdentifierStartCodepoint('_'));
    try testing.expect(isUnicodeIdentifierPartCodepoint('_'));
    try testing.expect(isIdentifierIgnorableCodepoint(0xAD)); // soft hyphen (Cf)
    try testing.expect(!isIdentifierIgnorableCodepoint('\t'));
    try testing.expectEqual(@as(?u8, 5), digitValue(0x665, 10)); // ٥
    try testing.expectEqual(@as(?u8, 10), digitValue(0xFF41, 16)); // ａ
    try testing.expectEqual(@as(?u8, null), digitValue('z', 16));
    try testing.expectEqual(@as(i32, 7), numericValueOf(0x2166)); // Ⅶ
    try testing.expectEqual(@as(i32, -2), numericValueOf(0xBD)); // ½
    try testing.expectEqual(@as(i32, -1), numericValueOf('!'));
    try testing.expectEqual(@as(u5, 12), categoryOf(' ')); // Zs
    try testing.expectEqual(@as(i8, 1), directionalityOf(0x5D0)); // א → R
}
