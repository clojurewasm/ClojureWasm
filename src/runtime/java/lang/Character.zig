// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Character` static methods.
//!
//! Backend: impl-only
//! Impl deps: charset
//! Clojure peer: none
//!
//! Thin wrapper over the single-codepoint classification + case-folding
//! helpers in the neutral `runtime/charset.zig` leaf (F-009). isDigit /
//! isLetter / isWhitespace return bool; toUpperCase / toLowerCase return
//! a char (non-letters unchanged); digit returns the radix digit value
//! or -1. Classification + case folding are ASCII-only, matching cljw's
//! existing string case behaviour (D-057 Unicode caveat); the JVM uses
//! full Unicode tables, so a non-ASCII codepoint diverges (recorded).
//! The arg is a cljw `.char` Value (built with `(char N)` / a `\x`
//! literal); a non-char arg is a type error.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const string_collection = @import("../../collection/string.zig");
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

/// `Character/isDigit` / `isLetter` / `isWhitespace`: classify a char,
/// return a bool. JVM reference: java.lang.Character#is*.
fn Classify(comptime name: []const u8, comptime f: fn (u21) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const cp = try argChar(args[0], "Character/" ++ name, loc);
            return if (f(cp)) .true_val else .false_val;
        }
    };
}

/// `Character/toUpperCase` / `toLowerCase`: fold a char's case, return a
/// char (non-letters unchanged). JVM reference: java.lang.Character#to*Case.
fn CaseFold(comptime name: []const u8, comptime f: fn (u21) u21) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Character/" ++ name, args, 1, loc);
            const cp = try argChar(args[0], "Character/" ++ name, loc);
            return Value.initChar(f(cp));
        }
    };
}

/// Implements `(Character/digit ch radix)`. Spec: the value of `ch` as a
/// digit in `radix` (0-9 then a-z/A-Z = 10-35), or -1 if it is not such a
/// digit or radix is outside 2..36. JVM reference: java.lang.Character#digit.
/// cw v1 tier: A (§A26 clj differential sweep).
fn digit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/digit", args, 2, loc);
    const cp = try argChar(args[0], "Character/digit", loc);
    const r = try error_catalog.expectInteger(args[1], "Character/digit", loc);
    if (r < 2 or r > 36) return Value.initInteger(-1);
    const v = charset.digitValue(cp, @intCast(r)) orelse return Value.initInteger(-1);
    return Value.initInteger(@as(i64, v));
}

/// Implements `(Character/getNumericValue ch)`. Spec: the numeric value of
/// `ch` (digits `0`-`9`, letters `a`-`z`/`A`-`Z` = 10-35), or -1 if none
/// (ASCII subset; D-057 Unicode caveat). JVM ref: Character#getNumericValue.
fn getNumericValue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Character/getNumericValue", args, 1, loc);
    const cp = try argChar(args[0], "Character/getNumericValue", loc);
    const v = charset.digitValue(cp, 36) orelse return Value.initInteger(-1);
    return Value.initInteger(@as(i64, v));
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

fn initCharacter(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "isDigit", &Classify("isDigit", charset.isDigitCodepoint).call },
        .{ "isLetter", &Classify("isLetter", charset.isLetterCodepoint).call },
        .{ "isLetterOrDigit", &Classify("isLetterOrDigit", charset.isLetterOrDigitCodepoint).call },
        .{ "isWhitespace", &Classify("isWhitespace", charset.isWhitespaceCodepoint).call },
        .{ "isUpperCase", &Classify("isUpperCase", charset.isUpperCodepoint).call },
        .{ "isLowerCase", &Classify("isLowerCase", charset.isLowerCodepoint).call },
        .{ "toUpperCase", &CaseFold("toUpperCase", charset.toUpperCodepoint).call },
        .{ "toLowerCase", &CaseFold("toLowerCase", charset.toLowerCodepoint).call },
        .{ "digit", &digit },
        .{ "getNumericValue", &getNumericValue },
        .{ "forDigit", &forDigit },
        .{ "codePointAt", &codePointAt },
        .{ "toChars", &toChars },
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

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.Character",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
