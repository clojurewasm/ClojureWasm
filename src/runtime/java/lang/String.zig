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

/// Implements `(.toUpperCase s)`.
/// Spec: returns a copy of the string with all codepoints upper-cased.
/// JVM reference: java.lang.String#toUpperCase.
/// cw v1 tier: A (Phase 14 / ADR-0050 am1).
fn toUpperCase(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // args[0] is the receiver; a no-arg instance method takes exactly it.
    try error_catalog.checkArity(".toUpperCase", args, 1, loc);
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
    try error_catalog.checkArity(".toLowerCase", args, 1, loc);
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
    const start: usize = @intCast(args[1].asInteger());
    var end: usize = std.math.maxInt(usize);
    if (args.len == 3) {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = ".substring", .actual = @tagName(args[2].tag()) });
        end = @intCast(args[2].asInteger());
    }
    const slice = charset.substring(s, start, end) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = ".substring index out of range" });
    return string_collection.alloc(rt, slice);
}

/// Implements `(.indexOf s needle)` → codepoint index of the first
/// occurrence of the substring `needle`, or -1 when absent. JVM
/// reference: java.lang.String#indexOf. cw v1 tier: A.
fn indexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".indexOf", args, 2, loc);
    const hay = string_collection.asString(args[0]);
    // JVM overloads `indexOf(String)` and `indexOf(int codepoint)`.
    if (args[1].tag() == .integer) {
        const cp = args[1].asInteger();
        if (cp < 0 or cp > 0x10FFFF) return Value.initInteger(-1);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return Value.initInteger(-1);
        const idx = charset.codepointIndexOf(hay, buf[0..n]) orelse return Value.initInteger(-1);
        return Value.initInteger(@intCast(idx));
    }
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".indexOf", .actual = @tagName(args[1].tag()) });
    const idx = charset.codepointIndexOf(hay, string_collection.asString(args[1])) orelse
        return Value.initInteger(-1);
    return Value.initInteger(@intCast(idx));
}

/// `(.lastIndexOf s needle)` → codepoint index of the LAST occurrence, or
/// -1. JVM reference: java.lang.String#lastIndexOf(String).
fn lastIndexOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".lastIndexOf", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".lastIndexOf", .actual = @tagName(args[1].tag()) });
    const idx = charset.codepointLastIndexOf(string_collection.asString(args[0]), string_collection.asString(args[1])) orelse
        return Value.initInteger(-1);
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
        .{ "codePointAt", &codePointAt }, .{ "compareTo", &compareTo },
        .{ "matches", &matches },
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
    try testing.expect(td.lookupMethod(null, "indexOf") != null);
    try testing.expect(td.lookupMethod(null, "charAt") != null);
    try testing.expect(td.lookupMethod(null, "contains") != null);
    try testing.expect(td.lookupMethod(null, "startsWith") != null);
    try testing.expect(td.lookupMethod(null, "endsWith") != null);
    try testing.expect(td.lookupMethod(null, "isEmpty") != null);
    try testing.expect(td.lookupMethod(null, "concat") != null);
    try testing.expect(td.lookupMethod(null, "repeat") != null);
    try testing.expect(td.lookupMethod(null, "replace") != null);
    try testing.expect(td.lookupMethod(null, "noSuchMethod") == null);

    // Idempotent: a second call leaves the table length unchanged.
    const len_before = td.method_table.len;
    try installNativeMethods(&rt);
    try testing.expectEqual(len_before, td.method_table.len);
}
