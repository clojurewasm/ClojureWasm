// SPDX-License-Identifier: EPL-2.0
//! `clojure.string/` namespace surface — Phase 6.9 cycle 1.
//!
//! Per ADR-0032 + ADR-0029, the `clojure.string` namespace is owned
//! by this file (registered at boot via `register(env)`); the
//! companion `src/lang/clj/clojure/string.clj` opens with
//! `(in-ns 'clojure.string)` and is loaded by the bootstrap loader
//! to pin the namespace reachability + reserve future Clojure-side
//! defns (capitalize / split-lines etc. arrive in later cycles).
//!
//! Cycle 1 ships `upper-case` / `lower-case` / `blank?` — the
//! simplest trio that proves the multi-file loader + (in-ns)
//! primitive + ns surface wiring end-to-end. The remaining ~18
//! vars land in cycles 2-4 per the per-task survey at
//! `private/notes/phase6-6.9-survey.md` §6.

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

/// `(clojure.string/upper-case s)` — ASCII upper-case fold per cycle
/// 1. Non-ASCII codepoints pass through unchanged; full Unicode case
/// folding is tracked at debt D-057 (lands at Phase 11+ conformance).
/// JVM Clojure delegates to `String.toUpperCase()` which is locale +
/// Unicode aware; cw v1 will catch up as part of the broader
/// charset.zig migration.
pub fn upperCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("upper-case", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "upper-case", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const buf = try charset.upperCaseAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(buf);
    return try string_collection.alloc(rt, buf);
}

/// `(clojure.string/lower-case s)` — mirror of `upperCase`. Same
/// Phase-11 Unicode caveat (D-057).
pub fn lowerCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("lower-case", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "lower-case", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const buf = try charset.lowerCaseAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(buf);
    return try string_collection.alloc(rt, buf);
}

/// `(clojure.string/blank? s)` — true iff `s` is nil, empty, or
/// contains only whitespace codepoints (per `charset.isAllWhitespace`,
/// matches JVM `Character.isWhitespace` apart from U+00A0 etc. —
/// see charset.zig for the JVM-divergence note). Non-string + non-nil
/// raises a type error; JVM Clojure accepts CharSequence so this is
/// a deliberate cw v1 surface tightening.
pub fn blank(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("blank?", args, 1, loc);
    const a = args[0];
    if (a.tag() == .nil) return .true_val;
    if (a.tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "blank?", .actual = @tagName(a.tag()) });
    const s = string_collection.asString(a);
    if (s.len == 0) return .true_val;
    const blank_all = charset.isAllWhitespace(s) catch return .false_val;
    return if (blank_all) .true_val else .false_val;
}

const TrimVariant = enum { both, left, right, newline_right };

fn trimImpl(rt: *Runtime, fn_name: []const u8, variant: TrimVariant, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
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
    _ = env;
    return trimImpl(rt, "trim", .both, args, loc);
}

/// `(clojure.string/triml s)` — left edge only.
pub fn trimLeft(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return trimImpl(rt, "triml", .left, args, loc);
}

/// `(clojure.string/trimr s)` — right edge only.
pub fn trimRight(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return trimImpl(rt, "trimr", .right, args, loc);
}

/// `(clojure.string/trim-newline s)` — strip ONLY trailing `\r` /
/// `\n`. Narrower than `trimr` (no broader Unicode whitespace).
pub fn trimNewline(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return trimImpl(rt, "trim-newline", .newline_right, args, loc);
}

const PrefixCheck = enum { starts, ends, contains };

fn prefixImpl(fn_name: []const u8, check: PrefixCheck, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[1].tag()) });
    const haystack = string_collection.asString(args[0]);
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
    _ = rt;
    _ = env;
    return prefixImpl("starts-with?", .starts, args, loc);
}

/// `(clojure.string/ends-with? s substr)`.
pub fn endsWith(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return prefixImpl("ends-with?", .ends, args, loc);
}

/// `(clojure.string/includes? s substr)`.
pub fn includes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return prefixImpl("includes?", .contains, args, loc);
}

/// `(clojure.string/index-of s substr)` — codepoint index of first
/// occurrence, or nil. Per DIVERGENCE D1 the index is in codepoint
/// units (JVM is UTF-16 code-unit index). 2-arity (substr) only at
/// cycle 3; the optional `from-index` arity lands later when integer
/// arg validation absorbs negative offsets.
pub fn indexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("index-of", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "index-of", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "index-of", .actual = @tagName(args[1].tag()) });
    const idx = charset.codepointIndexOf(string_collection.asString(args[0]), string_collection.asString(args[1])) orelse return .nil_val;
    return Value.initInteger(@intCast(idx));
}

/// `(clojure.string/last-index-of s substr)` — codepoint index of
/// LAST occurrence, or nil.
pub fn lastIndexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("last-index-of", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "last-index-of", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "last-index-of", .actual = @tagName(args[1].tag()) });
    const idx = charset.codepointLastIndexOf(string_collection.asString(args[0]), string_collection.asString(args[1])) orelse return .nil_val;
    return Value.initInteger(@intCast(idx));
}

const ReplaceKind = enum { all, first };

fn replaceImpl(rt: *Runtime, fn_name: []const u8, kind: ReplaceKind, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 3, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(args[0].tag()) });
    // Cycle 3 supports only string-string match-replacement. char-char
    // and regex-string / regex-fn forms raise feature_not_supported
    // pending D-051 cycle 3 (captures) + a dedicated char-char arm
    // (cycle 4 or later — see survey §3 DIVERGENCE D3).
    if (args[1].tag() != .string)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/replace with non-string match" });
    if (args[2].tag() != .string)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/replace with non-string replacement" });
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

/// `(clojure.string/replace s match replacement)` — cycle 3
/// supports string-string only. Regex `Pattern` + `$N` captures land
/// at D-051 cycle 3.
pub fn replace(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceImpl(rt, "replace", .all, args, loc);
}

/// `(clojure.string/replace-first s match replacement)`.
pub fn replaceFirst(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return replaceImpl(rt, "replace-first", .first, args, loc);
}

/// `(clojure.string/reverse s)` — codepoint-reversed copy. UTF-8
/// surrogate pairs are nonexistent so single-codepoint reversal is
/// the natural semantics.
pub fn reverse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("reverse", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "reverse", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const out = try charset.reverseCodepointsAlloc(rt.gc.infra, s);
    defer rt.gc.infra.free(out);
    return try string_collection.alloc(rt, out);
}

/// `(clojure.string/escape s cmap)` — replace each character of `s`
/// with the result of `(cmap c)`. cmap may be a map (`array_map` or
/// `hash_map`) or a fn (`fn_val` / `builtin_fn`). When `(cmap c)`
/// returns nil, the original character is kept; otherwise the
/// returned value must be a string (cycle 3 limitation — Clojure
/// JVM also accepts char and `(str ...)`-coercible values; cw v1's
/// `str` coercion graduates in a later cycle).
pub fn escape(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("escape", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "escape", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const cmap = args[1];

    const cmap_kind: enum { map, fn_callable, unsupported } = switch (cmap.tag()) {
        .array_map, .hash_map => .map,
        .fn_val, .builtin_fn => .fn_callable,
        else => .unsupported,
    };
    if (cmap_kind == .unsupported)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/escape with non-map non-fn cmap" });

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
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/escape cmap returned non-nil non-string" });
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
    _ = env;
    try error_catalog.checkArity("capitalize", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "capitalize", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
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
            else => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/split with invalid regex source" }),
        };
        return regex_value.asRegex(compiled);
    }
    return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(v.tag()) });
}

/// `(clojure.string/split s re)` — 2-arity, no-limit. Iterates
/// `regex_match.findFrom` over `s`, producing a vector of byte
/// substrings between matches. Zero-width matches advance by one
/// codepoint to guarantee termination. Empty input yields `[""]`
/// (matches JVM behaviour). Trailing-empty removal + the 3-arity
/// `limit` form land in a later cycle (no debt row — both lift
/// naturally when more `clojure.string` callers exercise them).
pub fn split(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("split", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "split", .actual = @tagName(args[0].tag()) });
    const r = try coerceRegex(rt, args[1], loc, "split");
    const s = string_collection.asString(args[0]);

    var result = vector_collection.empty();
    if (s.len == 0) {
        const empty_s = try string_collection.alloc(rt, "");
        return try vector_collection.conj(rt, result, empty_s);
    }

    var pos: u32 = 0;
    while (true) {
        const match = (try regex_match.findFrom(rt.gpa, r.program, s, pos)) orelse {
            const tail_v = try string_collection.alloc(rt, s[pos..]);
            result = try vector_collection.conj(rt, result, tail_v);
            break;
        };
        const before_v = try string_collection.alloc(rt, s[pos..match.start]);
        result = try vector_collection.conj(rt, result, before_v);
        if (match.end == match.start) {
            // Zero-width — advance by one byte to make progress.
            // Strictly cycle 4 limitation; codepoint-aware advance
            // for non-ASCII zero-width patterns is a future refinement.
            if (match.end >= s.len) {
                break;
            }
            pos = match.end + 1;
        } else {
            pos = match.end;
        }
        if (pos >= s.len) {
            const tail_v = try string_collection.alloc(rt, s[pos..]);
            result = try vector_collection.conj(rt, result, tail_v);
            break;
        }
    }
    return result;
}

/// `(clojure.string/split-lines s)` — split on `\r?\n`. Hand-rolled
/// byte scan to skip the regex round-trip for this hot pattern.
/// Matches the JVM contract: trailing empty terminator is dropped
/// (so `"a\n"` → `["a"]`, not `["a" ""]`).
pub fn splitLines(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("split-lines", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "split-lines", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);

    var result = vector_collection.empty();
    if (s.len == 0) {
        const empty_s = try string_collection.alloc(rt, "");
        return try vector_collection.conj(rt, result, empty_s);
    }

    var pos: usize = 0;
    while (pos < s.len) {
        const nl_off = std.mem.findScalarPos(u8, s, pos, '\n');
        const line_end_excl = nl_off orelse s.len;
        var line_strip_end = line_end_excl;
        if (line_strip_end > pos and s[line_strip_end - 1] == '\r') line_strip_end -= 1;
        const v = try string_collection.alloc(rt, s[pos..line_strip_end]);
        result = try vector_collection.conj(rt, result, v);
        if (nl_off) |i| pos = i + 1 else break;
    }
    // Drop trailing empty from a final \n (JVM convention).
    // (No-op when split-lines was called on input without trailing \n.)
    return result;
}

/// `(clojure.string/join coll)` / `(clojure.string/join sep coll)`.
/// `coll` must be a `vector` (cycle 4 limitation — list / seq /
/// nil arms land alongside the broader collection-iteration surface
/// in a later cycle; raising `feature_not_supported` keeps the
/// error explicit). Elements must be strings; non-string elements
/// raise `feature_not_supported` pending the `str` coercion
/// primitive landing.
pub fn join(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("join", args, 1, 2, loc);
    const sep: []const u8 = if (args.len == 2) blk: {
        if (args[0].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "join", .actual = @tagName(args[0].tag()) });
        break :blk string_collection.asString(args[0]);
    } else "";
    const coll = if (args.len == 2) args[1] else args[0];

    if (coll.tag() != .vector)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/join with non-vector coll" });

    const n = vector_collection.count(coll);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gc.infra);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const elt = vector_collection.nth(coll, i);
        if (elt.tag() != .string)
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "clojure.string/join with non-string element" });
        if (i > 0 and sep.len > 0) try out.appendSlice(rt.gc.infra, sep);
        try out.appendSlice(rt.gc.infra, string_collection.asString(elt));
    }
    return try string_collection.alloc(rt, out.items);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

/// Phase 6.16.d migration (v5 §8.1 + §9.2): 12 Pattern B2 leaves with
/// the `-name` dash-prefix convention + `.private = true` ADR-0033 D4
/// metadata. The user-visible names (`upper-case`, `lower-case`, ...)
/// land via 1-line shim `(def ...)` defns in `lang/clj/clojure/string.clj`.
/// User-ns callers reaching for `clojure.string/-upper-case` qualified
/// trip the analyzer's cross-ns private check; intra-clojure.string
/// shim resolution stays same-ns and passes.
///
/// 6.16.e (next) migrates the remaining 8 (`blank?`, `replace`,
/// `replace-first`, `escape`, `capitalize`, `split`, `split-lines`,
/// `join`) to Pattern A `.clj` defns when their compositions become
/// tractable.
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
    // Phase 6.16.e.1 (GREEN trio per survey): pure renames into
    // the leaf table. Public surface stays unchanged via shim
    // defns in `lang/clj/clojure/string.clj`.
    .{ .name = "-blank?", .f = &blank },
    .{ .name = "-split", .f = &split },
    .{ .name = "-split-lines", .f = &splitLines },
};

/// Vars that stay as Zig leaves at their public name for this cycle.
/// 6.16.e.2+ migrates the YELLOW subset (`capitalize` / `join`) once
/// `str` + `subs` Tier-A primitives land; `replace` / `replace-first`
/// / `escape` (RED) stay until `instance?` + regex sub-leaf split
/// land in a later cycle (D-NNN, post-6.16.e).
const ENTRIES = [_]Entry{
    .{ .name = "replace", .f = &replace },
    .{ .name = "replace-first", .f = &replaceFirst },
    .{ .name = "escape", .f = &escape },
    .{ .name = "capitalize", .f = &capitalize },
    .{ .name = "join", .f = &join },
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
