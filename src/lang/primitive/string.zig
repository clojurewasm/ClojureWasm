// SPDX-License-Identifier: EPL-2.0
//! `clojure.string/` namespace surface.
//!
//! Per ADR-0032 + ADR-0029, the `clojure.string` namespace is owned
//! by this file (registered at boot via `register(env)`); the
//! companion `src/lang/clj/clojure/string.clj` opens with
//! `(in-ns 'clojure.string)` and is loaded by the bootstrap loader.
//! The full namespace surface (upper/lower-case, trim family,
//! blank?, split / split-lines, join, replace / replace-first,
//! capitalize, escape, includes? / starts-with? / ends-with?,
//! index-of / last-index-of, reverse, ...) lands here; the
//! composable vars migrate to Pattern A `.clj` defns in string.clj.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const error_catalog = @import("../../runtime/error/catalog.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const charset = @import("../../runtime/charset.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const regex_match = @import("../../runtime/regex/match.zig");
const regex_replace = @import("../../runtime/regex/replace.zig");
const regex_prim = @import("regex.zig");
const print_mod = @import("../../runtime/print.zig");
const char_sequence = @import("../../runtime/char_sequence.zig");
const seqable = @import("../../runtime/seqable.zig");
const root_set = @import("../../runtime/gc/root_set.zig");

/// `(clojure.string/upper-case s)` — ASCII upper-case fold.
/// Non-ASCII codepoints pass through unchanged; full Unicode case
/// folding is tracked at debt D-057. JVM Clojure delegates to
/// `String.toUpperCase()` which is locale + Unicode aware; cw v1
/// will catch up as part of the broader charset.zig migration.
pub fn upperCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("upper-case", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try toStringArg(rt, env, args[0], "upper-case", loc, &aw);
    const buf = try charset.upperCaseAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(buf);
    return try string_collection.alloc(rt, buf);
}

/// `(clojure.string/lower-case s)` — mirror of `upperCase`. Same
/// Unicode case-folding caveat (D-057).
pub fn lowerCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("lower-case", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try toStringArg(rt, env, args[0], "lower-case", loc, &aw);
    const buf = try charset.lowerCaseAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(buf);
    return try string_collection.alloc(rt, buf);
}

/// `(clojure.string/blank? s)`: true iff `s` is nil, empty, or contains only
/// whitespace codepoints (per `charset.isAllWhitespace`, which matches JVM
/// `Character.isWhitespace` apart from U+00A0 etc.; see charset.zig for the
/// JVM-divergence note). `s` is any CharSequence (a StringBuilder, a
/// CharSequence deftype); any other non-nil value raises, clj's
/// ClassCastException.
pub fn blank(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("blank?", args, 1, loc);
    if (args[0].isNil()) return .true_val;
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], "blank?", loc, &aw);
    if (s.len == 0) return .true_val;
    const blank_all = charset.isAllWhitespace(s) catch return .false_val;
    return if (blank_all) .true_val else .false_val;
}

/// The first argument of clj's `.toString`-typed string fns, rendered.
///
/// clj hints those parameters `^CharSequence` but calls `.toString` on them,
/// so ANY non-nil value is accepted: `(upper-case :foo)` => ":FOO",
/// `(upper-case 42)` => "42". nil is NOT accepted (clj NPEs on `.toString`),
/// so `(str v)` is the wrong coercion — it would turn nil into "".
///
/// Rendering goes through `print.writeStrValue`, the same one `str` and the
/// `.toString` Object method use, so the three cannot answer differently.
/// The returned slice is owned by `aw` and lives until the caller deinits it.
///
/// NOT for the CharSequence-METHOD fns (trim / reverse / blank? / split): clj
/// calls CharSequence methods on those directly and throws ClassCastException
/// for a non-CharSequence, so they read through `char_sequence.textArg`.
fn toStringArg(
    rt: *Runtime,
    env: *env_mod.Env,
    v: Value,
    fn_name: []const u8,
    loc: error_mod.SourceLocation,
    aw: *std.Io.Writer.Allocating,
) anyerror![]const u8 {
    if (v.tag() == .string) return string_collection.asString(v);
    if (v.isNil())
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = "nil" });
    try print_mod.writeStrValue(rt, env, &aw.writer, v);
    return aw.writer.buffered();
}

const TrimVariant = enum { both, left, right, newline_right };

fn trimImpl(rt: *Runtime, env: *Env, fn_name: []const u8, variant: TrimVariant, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], fn_name, loc, &aw);
    const out = switch (variant) {
        .both => charset.trim(s),
        .left => charset.trimLeft(s),
        .right => charset.trimRight(s),
        .newline_right => charset.trimNewlineRight(s),
    };
    return try string_collection.alloc(rt, out);
}

/// `(clojure.string/trim s)` — strip Unicode whitespace from both
/// ends. Matches JVM `clojure.string/trim` (which uses
/// `Character/isWhitespace`, NOT `String.trim()` which is ASCII-only).
pub fn trimBoth(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return trimImpl(rt, env, "trim", .both, args, loc);
}

/// `(clojure.string/triml s)` — left edge only.
pub fn trimLeft(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return trimImpl(rt, env, "triml", .left, args, loc);
}

/// `(clojure.string/trimr s)` — right edge only.
pub fn trimRight(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return trimImpl(rt, env, "trimr", .right, args, loc);
}

/// `(clojure.string/trim-newline s)` — strip ONLY trailing `\r` /
/// `\n`. Narrower than `trimr` (no broader Unicode whitespace).
pub fn trimNewline(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return trimImpl(rt, env, "trim-newline", .newline_right, args, loc);
}

const PrefixCheck = enum { starts, ends, contains };

fn prefixImpl(rt: *Runtime, env: *Env, fn_name: []const u8, check: PrefixCheck, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 2, loc);
    // Only the FIRST argument coerces: clj `.toString`s `s` but types `substr`
    // as String, so `(starts-with? 421 "4")` is true while a non-string needle
    // is a ClassCastException there too.
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const haystack = try toStringArg(rt, env, args[0], fn_name, loc, &aw);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[1].tag()) });
    const needle = string_collection.asString(args[1]);
    const hit = switch (check) {
        // UTF-8 is self-synchronising — byte-equality is codepoint-
        // equality for prefix / suffix / substring at this scope.
        .starts => std.mem.startsWith(u8, haystack, needle),
        .ends => std.mem.endsWith(u8, haystack, needle),
        .contains => std.mem.find(u8, haystack, needle) != null,
    };
    return if (hit) Value.true_val else Value.false_val;
}

/// `(clojure.string/starts-with? s substr)`.
pub fn startsWith(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return prefixImpl(rt, env, "starts-with?", .starts, args, loc);
}

/// `(clojure.string/ends-with? s substr)`.
pub fn endsWith(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return prefixImpl(rt, env, "ends-with?", .ends, args, loc);
}

/// `(clojure.string/includes? s substr)`.
pub fn includes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return prefixImpl(rt, env, "includes?", .contains, args, loc);
}

/// `(clojure.string/index-of s substr)` / `(… s substr from-index)` —
/// codepoint index of the first occurrence (at or after from-index), or nil.
/// Per DIVERGENCE D1 the index is in codepoint units (JVM is UTF-16). The
/// 3-arity searches the codepoint tail `s[from..]` then re-bases the result.
pub fn indexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "index-of", .got = args.len, .min = 2, .max = 3 });
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const hay = try toStringArg(rt, env, args[0], "index-of", loc, &aw);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "index-of", .actual = @tagName(args[1].tag()) });
    const needle = string_collection.asString(args[1]);
    if (args.len == 3) {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "index-of", .expected = "integer from-index", .actual = @tagName(args[2].tag()) });
        var from: i64 = args[2].asInteger();
        if (from < 0) from = 0;
        const count: i64 = @intCast(charset.codepointCount(hay) catch return .nil_val);
        if (from > count) return .nil_val;
        const tail = charset.substring(hay, @intCast(from), @intCast(count)) catch return .nil_val;
        const rel = charset.codepointIndexOf(tail, needle) orelse return .nil_val;
        return Value.initInteger(@intCast(from + @as(i64, @intCast(rel))));
    }
    const idx = charset.codepointIndexOf(hay, needle) orelse return .nil_val;
    return Value.initInteger(@intCast(idx));
}

/// `(clojure.string/last-index-of s substr)` / `(… s substr from-index)` —
/// codepoint index of the LAST occurrence whose START is ≤ from-index, or nil.
/// 3-arity searches the prefix `s[0 .. from+len(substr)]` so a match starting
/// at from-index is still found, then takes its last occurrence.
pub fn lastIndexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "last-index-of", .got = args.len, .min = 2, .max = 3 });
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const hay = try toStringArg(rt, env, args[0], "last-index-of", loc, &aw);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "last-index-of", .actual = @tagName(args[1].tag()) });
    const needle = string_collection.asString(args[1]);
    if (args.len == 3) {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "last-index-of", .expected = "integer from-index", .actual = @tagName(args[2].tag()) });
        const from: i64 = args[2].asInteger();
        if (from < 0) return .nil_val;
        const count: i64 = @intCast(charset.codepointCount(hay) catch return .nil_val);
        const needle_count: i64 = @intCast(charset.codepointCount(needle) catch return .nil_val);
        var end: i64 = from + needle_count;
        if (end > count) end = count;
        const prefix = charset.substring(hay, 0, @intCast(end)) catch return .nil_val;
        const idx = charset.codepointLastIndexOf(prefix, needle) orelse return .nil_val;
        return Value.initInteger(@intCast(idx));
    }
    const idx = charset.codepointLastIndexOf(hay, needle) orelse return .nil_val;
    return Value.initInteger(@intCast(idx));
}

const ReplaceKind = regex_replace.ReplaceKind;

fn replaceImpl(rt: *Runtime, fn_name: []const u8, kind: ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[0].tag()) });
    // String-string match-replacement only. char-char and
    // regex-string / regex-fn forms raise feature_not_supported here.
    // SUPERSEDED: the public `replace` is the Pattern A `.clj` defn
    // dispatching over the `-str-replace-*` leaves (which DO cover
    // char-char + regex); this `replaceImpl`/`replace`/`replaceFirst`
    // path is legacy and no longer registered.
    if (args[1].tag() != .string)
        // clj throws a catchable ClassCastException / IllegalArgumentException
        // for a wrong-typed match — bad data, not a missing feature.
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "clojure.string/replace", .expected = "a string, char or regex match", .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "clojure.string/replace", .expected = "a string, char or fn replacement", .actual = @tagName(args[2].tag()) });
    const haystack = string_collection.asString(args[0]);
    const needle = string_collection.asString(args[1]);
    const replacement = string_collection.asString(args[2]);
    const out = switch (kind) {
        .all => try charset.replaceAllStringAlloc(rt.gc.infra, haystack, needle, replacement),
        .first => try charset.replaceFirstStringAlloc(rt.gc.infra, haystack, needle, replacement),
    };
    defer rt.gc.infra.free(out);
    return try string_collection.alloc(rt, out);
}

/// Legacy string-string-only `replace` (SUPERSEDED — the live surface
/// is the `.clj` defn over the `-str-replace-*` leaves, which handle
/// regex `Pattern` + `$N` captures; this leaf is no longer registered).
pub fn replace(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceImpl(rt, "replace", .all, args, loc);
}

/// `(clojure.string/replace-first s match replacement)`.
pub fn replaceFirst(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceImpl(rt, "replace-first", .first, args, loc);
}

// --- Row 7.12 (D-078): `replace` / `replace-first` are split into 6
//     private leaves per placement.yaml reservations
//     (`-str-replace-string` / `-str-replace-char` /
//     `-str-replace-pattern` × replace/replace-first). The Pattern A
//     `.clj` defn dispatches on `instance?` over these leaves; they
//     are private (`zig_leaf = true`) so user code does not depend on
//     them directly. ---

fn strReplaceStringImpl(rt: *Runtime, env: *Env, fn_name: []const u8, kind: ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const haystack = try toStringArg(rt, env, args[0], fn_name, loc, &aw);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[2].tag()) });
    const needle = string_collection.asString(args[1]);
    const replacement = string_collection.asString(args[2]);
    const out = switch (kind) {
        .all => try charset.replaceAllStringAlloc(rt.gc.infra, haystack, needle, replacement),
        .first => try charset.replaceFirstStringAlloc(rt.gc.infra, haystack, needle, replacement),
    };
    defer rt.gc.infra.free(out);
    return try string_collection.alloc(rt, out);
}

pub fn strReplaceString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplaceStringImpl(rt, env, "-str-replace-string", .all, args, loc);
}

pub fn strReplaceFirstString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplaceStringImpl(rt, env, "-str-replace-first-string", .first, args, loc);
}

fn strReplaceCharImpl(rt: *Runtime, env: *Env, fn_name: []const u8, kind: ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const haystack = try toStringArg(rt, env, args[0], fn_name, loc, &aw);
    if (args[1].tag() != .char)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "char", .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .char)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "char", .actual = @tagName(args[2].tag()) });
    const out = try charset.replaceCharAlloc(rt.gc.infra, haystack, args[1].asChar(), args[2].asChar(), kind == .first);
    defer rt.gc.infra.free(out);
    return try string_collection.alloc(rt, out);
}

pub fn strReplaceChar(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplaceCharImpl(rt, env, "-str-replace-char", .all, args, loc);
}

pub fn strReplaceFirstChar(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplaceCharImpl(rt, env, "-str-replace-first-char", .first, args, loc);
}

fn strReplacePatternImpl(rt: *Runtime, env: *Env, fn_name: []const u8, kind: ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const haystack = try toStringArg(rt, env, args[0], fn_name, loc, &aw);
    if (args[1].tag() != .regex)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "regex (Pattern)", .actual = @tagName(args[1].tag()) });
    const program = regex_value.asRegex(args[1]).program;

    // String replacement: delegate to the shared neutral leaf
    // (`runtime/regex/replace.zig`, also used by `.replaceAll` /
    // `.replaceFirst` per F-009). The `$N` backref / `\c` escape
    // expansion lives there.
    if (args[2].tag() == .string)
        return regex_replace.replaceString(rt, program, haystack, string_collection.asString(args[2]), kind);

    // Any non-string replacement is invoked as a FUNCTION via the vtable —
    // clj passes the match to it (a map / keyword / set / vector is IFn too,
    // e.g. {"X" "-"} looked up by the match "X"). A genuinely non-callable
    // value raises inside callFn, as it does in clj. The vtable call stays in
    // this Layer-2 file (the neutral leaf does not own the interpreter callback).
    const vt = rt.vtable orelse
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "regex-replace fn-arm before vtable install" });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gc.infra);
    var pos: u32 = 0;
    while (pos <= haystack.len) {
        const match = (try regex_match.findFrom(rt.gc.infra, program, haystack, pos)) orelse break;
        defer match.deinit(rt.gc.infra);
        try out.appendSlice(rt.gc.infra, haystack[pos..match.start]);
        // The replacement fn receives the `re-find` shape: the match
        // vector `[whole g1 …]` when the pattern has capturing groups,
        // else the whole-match string (D-093; reuses buildMatchResult).
        const arg_val = try regex_prim.buildMatchResult(rt, program, haystack, match);
        var call_args = [_]Value{arg_val};
        const result = try vt.callFn(rt, env, args[2], &call_args, loc);
        if (result.tag() != .string)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "fn returning string", .actual = @tagName(result.tag()) });
        try out.appendSlice(rt.gc.infra, string_collection.asString(result));
        // Empty matches advance by 1 byte to avoid an infinite loop
        // (mirrors JVM `Matcher.replaceAll` on `""` matches).
        pos = if (match.end > match.start) match.end else match.start + 1;
        if (kind == .first) break;
    }
    if (pos <= haystack.len) try out.appendSlice(rt.gc.infra, haystack[pos..]);
    return try string_collection.alloc(rt, out.items);
}

pub fn strReplacePattern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplacePatternImpl(rt, env, "-str-replace-pattern", .all, args, loc);
}

pub fn strReplaceFirstPattern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return strReplacePatternImpl(rt, env, "-str-replace-first-pattern", .first, args, loc);
}

/// `(clojure.string/reverse s)` — codepoint-reversed copy. UTF-8
/// surrogate pairs are nonexistent so single-codepoint reversal is
/// the natural semantics.
pub fn reverse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("reverse", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], "reverse", loc, &aw);
    const out = try charset.reverseCodepointsAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(out);
    return try string_collection.alloc(rt, out);
}

/// `(clojure.string/escape s cmap)` — replace each character of `s`
/// with the result of `(cmap c)`. cmap may be a map (`array_map` or
/// `hash_map`) or a fn (`fn_val` / `builtin_fn`). When `(cmap c)`
/// returns nil, the original character is kept; otherwise the
/// returned value must be a string. Clojure JVM also accepts char
/// and `(str ...)`-coercible values; the broader coercion is a
/// tracked follow-up (D-094).
pub fn escape(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("escape", args, 2, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], "escape", loc, &aw);
    const cmap = args[1];

    const cmap_kind: enum { map, fn_callable, unsupported } = switch (cmap.tag()) {
        .array_map, .hash_map => .map,
        .fn_val, .builtin_fn => .fn_callable,
        else => .unsupported,
    };
    if (cmap_kind == .unsupported)
        // clj throws a catchable ClassCastException when cmap is neither a map
        // nor a fn, so this is a `.type_error`, not the uncatchable
        // `.not_implemented`.
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "clojure.string/escape",
            .expected = "a map or a fn",
            .actual = @tagName(args[1].tag()),
        });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gc.infra);

    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var prev_i: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        const char_bytes = s[prev_i..iter.i];
        prev_i = iter.i;
        const replacement: Value = switch (cmap_kind) {
            .map => try map_collection.get(cmap, Value.initChar(cp)),
            .fn_callable => blk: {
                const callee_args = [_]Value{Value.initChar(cp)};
                const vt = rt.vtable orelse return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/escape (vtable not installed)" });
                break :blk try vt.callFn(rt, env, cmap, &callee_args, loc);
            },
            .unsupported => unreachable,
        };
        if (replacement.tag() == .nil) {
            try out.appendSlice(rt.gc.infra, char_bytes);
        } else if (replacement.tag() == .string) {
            try out.appendSlice(rt.gc.infra, string_collection.asString(replacement));
        } else {
            // The cmap fn returned an unusable value — the caller's data.
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "clojure.string/escape", .expected = "a string or nil from the cmap fn", .actual = "another value" });
        }
    }

    return try string_collection.alloc(rt, out.items);
}

/// `(clojure.string/capitalize s)` — upper-case the first codepoint,
/// lower-case the rest. Empty string returns "". Composes
/// `charset.upperCaseAlloc` + `charset.lowerCaseAlloc` on byte ranges
/// split at the first codepoint's boundary (no extra allocation
/// beyond the per-step buffers + the final heap string).
pub fn capitalize(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("capitalize", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try toStringArg(rt, env, args[0], "capitalize", loc, &aw);
    if (s.len == 0) return try string_collection.alloc(rt, "");

    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    _ = iter.nextCodepoint();
    const first_end = iter.i;

    const upper_first = try charset.upperCaseAlloc(rt.gc.infra, s[0..first_end]);
    defer rt.gc.infra.free(upper_first);
    const lower_rest = try charset.lowerCaseAlloc(rt.gc.infra, s[first_end..]);
    defer rt.gc.infra.free(lower_rest);

    var combined = try rt.gc.infra.alloc(u8, upper_first.len + lower_rest.len);
    defer rt.gc.infra.free(combined);
    @memcpy(combined[0..upper_first.len], upper_first);
    @memcpy(combined[upper_first.len..], lower_rest);

    return try string_collection.alloc(rt, combined);
}

fn coerceRegex(rt: *Runtime, v: Value, loc: SourceLocation, fn_name: []const u8) anyerror!*const regex_value.Regex {
    if (v.tag() == .regex) return regex_value.asRegex(v);
    if (v.tag() == .string) {
        const compiled = regex_value.alloc(rt, string_collection.asString(v), .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => |e| return regex_value.raiseCompileError(e, loc),
        };
        return regex_value.asRegex(compiled);
    }
    return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(v.tag()) });
}

/// `(clojure.string/split s re)` — 2-arity, no-limit. Iterates
/// `regex_match.findFrom` over `s`, producing a vector of byte
/// substrings between matches. Zero-width matches advance by one
/// codepoint to guarantee termination. Empty input yields `[""]`
/// (matches JVM behaviour).
///
/// `limit` (optional 3rd arg, default 0) matches `Pattern.split`:
///   - `> 0`: at most `limit` parts; the unmatched remainder is the last.
///   - `== 0` (default): unlimited parts, **trailing empty strings removed**.
///   - `< 0`: unlimited parts, trailing empties kept.
/// A no-match input returns `[s]` (single element, never stripped) — JVM's
/// `index == 0` short-circuit; the strip only fires once a match was consumed.
pub fn split(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "split", .got = args.len, .min = 2, .max = 3 });
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], "split", loc, &aw);
    const r = try coerceRegex(rt, args[1], loc, "split");
    const limit: i64 = if (args.len == 3) try error_catalog.expectInteger(args[2], "split", loc) else 0;
    // Shared neutral leaf (also used by `.split` per F-009).
    return regex_replace.splitToVector(rt, r.program, s, limit);
}

/// `(clojure.string/split-lines s)` — split on `\r?\n`. Hand-rolled
/// byte scan to skip the regex round-trip for this hot pattern.
/// Matches the JVM contract: trailing empty terminator is dropped
/// (so `"a\n"` → `["a"]`, not `["a" ""]`).
pub fn splitLines(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("split-lines", args, 1, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const s = try char_sequence.textArg(rt, env, args[0], "split-lines", loc, &aw);

    if (s.len == 0) {
        const empty_s = try string_collection.alloc(rt, "");
        return try vector_collection.conj(rt, vector_collection.empty(), empty_s);
    }

    var parts: std.ArrayList(Value) = .empty;
    defer parts.deinit(rt.gpa);
    var pos: usize = 0;
    while (pos < s.len) {
        const nl_off = std.mem.findScalarPos(u8, s, pos, '\n');
        const line_end_excl = nl_off orelse s.len;
        var line_strip_end = line_end_excl;
        if (nl_off != null and line_strip_end > pos and s[line_strip_end - 1] == '\r') line_strip_end -= 1;
        try parts.append(rt.gpa, try string_collection.alloc(rt, s[pos..line_strip_end]));
        if (nl_off) |i| pos = i + 1 else break;
    }

    while (parts.items.len > 0 and
        string_collection.asString(parts.items[parts.items.len - 1]).len == 0)
    {
        _ = parts.pop();
    }

    var result = vector_collection.empty();
    for (parts.items) |part| result = try vector_collection.conj(rt, result, part);
    return result;
}

/// `-join` leaf: the whole of `(clojure.string/join coll)` /
/// `(clojure.string/join sep coll)`. clj's body is a StringBuilder loop over
/// `(seq coll)` appending `(str x)` and `(str sep)` between elements; this is
/// that loop in Zig. `coll` is any seqable (vector, list, lazy seq, string,
/// map, set, a custom Seqable); `sep` and every element render through
/// `print.writeStrValue`, the same renderer `str` uses, so nil renders "" and
/// a char / keyword / number renders as `str` would. A non-seqable `coll`
/// raises through `seqable.seq` exactly like `(seq coll)`.
///
/// PERF: the old Pattern A body `(apply str (interpose sep coll))` built a
/// lazy interpose seq (a closure call + lazy cell per element) and then an
/// `apply` arg spill; that was 87% of bench/vs_bb string_ops. [refs: O-070]
pub fn join(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("join", args, 1, 2, loc);
    var out: std.Io.Writer.Allocating = .init(rt.gc.infra);
    defer out.deinit();

    // The separator is rendered once up front (clj `(str separator)` per gap
    // gives the same text every time).
    var sep_aw: std.Io.Writer.Allocating = .init(rt.gc.infra);
    defer sep_aw.deinit();
    if (args.len == 2) try print_mod.writeStrValue(rt, env, &sep_aw.writer, args[0]);
    const sep = sep_aw.writer.buffered();

    // GC-ROOT: A14 — [cursor, element]. `seq`/`next` may build fresh views or
    // realize a lazy seq, and rendering an instance's toString re-enters eval;
    // either can collect while the cursor is held only here.
    // [ref: .dev/gc_rooting.md §A]
    var roots = [_]Value{ .nil_val, .nil_val };
    var sp: u16 = roots.len;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;

    const coll = args[args.len - 1];
    switch (coll.tag()) {
        // Indexed fast path: no seq view, no per-element cursor allocation.
        .vector => {
            const n = vector_collection.count(coll);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try out.writer.writeAll(sep);
                const elt = vector_collection.nth(coll, i);
                if (elt.tag() == .string)
                    try out.writer.writeAll(string_collection.asString(elt))
                else
                    try print_mod.writeStrValue(rt, env, &out.writer, elt);
            }
        },
        else => {
            roots[0] = try seqable.seq(rt, env, coll, loc);
            var first_elt = true;
            while (roots[0].tag() != .nil) {
                if (!first_elt) try out.writer.writeAll(sep);
                first_elt = false;
                roots[1] = try seqable.first(rt, env, roots[0], loc);
                if (roots[1].tag() == .string)
                    try out.writer.writeAll(string_collection.asString(roots[1]))
                else
                    try print_mod.writeStrValue(rt, env, &out.writer, roots[1]);
                roots[0] = try seqable.next(rt, env, roots[0], loc);
            }
        },
    }
    return try string_collection.alloc(rt, out.writer.buffered());
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

/// Pattern B2 leaves with the `-name` dash-prefix convention +
/// `.private = true` (ADR-0033 D4) metadata. The user-visible names
/// (`upper-case`, `lower-case`, ...) resolve via shim `(def ...)` /
/// Pattern A defns in `lang/clj/clojure/string.clj`. User-ns callers
/// reaching for `clojure.string/-upper-case` qualified trip the
/// analyzer's cross-ns private check; intra-clojure.string shim
/// resolution stays same-ns and passes.
const LEAF_ENTRIES = [_]Entry{
    .{ .name = "-upper-case", .f = &upperCase },
    .{ .name = "-lower-case", .f = &lowerCase },
    .{ .name = "-trim", .f = &trimBoth },
    .{ .name = "-triml", .f = &trimLeft },
    .{ .name = "-trimr", .f = &trimRight },
    .{ .name = "-trim-newline", .f = &trimNewline },
    .{ .name = "-starts-with?", .f = &startsWith },
    .{ .name = "-ends-with?", .f = &endsWith },
    .{ .name = "-includes?", .f = &includes },
    .{ .name = "-index-of", .f = &indexOf },
    .{ .name = "-last-index-of", .f = &lastIndexOf },
    .{ .name = "-reverse", .f = &reverse },
    // Public surface stays unchanged via shim defns in
    // `lang/clj/clojure/string.clj`.
    .{ .name = "-blank?", .f = &blank },
    .{ .name = "-split", .f = &split },
    .{ .name = "-split-lines", .f = &splitLines },
    // capitalize + join: the public name is the Pattern A defn over
    // `str` + `subs`; these Zig leaves are the opt-in fast path.
    .{ .name = "-capitalize", .f = &capitalize },
    .{ .name = "-join", .f = &join },
    // Row 7.12 (D-078): 6 replace sub-leaves per placement.yaml
    // reservations. The Pattern A `(defn replace …)` dispatches on
    // `instance?` across these.
    .{ .name = "-str-replace-string", .f = &strReplaceString },
    .{ .name = "-str-replace-first-string", .f = &strReplaceFirstString },
    .{ .name = "-str-replace-char", .f = &strReplaceChar },
    .{ .name = "-str-replace-first-char", .f = &strReplaceFirstChar },
    .{ .name = "-str-replace-pattern", .f = &strReplacePattern },
    .{ .name = "-str-replace-first-pattern", .f = &strReplaceFirstPattern },
};

/// Vars that stay as Zig leaves at their public name. `replace` /
/// `replace-first` are Pattern A `.clj` defns (see
/// `lang/clj/clojure/string.clj`) dispatching on `instance?` across
/// the 6 `-str-replace-*` private leaves. `escape` stays Zig (its
/// Pattern A migration is an opportunistic follow-up — D-094 — when
/// the codepoint-walk primitives + cmap dispatch ergonomics mature).
const ENTRIES = [_]Entry{
    .{ .name = "escape", .f = &escape },
};

/// Create the `clojure.string` namespace (idempotent — uses
/// `findOrCreateNs`) and intern this cycle's primitives into it.
/// Called from `lang/primitive.zig::registerAll` before the
/// bootstrap loader runs, so by the time `string.clj`'s
/// `(in-ns 'clojure.string)` form executes, the namespace already
/// carries these Vars.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.string");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
    for (LEAF_ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), .{
            .private = true,
            .zig_leaf = true,
        });
    }
}
