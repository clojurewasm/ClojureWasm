// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.String` instance methods.
//!
//! Backend: impl-only
//! Impl deps: charset
//! Clojure peer: clojure.string/upper-case
//!
//! Thin wrapper over `runtime/charset.zig` per F-009. Unlike the
//! `___HOST_EXTENSION` static-descriptor surfaces (System / UUID / …),
//! String exposes **instance** methods reached as `(.toUpperCase s)`.
//! Instance dispatch on a native receiver resolves via
//! `rt.nativeDescriptor(.string)` — a per-Runtime descriptor distinct
//! from the static `rt.types` entries `installAll` registers — so these
//! methods are installed by `installNativeMethods(rt)` at runtime init
//! (ADR-0050 am1 caveat 3), not by the `___HOST_EXTENSION` aggregator.

const std = @import("std");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const charset = @import("../../charset.zig");
const string_collection = @import("../../collection/string.zig");
const regex_compile = @import("../../regex/compile.zig");
const regex_match = @import("../../regex/match.zig");
const regex_replace = @import("../../regex/replace.zig");
const vector_collection = @import("../../collection/vector.zig");
const java_array = @import("../../collection/java_array.zig");

/// Implements `(.toUpperCase s)`.
/// Spec: returns a copy of the string with all codepoints upper-cased.
/// JVM reference: java.lang.String#toUpperCase.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn toUpperCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // 1-arg (receiver) or 2-arg with a java.util.Locale (`(.toUpperCase s
    // Locale/US)`, honeysql). cljw casing is locale-independent, so the Locale
    // arg is accepted + ignored (US/ROOT map to the same impl — F-011-faithful).
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".toUpperCase", .got = args.len, .min = 1, .max = 2 });
    const up = try charset.upperCaseAlloc(rt.gpa, string_collection.asString(args[0]));
    defer rt.gpa.free(up);
    return string_collection.alloc(rt, up);
}

/// Implements `(.toLowerCase s)`.
/// Spec: returns a copy of the string with all codepoints lower-cased.
/// JVM reference: java.lang.String#toLowerCase.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn toLowerCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // 1-arg or 2-arg with a Locale (ignored; cljw casing is locale-independent).
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".toLowerCase", .got = args.len, .min = 1, .max = 2 });
    const down = try charset.lowerCaseAlloc(rt.gpa, string_collection.asString(args[0]));
    defer rt.gpa.free(down);
    return string_collection.alloc(rt, down);
}

/// Implements `(.trim s)`.
/// Spec: returns a copy with leading/trailing ASCII whitespace removed.
/// JVM reference: java.lang.String#trim.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn trim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".trim", args, 1, loc);
    return string_collection.alloc(rt, charset.trim(string_collection.asString(args[0])));
}

/// Implements `(.length s)` → codepoint count (ADR-0014: cw v1 strings
/// count codepoints, not UTF-16 units). JVM reference: java.lang.String#length.
/// cw v1 tier: A.
fn length(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".length", args, 1, loc);
    const n = charset.codepointCount(string_collection.asString(args[0])) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".length on invalid UTF-8" });
    return Value.initInteger(@intCast(n));
}

/// Implements `(.substring s start)` / `(.substring s start end)` over
/// codepoint indices. JVM reference: java.lang.String#substring.
/// cw v1 tier: A.
fn substring(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".substring", .got = args.len, .min = 2, .max = 3 });
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".substring", .actual = @tagName(args[1].tag()) });
    const s = string_collection.asString(args[0]);
    // Codepoint-based indices, bounds-checked against the count (JVM throws
    // StringIndexOutOfBounds rather than clamping — `(.substring "hello" 1 10)`
    // is an error, not "ello"). Mirrors clojure.core/subs (D-164-adjacent).
    const len = charset.codepointCount(s) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".substring on invalid UTF-8" });
    const start_i = args[1].asInteger();
    if (start_i < 0 or @as(u64, @intCast(@max(start_i, 0))) > len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".substring" });
    const start: usize = @intCast(start_i);
    var end: usize = len;
    if (args.len == 3) {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".substring", .actual = @tagName(args[2].tag()) });
        const end_i = args[2].asInteger();
        if (end_i < start_i or @as(u64, @intCast(@max(end_i, 0))) > len)
            return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".substring" });
        end = @intCast(end_i);
    }
    const slice = charset.substring(s, start, end) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".substring index out of range" });
    return string_collection.alloc(rt, slice);
}

/// Resolve a `needle` arg to its UTF-8 bytes for both JVM overload families:
/// `(String)` (substring) and `(int codepoint)`. An out-of-range codepoint
/// yields `null` (treated as "not found" by the callers, matching the JVM
/// where an invalid char simply never matches). `buf` backs an int needle's
/// encoded bytes, so it must outlive the returned slice.
fn needleBytes(arg: Value, buf: *[4]u8, loc: SourceLocation, fn_name: []const u8) anyerror!?[]const u8 {
    if (arg.tag() == .integer) {
        const cp = arg.asInteger();
        if (cp < 0 or cp > 0x10FFFF) return null;
        const n = std.unicode.utf8Encode(@intCast(cp), buf) catch return null;
        return buf[0..n];
    }
    if (arg.tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(arg.tag()) });
    return string_collection.asString(arg);
}

/// `(.indexOf s needle)` / `(.indexOf s needle fromIndex)` → codepoint index
/// of the first occurrence of `needle` at or after `fromIndex` (default 0),
/// or -1 when absent. `needle` is a substring (String) or a codepoint (int);
/// `fromIndex` is clamped to `[0, len]` (a negative value behaves as 0, per
/// the JVM). JVM reference: java.lang.String#indexOf. cw v1 tier: A.
fn indexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".indexOf", .got = args.len, .min = 2, .max = 3 });
    const hay = string_collection.asString(args[0]);
    var buf: [4]u8 = undefined;
    const needle = (try needleBytes(args[1], &buf, loc, ".indexOf")) orelse return Value.initInteger(-1);
    if (args.len == 2) {
        const idx = charset.codepointIndexOf(hay, needle) orelse return Value.initInteger(-1);
        return Value.initInteger(@intCast(idx));
    }
    if (args[2].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".indexOf", .actual = @tagName(args[2].tag()) });
    const len = charset.codepointCount(hay) catch return Value.initInteger(-1);
    const from = args[2].asInteger();
    const start: usize = if (from < 0) 0 else @min(@as(usize, @intCast(from)), len);
    const sub = charset.substring(hay, start, len) catch return Value.initInteger(-1);
    const idx = charset.codepointIndexOf(sub, needle) orelse return Value.initInteger(-1);
    return Value.initInteger(@intCast(start + idx));
}

/// `(.lastIndexOf s needle)` / `(.lastIndexOf s needle fromIndex)` → codepoint
/// index of the LAST occurrence of `needle` at or before `fromIndex` (default:
/// search the whole string), or -1. `needle` is a substring (String) or a
/// codepoint (int). A negative `fromIndex` yields -1 (JVM). JVM reference:
/// java.lang.String#lastIndexOf.
fn lastIndexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".lastIndexOf", .got = args.len, .min = 2, .max = 3 });
    const hay = string_collection.asString(args[0]);
    var buf: [4]u8 = undefined;
    const needle = (try needleBytes(args[1], &buf, loc, ".lastIndexOf")) orelse return Value.initInteger(-1);
    if (args.len == 2) {
        const idx = charset.codepointLastIndexOf(hay, needle) orelse return Value.initInteger(-1);
        return Value.initInteger(@intCast(idx));
    }
    if (args[2].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".lastIndexOf", .actual = @tagName(args[2].tag()) });
    const from = args[2].asInteger();
    if (from < 0) return Value.initInteger(-1);
    const len = charset.codepointCount(hay) catch return Value.initInteger(-1);
    // A match starting at k ≤ fromIndex occupies [k, k+needleLen); bound the
    // search region's end at fromIndex + needleLen so the last match within it
    // is guaranteed to start at or before fromIndex.
    const needle_cp = charset.codepointCount(needle) catch return Value.initInteger(-1);
    const end: usize = @min(@as(usize, @intCast(from)) + needle_cp, len);
    const sub = charset.substring(hay, 0, end) catch return Value.initInteger(-1);
    const idx = charset.codepointLastIndexOf(sub, needle) orelse return Value.initInteger(-1);
    return Value.initInteger(@intCast(idx));
}

/// `(.isBlank s)` → true iff `s` is empty or all whitespace. JVM ref:
/// java.lang.String#isBlank (ASCII whitespace; D-057 Unicode caveat).
fn isBlank(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isBlank", args, 1, loc);
    var iter = std.unicode.Utf8Iterator{ .bytes = string_collection.asString(args[0]), .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (!charset.isWhitespaceCodepoint(cp)) return Value.false_val;
    }
    return Value.true_val;
}

/// `(.strip s)` → leading + trailing whitespace removed. JVM ref:
/// java.lang.String#strip (≈ `.trim` for ASCII; D-057 Unicode caveat).
fn strip(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".strip", args, 1, loc);
    return string_collection.alloc(rt, charset.trim(string_collection.asString(args[0])));
}

/// `(.stripLeading s)` → leading whitespace removed (trailing kept). Sibling
/// of `.strip`; ships with it per per-class completeness (F-014). JVM ref:
/// java.lang.String#stripLeading (ASCII whitespace; D-057 Unicode caveat).
fn stripLeading(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".stripLeading", args, 1, loc);
    return string_collection.alloc(rt, charset.trimLeft(string_collection.asString(args[0])));
}

/// `(.stripTrailing s)` → trailing whitespace removed (leading kept). Sibling
/// of `.strip`. JVM ref: java.lang.String#stripTrailing (D-057 Unicode caveat).
fn stripTrailing(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".stripTrailing", args, 1, loc);
    return string_collection.alloc(rt, charset.trimRight(string_collection.asString(args[0])));
}

/// `(.equalsIgnoreCase a b)` → ASCII case-insensitive equality. JVM ref:
/// java.lang.String#equalsIgnoreCase (D-057 Unicode caveat).
fn equalsIgnoreCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".equalsIgnoreCase", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".equalsIgnoreCase", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(std.ascii.eqlIgnoreCase(string_collection.asString(args[0]), string_collection.asString(args[1])));
}

/// `(.codePointAt s i)` → the codepoint (int) at codepoint index `i`. JVM
/// ref: java.lang.String#codePointAt (cw v1 indexes by codepoint, ADR-0014).
fn codePointAt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".codePointAt", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".codePointAt", .actual = @tagName(args[1].tag()) });
    const i = args[1].asInteger();
    if (i < 0) return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".codePointAt" });
    const cp = charset.codepointAt(string_collection.asString(args[0]), @intCast(i)) catch
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".codePointAt" });
    return Value.initInteger(@intCast(cp));
}

/// `(.compareTo a b)` → JVM lexicographic compare: at the first differing
/// codepoint, `cp_a - cp_b`; else `len_a - len_b` (codepoint counts). NOT
/// normalised to -1/0/1 (matches Java `String.compareTo` magnitude).
fn compareTo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".compareTo", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".compareTo", .actual = @tagName(args[1].tag()) });
    const sa = string_collection.asString(args[0]);
    const sb = string_collection.asString(args[1]);
    var ia = std.unicode.Utf8Iterator{ .bytes = sa, .i = 0 };
    var ib = std.unicode.Utf8Iterator{ .bytes = sb, .i = 0 };
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return Value.initInteger(0);
        if (ca == null or cb == null) {
            const na: i64 = @intCast(charset.codepointCount(sa) catch sa.len);
            const nb: i64 = @intCast(charset.codepointCount(sb) catch sb.len);
            return Value.initInteger(na - nb);
        }
        if (ca.? != cb.?) return Value.initInteger(@as(i64, ca.?) - @as(i64, cb.?));
    }
}

/// `(.compareToIgnoreCase a b)` → like `.compareTo` but ASCII case-folded at
/// each codepoint. Sibling of `.compareTo`; ships with it (F-014). JVM ref:
/// java.lang.String#compareToIgnoreCase (D-057 Unicode caveat).
fn compareToIgnoreCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".compareToIgnoreCase", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".compareToIgnoreCase", .actual = @tagName(args[1].tag()) });
    const sa = string_collection.asString(args[0]);
    const sb = string_collection.asString(args[1]);
    var ia = std.unicode.Utf8Iterator{ .bytes = sa, .i = 0 };
    var ib = std.unicode.Utf8Iterator{ .bytes = sb, .i = 0 };
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return Value.initInteger(0);
        if (ca == null or cb == null) {
            const na: i64 = @intCast(charset.codepointCount(sa) catch sa.len);
            const nb: i64 = @intCast(charset.codepointCount(sb) catch sb.len);
            return Value.initInteger(na - nb);
        }
        const fa = foldAscii(ca.?);
        const fb = foldAscii(cb.?);
        if (fa != fb) return Value.initInteger(@as(i64, fa) - @as(i64, fb));
    }
}

/// ASCII lower-case fold of a codepoint (non-ASCII passes through), for
/// case-insensitive compare. Mirrors `std.ascii.toLower` at codepoint width.
fn foldAscii(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

/// Implements `(.charAt s i)` → the char at codepoint index `i`
/// (ADR-0014: cw v1 strings index by codepoint, not UTF-16 unit). JVM
/// reference: java.lang.String#charAt (IndexOutOfBoundsException when out
/// of range). cw v1 tier: A.
fn charAt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".charAt", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".charAt", .actual = @tagName(args[1].tag()) });
    const s = string_collection.asString(args[0]);
    const idx = args[1].asInteger();
    if (idx < 0)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".charAt" });
    const cp = charset.codepointAt(s, @intCast(idx)) catch
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".charAt" });
    return Value.initChar(cp);
}

/// Implements `(.contains s needle)` → whether `needle` occurs in `s`.
/// JVM reference: java.lang.String#contains (CharSequence). cw v1 tier: A.
fn contains(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".contains", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".contains", .actual = @tagName(args[1].tag()) });
    const found = std.mem.find(u8, string_collection.asString(args[0]), string_collection.asString(args[1])) != null;
    return Value.initBoolean(found);
}

/// Implements `(.startsWith s prefix)`. A UTF-8 byte-prefix test is
/// codepoint-correct (a valid UTF-8 string cannot start mid-codepoint).
/// JVM reference: java.lang.String#startsWith. cw v1 tier: A.
fn startsWith(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".startsWith", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".startsWith", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(std.mem.startsWith(u8, string_collection.asString(args[0]), string_collection.asString(args[1])));
}

/// Implements `(.endsWith s suffix)`. Byte-suffix test is codepoint-correct
/// for the same reason as `startsWith`. JVM reference:
/// java.lang.String#endsWith. cw v1 tier: A.
fn endsWith(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".endsWith", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".endsWith", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(std.mem.endsWith(u8, string_collection.asString(args[0]), string_collection.asString(args[1])));
}

/// Implements `(.isEmpty s)` → whether `s` has length zero. JVM reference:
/// java.lang.String#isEmpty. cw v1 tier: A.
fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    return Value.initBoolean(string_collection.asString(args[0]).len == 0);
}

/// Implements `(.concat s t)` → `s` followed by `t`. JVM reference:
/// java.lang.String#concat. cw v1 tier: A.
fn concat(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".concat", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".concat", .actual = @tagName(args[1].tag()) });
    const a = string_collection.asString(args[0]);
    const b = string_collection.asString(args[1]);
    const buf = try rt.gpa.alloc(u8, a.len + b.len);
    defer rt.gpa.free(buf);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return string_collection.alloc(rt, buf);
}

/// Implements `(.repeat s n)` → `s` concatenated `n` times. A negative
/// count is an error (JVM throws IllegalArgumentException). JVM reference:
/// java.lang.String#repeat. cw v1 tier: A.
fn repeat(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".repeat", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".repeat", .actual = @tagName(args[1].tag()) });
    const n = args[1].asInteger();
    if (n < 0)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = ".repeat" });
    const s = string_collection.asString(args[0]);
    const count: usize = @intCast(n);
    const buf = try rt.gpa.alloc(u8, s.len * count);
    defer rt.gpa.free(buf);
    var i: usize = 0;
    while (i < count) : (i += 1) @memcpy(buf[i * s.len ..][0..s.len], s);
    return string_collection.alloc(rt, buf);
}

/// Implements `(.replace s match repl)` for both overloads JVM exposes:
/// `replace(char,char)` (replace every char) and
/// `replace(CharSequence,CharSequence)` (replace every substring). The
/// receiver is `s`; `match`/`repl` are both chars OR both strings — a
/// mixed pair is a type error. JVM reference: java.lang.String#replace.
/// cw v1 tier: A. Shares `charset.replaceCharAlloc` /
/// `replaceAllStringAlloc` with `clojure.string/replace` (F-009/F-011).
fn replace(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".replace", args, 3, loc);
    const out: []u8 = if (args[1].tag() == .char and args[2].tag() == .char)
        try charset.replaceCharAlloc(rt.gpa, string_collection.asString(args[0]), args[1].asChar(), args[2].asChar(), false)
    else if (args[1].tag() == .string and args[2].tag() == .string)
        try charset.replaceAllStringAlloc(rt.gpa, string_collection.asString(args[0]), string_collection.asString(args[1]), string_collection.asString(args[2]))
    else
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".replace", .actual = @tagName(args[1].tag()) });
    defer rt.gpa.free(out);
    return string_collection.alloc(rt, out);
}

/// `(.matches s regex)` → whether `s` matches the regex PATTERN STRING in
/// FULL (anchored both ends, like Java `String.matches`). The pattern is
/// compiled on the spot; a malformed pattern raises. Has no layering issue
/// (compile + matchFull are runtime/regex/ leaves) — the regex-REPLACE
/// String methods are D-206 (their impl lives in Layer-2 lang/). JVM ref:
/// java.lang.String#matches.
fn matches(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".matches", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".matches", .actual = @tagName(args[1].tag()) });
    var program = regex_compile.compile(rt.gpa, string_collection.asString(args[1]), .{}) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".matches (invalid regex pattern)" });
    defer program.deinit(rt.gpa);
    const m = regex_match.matchFull(rt.gpa, &program, string_collection.asString(args[0])) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".matches" });
    return Value.initBoolean(m != null);
}

/// `(.replaceAll s regex repl)` / `(.replaceFirst s regex repl)` — replace
/// regex matches with the template `repl` (`$N` backref / `\c` escape, JVM
/// `Matcher` semantics). The pattern is compiled on the spot. Shares the
/// `runtime/regex/replace.zig` impl with `clojure.string/replace` (F-009).
/// JVM ref: java.lang.String#replaceAll / #replaceFirst.
fn replaceRegex(rt: *Runtime, fn_name: []const u8, kind: regex_replace.ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[2].tag()) });
    var program = regex_compile.compile(rt.gpa, string_collection.asString(args[1]), .{}) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "regex-replace (invalid regex pattern)" });
    defer program.deinit(rt.gpa);
    return regex_replace.replaceString(rt, &program, string_collection.asString(args[0]), string_collection.asString(args[2]), kind);
}

fn replaceAll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceRegex(rt, ".replaceAll", .all, args, loc);
}

fn replaceFirst(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceRegex(rt, ".replaceFirst", .first, args, loc);
}

/// `(.split s regex)` / `(.split s regex limit)` — split on regex matches.
/// JVM returns a `String[]`; cw v1 returns a VECTOR (no usable Java-array
/// value type — `(seq …)` / `(vec …)` / `count` / `first` all work; `class`
/// / `aget` diverge, a recorded no-JVM-Class surface divergence). Shares the
/// split impl with `clojure.string/split` (F-009). JVM ref:
/// java.lang.String#split.
fn split(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".split", .got = args.len, .min = 2, .max = 3 });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".split", .actual = @tagName(args[1].tag()) });
    const limit: i64 = if (args.len == 3) try error_catalog.expectInteger(args[2], ".split", loc) else 0;
    var program = regex_compile.compile(rt.gpa, string_collection.asString(args[1]), .{}) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".split (invalid regex pattern)" });
    defer program.deinit(rt.gpa);
    return regex_replace.splitToVector(rt, &program, string_collection.asString(args[0]), limit);
}

/// `(.toCharArray s)` — JVM returns a `char[]`; cw v1 returns a VECTOR of
/// chars (same no-array rationale as `.split`). `(seq …)` / `(vec …)` /
/// `count` / `first` all work. JVM ref: java.lang.String#toCharArray.
fn toCharArray(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".toCharArray", args, 1, loc);
    var iter = std.unicode.Utf8Iterator{ .bytes = string_collection.asString(args[0]), .i = 0 };
    var result = vector_collection.empty();
    while (iter.nextCodepoint()) |cp| {
        result = try vector_collection.conj(rt, result, Value.initChar(cp));
    }
    return result;
}

/// Implements `(.getBytes s)` / `(.getBytes s charset)` — the UTF-8 bytes of `s`
/// as a byte array (cljw `.array` of SIGNED-byte ints, matching clj's `byte[]`:
/// a byte > 127 is negative, e.g. "é" → (-61 -87)). cljw is UTF-8-only, so a
/// charset arg (a name String — or any object) is accepted and the encoding is
/// always UTF-8 (documented limitation; the common `(.getBytes s "UTF-8")` works).
fn getBytes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".getBytes", .got = args.len, .min = 1, .max = 2 });
    const s = string_collection.asString(args[0]);
    const buf = try rt.gpa.alloc(Value, s.len);
    defer rt.gpa.free(buf);
    for (s, 0..) |b, i| buf[i] = Value.initInteger(@as(i8, @bitCast(b))); // signed byte (clj byte[])
    return java_array.fromSlice(rt, buf);
}

/// `(.intern s)` → the canonical interned instance. cw v1 has no string pool
/// and strings compare by value, so the receiver is already canonical: return
/// it unchanged. JVM ref: java.lang.String#intern.
fn intern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".intern", args, 1, loc);
    return args[0];
}

/// Populate the per-Runtime native `.string` descriptor's `method_table`
/// with String instance methods. Driven from `lang/primitive.zig` at
/// runtime init (Layer 2 — Layer 0 `runtime/` may not import this
/// surface per zone rules). Idempotent: a non-empty table short-circuits.
///
/// Allocations land on `rt.gc.infra` (the same allocator
/// `Runtime.deinit`'s native-descriptor pass frees), so the method-name
/// dups + the slice are released without a separate owner.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.string);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "toUpperCase", &toUpperCase }, .{ "toLowerCase", &toLowerCase },
        .{ "trim", &trim },               .{ "length", &length },
        .{ "substring", &substring },     .{ "indexOf", &indexOf },
        .{ "charAt", &charAt },           .{ "contains", &contains },
        .{ "startsWith", &startsWith },   .{ "endsWith", &endsWith },
        .{ "isEmpty", &isEmpty },         .{ "concat", &concat },
        .{ "repeat", &repeat },           .{ "replace", &replace },
        .{ "lastIndexOf", &lastIndexOf }, .{ "isBlank", &isBlank },
        .{ "strip", &strip },             .{ "equalsIgnoreCase", &equalsIgnoreCase },
        .{ "stripLeading", &stripLeading }, .{ "stripTrailing", &stripTrailing },
        .{ "codePointAt", &codePointAt }, .{ "compareTo", &compareTo },
        .{ "compareToIgnoreCase", &compareToIgnoreCase }, .{ "intern", &intern },
        .{ "matches", &matches },         .{ "replaceAll", &replaceAll },
        .{ "replaceFirst", &replaceFirst }, .{ "split", &split },
        .{ "toCharArray", &toCharArray },   .{ "getBytes", &getBytes },
        // CharSequence.subSequence(start, end) ≡ substring(start, end) (D-429).
        .{ "subSequence", &substring },
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

// --- static surface (java.lang.String/valueOf etc.) ---
//
// Distinct from the native-instance methods installed above: static `String/…`
// calls resolve a `cljw.java.lang.String` descriptor in `rt.types` (the always-on
// `cljw.java.lang.*` auto-import), like Math/System. hiccup's compiler emits
// `(String/valueOf x)`.

const host_api = @import("../_host_api.zig");
const print_mod = @import("../../print.zig");

/// `(String/valueOf x)` — Java `String.valueOf(Object)`: the str-rendering of
/// `x`, with `nil` → `"null"` (JVM valueOf(null) is the literal "null").
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("String/valueOf", args, 1, loc);
    if (args[0].tag() == .nil) return string_collection.alloc(rt, "null");
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try print_mod.writeStrValue(rt, env, &aw.writer, args[0]);
    return string_collection.alloc(rt, aw.writer.buffered());
}

/// `(String.)` → "". `(String. s)` → a copy of the string `s`. `(String. bytes
/// [charset])` → the UTF-8 string of a cljw byte array (the `.getBytes` inverse;
/// each element's low 8 bits form a byte, so a signed -61 and unsigned 195 both
/// give 0xC3). cljw is UTF-8-only (charset arg accepted, UTF-8 used). `(String.
/// char-array)` → the chars' codepoints UTF-8-encoded (the first element's tag
/// selects the char vs byte path).
fn stringCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 0) return string_collection.alloc(rt, "");
    if (args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "java.lang.String.", .got = args.len, .min = 0, .max = 2 });
    const a = args[0];
    if (a.tag() == .string) return string_collection.alloc(rt, string_collection.asString(a)); // copy
    if (java_array.isArray(a)) {
        const arr = java_array.asArray(a);
        // A CHAR array → the chars' codepoints, UTF-8 encoded (clj `(String.
        // char[])`); a BYTE/INT array → each element's low 8 bits as a byte (the
        // `.getBytes` inverse). The first element selects the path.
        if (arr.len > 0 and arr.items()[0].tag() == .char) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(rt.gpa);
            for (arr.items()) |v| {
                if (v.tag() != .char)
                    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.String.", .expected = "char array", .actual = @tagName(v.tag()) });
                var cbuf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(v.asChar(), &cbuf) catch
                    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.String.", .expected = "valid char", .actual = "unencodable codepoint" });
                try buf.appendSlice(rt.gpa, cbuf[0..n]);
            }
            return string_collection.alloc(rt, buf.items);
        }
        const buf = try rt.gpa.alloc(u8, arr.len);
        defer rt.gpa.free(buf);
        for (arr.items(), 0..) |v, i| {
            if (v.tag() != .integer)
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.String.", .expected = "byte array", .actual = @tagName(v.tag()) });
            buf[i] = @intCast(v.asInteger() & 0xFF); // low 8 bits → byte (signed or unsigned in)
        }
        return string_collection.alloc(rt, buf);
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.lang.String.", .expected = "string or byte array", .actual = @tagName(a.tag()) });
}

fn initStringStatics(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 2);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "valueOf"), .method_val = Value.initBuiltinFn(&valueOf) };
    entries[1] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "<init>"), .method_val = Value.initBuiltinFn(&stringCtor) };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.String",
    .descriptor = &static_descriptor,
    .init = &initStringStatics,
};

var static_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.String",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

// --- tests ---

const testing = std.testing;

test "installNativeMethods populates the native .string descriptor" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    try installNativeMethods(&rt);
    const td = try rt.nativeDescriptor(.string);
    try testing.expect(td.lookupMethod(null, "toUpperCase") != null);
    try testing.expect(td.lookupMethod(null, "toLowerCase") != null);
    try testing.expect(td.lookupMethod(null, "trim") != null);
    try testing.expect(td.lookupMethod(null, "length") != null);
    try testing.expect(td.lookupMethod(null, "substring") != null);
    try testing.expect(td.lookupMethod(null, "subSequence") != null); // D-429 (≡ substring)
    try testing.expect(td.lookupMethod(null, "indexOf") != null);
    try testing.expect(td.lookupMethod(null, "charAt") != null);
    try testing.expect(td.lookupMethod(null, "contains") != null);
    try testing.expect(td.lookupMethod(null, "startsWith") != null);
    try testing.expect(td.lookupMethod(null, "endsWith") != null);
    try testing.expect(td.lookupMethod(null, "isEmpty") != null);
    try testing.expect(td.lookupMethod(null, "concat") != null);
    try testing.expect(td.lookupMethod(null, "repeat") != null);
    try testing.expect(td.lookupMethod(null, "replace") != null);
    try testing.expect(td.lookupMethod(null, "stripLeading") != null); // F-014 sibling-of-strip
    try testing.expect(td.lookupMethod(null, "stripTrailing") != null);
    try testing.expect(td.lookupMethod(null, "compareToIgnoreCase") != null);
    try testing.expect(td.lookupMethod(null, "intern") != null);
    try testing.expect(td.lookupMethod(null, "noSuchMethod") == null);

    // Idempotent: a second call leaves the table length unchanged.
    const len_before = td.method_table.len;
    try installNativeMethods(&rt);
    try testing.expectEqual(len_before, td.method_table.len);
}
