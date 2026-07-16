// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Character` static methods + fields.
//!
//! Backend: impl-only
//! Impl deps: charset
//! Clojure peer: none
//!
//! Thin wrapper over the single-codepoint classification + case-folding
//! helpers in the neutral `runtime/charset.zig` leaf (F-009), which
//! evaluates the JVM classification formulas over the generated UCD
//! 16.0.0 tables (unicode_case.zig / unicode_category.zig) — full
//! Unicode, matching the JVM. Args follow the JVM overload pairs: the
//! classification / case methods take a `.char` OR an `.integer`
//! codepoint (the `int codePoint` overloads); the case folds echo the
//! arg type back (`(Character/toUpperCase \a)` → `\A`,
//! `(Character/toUpperCase 97)` → `65`). An out-of-range int codepoint
//! is NOT an error for the classification group (JVM returns the
//! "unassigned" answer: false / echo / 0 / -1). `Character/getName` +
//! `Character/codePointOf` ride the generated word-indexed name table
//! (`char_name.zig`, D-561 — pre-compressed, decoded once per process).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const string_collection = @import("../../collection/string.zig");
const char_name = @import("../../char_name.zig");
const java_array = @import("../../collection/java_array.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const charset = @import("../../charset.zig");

/// Extract the codepoint from a `.char` arg, else a type error.
fn argChar(v: Value, fn_name: []const u8, loc: SourceLocation) anyerror!u21 {
    if (v.tag() != .char)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "char", .actual = @tagName(v.tag()) });
    return v.asChar();
}

/// Codepoint from a `.char` OR an `.integer` arg — the JVM char/int
/// overload pairs. An integer outside 0..0x10FFFF returns null (the JVM
/// classification methods answer "unassigned" rather than throwing);
/// any other tag is a type error.
fn argCodepointLoose(v: Value, fn_name: []const u8, loc: SourceLocation) anyerror!?u21 {
    return switch (v.tag()) {
        .char => v.asChar(),
        .integer => blk: {
            const i = v.asInteger();
            if (i < 0 or i > 0x10FFFF) break :blk null;
            break :blk @intCast(i);
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "char or codepoint int", .actual = @tagName(v.tag()) }),
    };
}

/// `Character/isDigit` / `isLetter` / `isWhitespace` / …: classify a
/// char-or-int codepoint, return a bool (false for an out-of-range int —
/// JVM unassigned answer). JVM reference: java.lang.Character#is*.
fn Classify(comptime name: []const u8, comptime f: fn (u21) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const cp = (try argCodepointLoose(args[0], "Character/" ++ name, loc)) orelse return .false_val;
            return if (f(cp)) .true_val else .false_val;
        }
    };
}

/// `Character/toUpperCase` / `toLowerCase` / `toTitleCase`: fold a
/// codepoint's case, echoing the arg type (JVM overload pair: char in →
/// char out, int in → int out; an out-of-range int echoes unchanged).
/// JVM reference: java.lang.Character#to*Case.
fn CaseFold(comptime name: []const u8, comptime f: fn (u21) u21) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const v = args[0];
            const cp = (try argCodepointLoose(v, "Character/" ++ name, loc)) orelse return v;
            return if (v.tag() == .char)
                Value.initChar(f(cp))
            else
                Value.initInteger(@as(i64, f(cp)));
        }
    };
}

/// Implements `(Character/digit ch radix)`. Spec: the value of `ch` as a
/// digit in `radix` (any Unicode decimal digit, then a-z/A-Z incl. the
/// fullwidth forms = 10-35), or -1 if it is not such a digit or radix is
/// outside 2..36. JVM reference: java.lang.Character#digit.
/// cw v1 tier: A (§A26 clj differential sweep).
fn digit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/digit", args, 2, loc);
    const r = try error_catalog.expectInteger(args[1], "Character/digit", loc);
    const cp = (try argCodepointLoose(args[0], "Character/digit", loc)) orelse return Value.initInteger(-1);
    if (r < 2 or r > 36) return Value.initInteger(-1);
    const v = charset.digitValue(cp, @intCast(r)) orelse return Value.initInteger(-1);
    return Value.initInteger(@as(i64, v));
}

/// Implements `(Character/getNumericValue ch)`. Spec: the numeric value of
/// `ch` — decimal digits, letters a-z/A-Z (incl. fullwidth) = 10-35, other
/// numerics via UCD Numeric_Value (`\Ⅶ` → 7), -2 for fractional (`\½`),
/// -1 if none. JVM ref: Character#getNumericValue.
fn getNumericValue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/getNumericValue", args, 1, loc);
    const cp = (try argCodepointLoose(args[0], "Character/getNumericValue", loc)) orelse return Value.initInteger(-1);
    return Value.initInteger(@as(i64, charset.numericValueOf(cp)));
}

/// Implements `(Character/forDigit d radix)`. Spec: the char for digit value
/// `d` in `radix` (`0`-`9` then `a`-`z`), or `\0` when out of range. JVM
/// ref: Character#forDigit.
fn forDigit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/forDigit", args, 2, loc);
    const d = try error_catalog.expectInteger(args[0], "Character/forDigit", loc);
    const r = try error_catalog.expectInteger(args[1], "Character/forDigit", loc);
    if (d < 0 or d > 255 or r < 0 or r > 255) return Value.initChar(0);
    return Value.initChar(charset.forDigit(@intCast(d), @intCast(r)));
}

/// `(Character/codePointAt text index)` — the codepoint at `index`. cljw
/// chars ARE codepoints (no UTF-16 surrogates), so for a native string this
/// is the D-217 codepoint indexer; a CharSequence deftype (instaparse's
/// Segment) dispatches its `.charAt`. Index semantics are cljw's
/// codepoint-based indexing (the string_indexed divergence family).
fn codePointAt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("Character/codePointAt", args, 2, loc);
    const idx = try error_catalog.expectInteger(args[1], "Character/codePointAt", loc);
    const text = args[0];
    if (text.tag() == .string) {
        const sbytes = string_collection.asString(text);
        if (idx >= 0) {
            if (string_collection.codepointAt(sbytes, @intCast(idx))) |cp| {
                return Value.initInteger(@intCast(cp));
            }
        }
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "Character/codePointAt" });
    }
    // CharSequence deftype: dispatch its charAt; the char IS the codepoint.
    const td_of: ?*const type_descriptor.TypeDescriptor = switch (text.tag()) {
        .typed_instance => text.decodePtr(*const type_descriptor.TypedInstance).descriptor,
        .reified_instance => text.decodePtr(*const type_descriptor.ReifiedInstance).descriptor,
        else => null,
    };
    if (td_of) |t| {
        if (t.lookupMethod(null, "charAt")) |me| {
            const vt = rt.vtable orelse return error.NoVTable;
            const c = try vt.callFn(rt, env, me.method_val, &.{ text, args[1] }, loc);
            if (c.tag() == .char) return Value.initInteger(@intCast(c.asChar()));
            return c;
        }
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Character/codePointAt", .expected = "CharSequence", .actual = @tagName(text.tag()) });
}

/// `(Character/toChars cp)` — a char array for the codepoint. cljw chars are
/// codepoints, so this is always a 1-element array (the JVM's surrogate-pair
/// 2-element case cannot arise).
fn toChars(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Character/toChars", args, 1, loc);
    const cp = try error_catalog.expectInteger(args[0], "Character/toChars", loc);
    if (cp < 0 or cp > 0x10FFFF) {
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Character/toChars", .expected = "valid codepoint", .actual = "out-of-range int" });
    }
    return java_array.fromSlice(rt, &.{Value.initChar(@intCast(cp))});
}

/// Strict codepoint from a `.char` OR an in-range `.integer` — for the
/// members that DO throw on an invalid codepoint (toString(int), the
/// surrogate combiners).
fn argCodepoint(v: Value, fn_name: []const u8, loc: SourceLocation) anyerror!u21 {
    return (try argCodepointLoose(v, fn_name, loc)) orelse
        error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = fn_name });
}

/// `(Character/toString c)` — a one-char string. JVM Character.toString has
/// both the char and the int-codepoint overload (the latter throws on an
/// invalid codepoint).
fn toStringChar(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Character/toString", args, 1, loc);
    const cp = try argCodepoint(args[0], "Character/toString", loc);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "Character/toString" });
    return string_collection.alloc(rt, buf[0..n]);
}

// Surrogate / control range predicates over a UTF-16 code unit. cljw chars
// ARE codepoints, so a surrogate value (0xD800..0xDFFF) is held numerically
// even though it is not a standalone Unicode scalar — the range tests still
// hold. These functions take a char OR an int (argCodepoint).
fn isSurrogateCp(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDFFF;
}
fn isHighSurrogateCp(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDBFF;
}
fn isLowSurrogateCp(cp: u21) bool {
    return cp >= 0xDC00 and cp <= 0xDFFF;
}
fn isISOControlCp(cp: u21) bool {
    return cp <= 0x1F or (cp >= 0x7F and cp <= 0x9F);
}

/// `Character/isSurrogate` / `isHighSurrogate` / `isLowSurrogate` /
/// `isISOControl` — boolean range tests over a char-or-int codepoint
/// (an out-of-range int is false, matching the Classify group).
fn CpPred(comptime name: []const u8, comptime f: fn (u21) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const cp = (try argCodepointLoose(args[0], "Character/" ++ name, loc)) orelse return .false_val;
            return if (f(cp)) .true_val else .false_val;
        }
    };
}

// Codepoint validity predicates over a raw `int` (any value, so an
// out-of-codepoint-range int is simply `false` rather than a range error —
// `argCodepoint` would reject it). JVM reference: java.lang.Character.
fn isBmpCp(cp: i64) bool {
    return cp >= 0 and cp <= 0xFFFF;
}
fn isValidCp(cp: i64) bool {
    return cp >= 0 and cp <= 0x10FFFF;
}
fn isSupplementaryCp(cp: i64) bool {
    return cp >= 0x10000 and cp <= 0x10FFFF;
}

/// `Character/isBmpCodePoint` / `isValidCodePoint` / `isSupplementaryCodePoint`
/// — boolean tests over a raw `int` codepoint (no range error).
fn IntCpPred(comptime name: []const u8, comptime f: fn (i64) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const cp = try error_catalog.expectInteger(args[0], "Character/" ++ name, loc);
            return if (f(cp)) .true_val else .false_val;
        }
    };
}

/// `(Character/charCount cp)` — UTF-16 code units for `cp`: 2 for a
/// supplementary codepoint (≥ 0x10000), else 1. JVM ref: Character#charCount.
fn charCount(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/charCount", args, 1, loc);
    const cp = try error_catalog.expectInteger(args[0], "Character/charCount", loc);
    return Value.initInteger(if (cp >= 0x10000) 2 else 1);
}

/// `(Character/highSurrogate cp)` / `lowSurrogate cp` — the high / low UTF-16
/// surrogate char for a supplementary codepoint, via Java's bit formulas
/// (`(cp >>> 10) + 0xD7C0` and `(cp & 0x3FF) + 0xDC00`). JVM reference:
/// java.lang.Character#highSurrogate / #lowSurrogate.
fn highSurrogate(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/highSurrogate", args, 1, loc);
    const cp: u64 = @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Character/highSurrogate", loc)));
    return Value.initChar(@as(u16, @truncate((cp >> 10) + 0xD7C0)));
}
fn lowSurrogate(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/lowSurrogate", args, 1, loc);
    const cp: u64 = @bitCast(@as(i64, try error_catalog.expectInteger(args[0], "Character/lowSurrogate", loc)));
    return Value.initChar(@as(u16, @truncate((cp & 0x3FF) + 0xDC00)));
}

/// `(Character/toCodePoint high low)` — combine a high + low surrogate char
/// pair into the supplementary codepoint. JVM ref: Character#toCodePoint.
fn toCodePoint(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/toCodePoint", args, 2, loc);
    const high = try argCodepoint(args[0], "Character/toCodePoint", loc);
    const low = try argCodepoint(args[1], "Character/toCodePoint", loc);
    const cp: i64 = 0x10000 + (@as(i64, high) - 0xD800) * 1024 + (@as(i64, low) - 0xDC00);
    return Value.initInteger(cp);
}

/// `(Character/isSurrogatePair high low)` — `high` is a high surrogate AND
/// `low` is a low surrogate. JVM reference: Character#isSurrogatePair.
fn isSurrogatePair(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/isSurrogatePair", args, 2, loc);
    const high = try argCodepoint(args[0], "Character/isSurrogatePair", loc);
    const low = try argCodepoint(args[1], "Character/isSurrogatePair", loc);
    return if (isHighSurrogateCp(high) and isLowSurrogateCp(low)) .true_val else .false_val;
}

/// `(Character/hashCode c)` — Java returns the char's codepoint as an int.
/// JVM reference: java.lang.Character#hashCode.
fn hashCode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/hashCode", args, 1, loc);
    const cp = try argChar(args[0], "Character/hashCode", loc);
    return Value.initInteger(@as(i64, cp));
}

/// `(Character/valueOf c)` — the boxed char; cljw chars are already
/// values, so this is the identity. JVM ref: Character#valueOf.
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/valueOf", args, 1, loc);
    _ = try argChar(args[0], "Character/valueOf", loc);
    return args[0];
}

/// `(Character/compare x y)` — the numeric difference `x - y` (JVM exact
/// semantics, not a clamped sign). JVM ref: Character#compare.
fn compare(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/compare", args, 2, loc);
    const x = try argChar(args[0], "Character/compare", loc);
    const y = try argChar(args[1], "Character/compare", loc);
    return Value.initInteger(@as(i64, x) - @as(i64, y));
}

/// `(Character/isSpace c)` — the deprecated-but-callable legacy predicate:
/// exactly space / \t / \n / \f / \r (NOT vertical tab). JVM ref:
/// Character#isSpace.
fn isSpace(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/isSpace", args, 1, loc);
    const cp = try argChar(args[0], "Character/isSpace", loc);
    return switch (cp) {
        ' ', '\t', '\n', 0x0C, '\r' => .true_val,
        else => .false_val,
    };
}

/// `(Character/getType cp)` — the JVM General_Category byte value
/// (UPPERCASE_LETTER = 1 … FINAL_QUOTE_PUNCTUATION = 30; 0 = UNASSIGNED,
/// also the out-of-range-int answer). JVM ref: Character#getType.
fn getType(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/getType", args, 1, loc);
    const cp = (try argCodepointLoose(args[0], "Character/getType", loc)) orelse return Value.initInteger(0);
    return Value.initInteger(@as(i64, charset.categoryOf(cp)));
}

/// `(Character/getDirectionality cp)` — the JVM bidi directionality byte
/// (-1 = UNDEFINED, also the out-of-range-int answer). JVM ref:
/// Character#getDirectionality.
fn getDirectionality(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/getDirectionality", args, 1, loc);
    const cp = (try argCodepointLoose(args[0], "Character/getDirectionality", loc)) orelse return Value.initInteger(-1);
    return Value.initInteger(@as(i64, charset.directionalityOf(cp)));
}

/// `(Character/getName cp)` — the Unicode name of the codepoint (JVM
/// Character.getName; D-561): a stored UCD name, a control's pinned alias
/// ("NULL"/"BEL"), an assigned-but-unnamed "<BLOCK NAME> <HEX>", or nil
/// for an unassigned codepoint. Backed by the generated word-indexed
/// table (`char_name.zig`), decompressed once per process.
fn getName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Character/getName", args, 1, loc);
    const cp = try argCodepoint(args[0], "Character/getName", loc);
    const name = char_name.getName(rt.gpa, cp) catch
        return error_catalog.raiseInternal(loc, "Character/getName: name table unavailable");
    const n = name orelse return Value.nil_val;
    defer rt.gpa.free(n);
    return string_collection.alloc(rt, n);
}

/// `(Character/codePointOf name)` — the codepoint whose name matches
/// (trimmed, case-insensitive; the exact inverse of getName's output
/// forms — the UCD algorithmic spellings the JVM never emits are
/// rejected). An unrecognized name raises (JVM IllegalArgumentException).
fn codePointOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/codePointOf", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Character/codePointOf", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const cp = char_name.codePointOf(s) catch
        return error_catalog.raiseInternal(loc, "Character/codePointOf: name table unavailable");
    const found = cp orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Character/codePointOf", .expected = "a Unicode character name", .actual = "an unrecognized name" });
    return Value.initInteger(found);
}

/// `(Character/reverseBytes c)` — the char with its two UTF-16 bytes
/// swapped (`\a` → `\愀`). A supplementary cljw char (> 0xFFFF) has no
/// JVM char analogue, so it is a type error.
fn reverseBytes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/reverseBytes", args, 1, loc);
    const cp = try argChar(args[0], "Character/reverseBytes", loc);
    if (cp > 0xFFFF)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Character/reverseBytes", .expected = "BMP char", .actual = "supplementary char" });
    const u: u16 = @intCast(cp);
    return Value.initChar(@as(u21, (u << 8) | (u >> 8)));
}

/// `(Character/codePointBefore text index)` — the codepoint at
/// `index - 1`; errors when `index - 1` is out of range (JVM
/// StringIndexOutOfBounds). Index semantics are cljw's codepoint-based
/// indexing (the string_indexed divergence family), same as codePointAt.
fn codePointBefore(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("Character/codePointBefore", args, 2, loc);
    const idx = try error_catalog.expectInteger(args[1], "Character/codePointBefore", loc);
    if (idx < 1)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "Character/codePointBefore" });
    const prev = Value.initInteger(idx - 1);
    return codePointAt(rt, env, &.{ args[0], prev }, loc);
}

/// Codepoint count of a string arg (the CharSequence surface cljw carries
/// natively). A non-string arg is a type error.
fn argStringCount(v: Value, fn_name: []const u8, loc: SourceLocation) anyerror!i64 {
    if (v.tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "string", .actual = @tagName(v.tag()) });
    return @intCast(string_collection.codepointCount(string_collection.asString(v)));
}

/// `(Character/codePointCount text begin end)` — the codepoint count of
/// the index range. cljw strings are codepoint-indexed, so this is
/// `end - begin` after bounds validation (the string_indexed divergence
/// family — a JVM string with surrogate pairs counts UTF-16 units).
fn codePointCount(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/codePointCount", args, 3, loc);
    const begin = try error_catalog.expectInteger(args[1], "Character/codePointCount", loc);
    const end = try error_catalog.expectInteger(args[2], "Character/codePointCount", loc);
    const n = try argStringCount(args[0], "Character/codePointCount", loc);
    if (begin < 0 or end < begin or end > n)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "Character/codePointCount" });
    return Value.initInteger(end - begin);
}

/// `(Character/offsetByCodePoints text index offset)` — `index + offset`
/// after bounds validation (cljw codepoint indexing; string_indexed
/// divergence family). JVM ref: Character#offsetByCodePoints.
fn offsetByCodePoints(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/offsetByCodePoints", args, 3, loc);
    const idx = try error_catalog.expectInteger(args[1], "Character/offsetByCodePoints", loc);
    const offset = try error_catalog.expectInteger(args[2], "Character/offsetByCodePoints", loc);
    const n = try argStringCount(args[0], "Character/offsetByCodePoints", loc);
    const result = idx + offset;
    if (idx < 0 or idx > n or result < 0 or result > n)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "Character/offsetByCodePoints" });
    return Value.initInteger(result);
}

/// `(.charValue c)` — the receiver itself (cljw chars are unboxed values).
fn charValueMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".charValue", args, 1, loc);
    _ = try argChar(args[0], ".charValue", loc);
    return args[0];
}

/// `(.compareTo x y)` — the numeric difference, as `Character/compare`.
fn compareToMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".compareTo", args, 2, loc);
    const x = try argChar(args[0], ".compareTo", loc);
    const y = try argChar(args[1], ".compareTo", loc);
    return Value.initInteger(@as(i64, x) - @as(i64, y));
}

/// Instance methods on the native `.char` value (`(.charValue \a)`,
/// `(.compareTo \a \b)`) — the java.lang.Character instance surface.
/// `.toString` / `.equals` / `.hashCode` ride the universal Object path.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.char);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "charValue", &charValueMethod },
        .{ "compareTo", &compareToMethod },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

fn initCharacter(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "isDigit", &Classify("isDigit", charset.isDigitCodepoint).call },
        .{ "isLetter", &Classify("isLetter", charset.isLetterCodepoint).call },
        .{ "isLetterOrDigit", &Classify("isLetterOrDigit", charset.isLetterOrDigitCodepoint).call },
        .{ "isWhitespace", &Classify("isWhitespace", charset.isWhitespaceCodepoint).call },
        .{ "isUpperCase", &Classify("isUpperCase", charset.isUpperCodepoint).call },
        .{ "isLowerCase", &Classify("isLowerCase", charset.isLowerCodepoint).call },
        .{ "isTitleCase", &Classify("isTitleCase", charset.isTitleCaseCodepoint).call },
        .{ "isSpaceChar", &Classify("isSpaceChar", charset.isSpaceCharCodepoint).call },
        .{ "isDefined", &Classify("isDefined", charset.isDefinedCodepoint).call },
        .{ "isMirrored", &Classify("isMirrored", charset.isMirroredCodepoint).call },
        .{ "isIdeographic", &Classify("isIdeographic", charset.isIdeographicCodepoint).call },
        .{ "isAlphabetic", &Classify("isAlphabetic", charset.isAlphabeticCodepoint).call },
        .{ "isJavaIdentifierStart", &Classify("isJavaIdentifierStart", charset.isJavaIdentifierStartCodepoint).call },
        .{ "isJavaIdentifierPart", &Classify("isJavaIdentifierPart", charset.isJavaIdentifierPartCodepoint).call },
        .{ "isUnicodeIdentifierStart", &Classify("isUnicodeIdentifierStart", charset.isUnicodeIdentifierStartCodepoint).call },
        .{ "isUnicodeIdentifierPart", &Classify("isUnicodeIdentifierPart", charset.isUnicodeIdentifierPartCodepoint).call },
        .{ "isIdentifierIgnorable", &Classify("isIdentifierIgnorable", charset.isIdentifierIgnorableCodepoint).call },
        // Deprecated-but-callable aliases of the identifier predicates.
        .{ "isJavaLetter", &Classify("isJavaLetter", charset.isJavaIdentifierStartCodepoint).call },
        .{ "isJavaLetterOrDigit", &Classify("isJavaLetterOrDigit", charset.isJavaIdentifierPartCodepoint).call },
        // JDK 21 emoji property family (UCD emoji-data.txt).
        .{ "isEmoji", &Classify("isEmoji", charset.isEmojiCodepoint).call },
        .{ "isEmojiPresentation", &Classify("isEmojiPresentation", charset.isEmojiPresentationCodepoint).call },
        .{ "isEmojiModifier", &Classify("isEmojiModifier", charset.isEmojiModifierCodepoint).call },
        .{ "isEmojiModifierBase", &Classify("isEmojiModifierBase", charset.isEmojiModifierBaseCodepoint).call },
        .{ "isEmojiComponent", &Classify("isEmojiComponent", charset.isEmojiComponentCodepoint).call },
        .{ "isExtendedPictographic", &Classify("isExtendedPictographic", charset.isExtendedPictographicCodepoint).call },
        .{ "toUpperCase", &CaseFold("toUpperCase", charset.toUpperCodepoint).call },
        .{ "toLowerCase", &CaseFold("toLowerCase", charset.toLowerCodepoint).call },
        .{ "toTitleCase", &CaseFold("toTitleCase", charset.toTitleCodepoint).call },
        .{ "digit", &digit },
        .{ "getNumericValue", &getNumericValue },
        .{ "getType", &getType },
        .{ "getDirectionality", &getDirectionality },
        .{ "getName", &getName },
        .{ "codePointOf", &codePointOf },
        .{ "forDigit", &forDigit },
        .{ "codePointAt", &codePointAt },
        .{ "codePointBefore", &codePointBefore },
        .{ "codePointCount", &codePointCount },
        .{ "offsetByCodePoints", &offsetByCodePoints },
        .{ "toChars", &toChars },
        .{ "toString", &toStringChar },
        .{ "charCount", &charCount },
        .{ "isSurrogate", &CpPred("isSurrogate", isSurrogateCp).call },
        .{ "isHighSurrogate", &CpPred("isHighSurrogate", isHighSurrogateCp).call },
        .{ "isLowSurrogate", &CpPred("isLowSurrogate", isLowSurrogateCp).call },
        .{ "isISOControl", &CpPred("isISOControl", isISOControlCp).call },
        .{ "isBmpCodePoint", &IntCpPred("isBmpCodePoint", isBmpCp).call },
        .{ "isValidCodePoint", &IntCpPred("isValidCodePoint", isValidCp).call },
        .{ "isSupplementaryCodePoint", &IntCpPred("isSupplementaryCodePoint", isSupplementaryCp).call },
        .{ "highSurrogate", &highSurrogate },
        .{ "lowSurrogate", &lowSurrogate },
        .{ "toCodePoint", &toCodePoint },
        .{ "isSurrogatePair", &isSurrogatePair },
        .{ "hashCode", &hashCode },
        .{ "compare", &compare },
        .{ "valueOf", &valueOf },
        .{ "isSpace", &isSpace },
        .{ "reverseBytes", &reverseBytes },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Character",
    .descriptor = &descriptor,
    .init = &initCharacter,
};

// Static fields (ADR-0061) — comptime-const. `Character/TYPE` (the
// primitive Class object) is NOT carried: cljw has no primitive Class
// values (ADR-0059 no-JVM; arrays are type-erased per AD-019).
const character_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MIN_VALUE", .value = .{ .char = 0x0000 } },
    .{ .name = "MAX_VALUE", .value = .{ .char = 0xFFFF } },
    .{ .name = "MIN_RADIX", .value = .{ .int = 2 } },
    .{ .name = "MAX_RADIX", .value = .{ .int = 36 } },
    .{ .name = "SIZE", .value = .{ .int = 16 } },
    .{ .name = "BYTES", .value = .{ .int = 2 } },
    .{ .name = "MIN_CODE_POINT", .value = .{ .int = 0x0000 } },
    .{ .name = "MAX_CODE_POINT", .value = .{ .int = 0x10FFFF } },
    .{ .name = "MIN_SUPPLEMENTARY_CODE_POINT", .value = .{ .int = 0x10000 } },
    .{ .name = "MIN_HIGH_SURROGATE", .value = .{ .char = 0xD800 } },
    .{ .name = "MAX_HIGH_SURROGATE", .value = .{ .char = 0xDBFF } },
    .{ .name = "MIN_LOW_SURROGATE", .value = .{ .char = 0xDC00 } },
    .{ .name = "MAX_LOW_SURROGATE", .value = .{ .char = 0xDFFF } },
    .{ .name = "MIN_SURROGATE", .value = .{ .char = 0xD800 } },
    .{ .name = "MAX_SURROGATE", .value = .{ .char = 0xDFFF } },
    // General_Category constants (JVM getType byte values; 17 unused).
    .{ .name = "UNASSIGNED", .value = .{ .int = 0 } },
    .{ .name = "UPPERCASE_LETTER", .value = .{ .int = 1 } },
    .{ .name = "LOWERCASE_LETTER", .value = .{ .int = 2 } },
    .{ .name = "TITLECASE_LETTER", .value = .{ .int = 3 } },
    .{ .name = "MODIFIER_LETTER", .value = .{ .int = 4 } },
    .{ .name = "OTHER_LETTER", .value = .{ .int = 5 } },
    .{ .name = "NON_SPACING_MARK", .value = .{ .int = 6 } },
    .{ .name = "ENCLOSING_MARK", .value = .{ .int = 7 } },
    .{ .name = "COMBINING_SPACING_MARK", .value = .{ .int = 8 } },
    .{ .name = "DECIMAL_DIGIT_NUMBER", .value = .{ .int = 9 } },
    .{ .name = "LETTER_NUMBER", .value = .{ .int = 10 } },
    .{ .name = "OTHER_NUMBER", .value = .{ .int = 11 } },
    .{ .name = "SPACE_SEPARATOR", .value = .{ .int = 12 } },
    .{ .name = "LINE_SEPARATOR", .value = .{ .int = 13 } },
    .{ .name = "PARAGRAPH_SEPARATOR", .value = .{ .int = 14 } },
    .{ .name = "CONTROL", .value = .{ .int = 15 } },
    .{ .name = "FORMAT", .value = .{ .int = 16 } },
    .{ .name = "PRIVATE_USE", .value = .{ .int = 18 } },
    .{ .name = "SURROGATE", .value = .{ .int = 19 } },
    .{ .name = "DASH_PUNCTUATION", .value = .{ .int = 20 } },
    .{ .name = "START_PUNCTUATION", .value = .{ .int = 21 } },
    .{ .name = "END_PUNCTUATION", .value = .{ .int = 22 } },
    .{ .name = "CONNECTOR_PUNCTUATION", .value = .{ .int = 23 } },
    .{ .name = "OTHER_PUNCTUATION", .value = .{ .int = 24 } },
    .{ .name = "MATH_SYMBOL", .value = .{ .int = 25 } },
    .{ .name = "CURRENCY_SYMBOL", .value = .{ .int = 26 } },
    .{ .name = "MODIFIER_SYMBOL", .value = .{ .int = 27 } },
    .{ .name = "OTHER_SYMBOL", .value = .{ .int = 28 } },
    .{ .name = "INITIAL_QUOTE_PUNCTUATION", .value = .{ .int = 29 } },
    .{ .name = "FINAL_QUOTE_PUNCTUATION", .value = .{ .int = 30 } },
    // Bidi directionality constants (JVM getDirectionality byte values).
    .{ .name = "DIRECTIONALITY_UNDEFINED", .value = .{ .int = -1 } },
    .{ .name = "DIRECTIONALITY_LEFT_TO_RIGHT", .value = .{ .int = 0 } },
    .{ .name = "DIRECTIONALITY_RIGHT_TO_LEFT", .value = .{ .int = 1 } },
    .{ .name = "DIRECTIONALITY_RIGHT_TO_LEFT_ARABIC", .value = .{ .int = 2 } },
    .{ .name = "DIRECTIONALITY_EUROPEAN_NUMBER", .value = .{ .int = 3 } },
    .{ .name = "DIRECTIONALITY_EUROPEAN_NUMBER_SEPARATOR", .value = .{ .int = 4 } },
    .{ .name = "DIRECTIONALITY_EUROPEAN_NUMBER_TERMINATOR", .value = .{ .int = 5 } },
    .{ .name = "DIRECTIONALITY_ARABIC_NUMBER", .value = .{ .int = 6 } },
    .{ .name = "DIRECTIONALITY_COMMON_NUMBER_SEPARATOR", .value = .{ .int = 7 } },
    .{ .name = "DIRECTIONALITY_NONSPACING_MARK", .value = .{ .int = 8 } },
    .{ .name = "DIRECTIONALITY_BOUNDARY_NEUTRAL", .value = .{ .int = 9 } },
    .{ .name = "DIRECTIONALITY_PARAGRAPH_SEPARATOR", .value = .{ .int = 10 } },
    .{ .name = "DIRECTIONALITY_SEGMENT_SEPARATOR", .value = .{ .int = 11 } },
    .{ .name = "DIRECTIONALITY_WHITESPACE", .value = .{ .int = 12 } },
    .{ .name = "DIRECTIONALITY_OTHER_NEUTRALS", .value = .{ .int = 13 } },
    .{ .name = "DIRECTIONALITY_LEFT_TO_RIGHT_EMBEDDING", .value = .{ .int = 14 } },
    .{ .name = "DIRECTIONALITY_LEFT_TO_RIGHT_OVERRIDE", .value = .{ .int = 15 } },
    .{ .name = "DIRECTIONALITY_RIGHT_TO_LEFT_EMBEDDING", .value = .{ .int = 16 } },
    .{ .name = "DIRECTIONALITY_RIGHT_TO_LEFT_OVERRIDE", .value = .{ .int = 17 } },
    .{ .name = "DIRECTIONALITY_POP_DIRECTIONAL_FORMAT", .value = .{ .int = 18 } },
    .{ .name = "DIRECTIONALITY_LEFT_TO_RIGHT_ISOLATE", .value = .{ .int = 19 } },
    .{ .name = "DIRECTIONALITY_RIGHT_TO_LEFT_ISOLATE", .value = .{ .int = 20 } },
    .{ .name = "DIRECTIONALITY_FIRST_STRONG_ISOLATE", .value = .{ .int = 21 } },
    .{ .name = "DIRECTIONALITY_POP_DIRECTIONAL_ISOLATE", .value = .{ .int = 22 } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Character",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &character_static_fields,
    .parent = null,
    .meta = .nil_val,
};
