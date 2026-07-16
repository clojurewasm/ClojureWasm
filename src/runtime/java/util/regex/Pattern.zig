// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.regex.Pattern`.
//!
//! Backend: impl-only
//! Impl deps: regex
//! Clojure peer: clojure.core/re-pattern, clojure.core/re-find,
//!   clojure.core/re-matches, clojure.core/re-seq,
//!   clojure.core/re-groups, clojure.string/replace,
//!   clojure.string/split
//!
//! Thin wrapper over `runtime/regex/{compile,match}.zig` per
//! F-009 + ADR-0031. The Clojure-ns peer in
//! `lang/primitive/regex.zig` calls the same impl; this file is
//! the entry point for `(java.util.regex.Pattern/compile ...)`
//! and similar Java-style invocations.
//!
//! Status: static `quote` / `compile` / `matches` are wired (D-431 per-class
//! completeness); flag constants remain a reservation. Instance `.matcher` +
//! `.pattern` (source accessor) are on the `.regex` native descriptor. The
//! `runtime/regex/` impl is complete and already honors `\Q…\E`, so `quote` is
//! a pure string transform and `compile` is `re-pattern`'s `regex_value.alloc`.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const string_collection = @import("../../../collection/string.zig");
const matcher_mod = @import("Matcher.zig");
const regex_value = @import("../../../regex/value.zig");
const regex_replace = @import("../../../regex/replace.zig");
const regex_match = @import("../../../regex/match.zig");
const compile_mod = @import("../../../regex/compile.zig");

/// Implements `(java.util.regex.Pattern/quote s)`.
/// Spec: returns a literal-pattern string — `s` wrapped in `\Q…\E` so every
/// regex metacharacter in `s` is matched literally. An embedded `\E` is split
/// per the JVM (`\E\\E\Q`) so it cannot prematurely close the quoted region.
/// JVM reference: java.util.regex.Pattern#quote. cw v1 tier: A.
fn quote(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.regex.Pattern/quote", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "java.util.regex.Pattern/quote",
            .expected = "string",
            .actual = @tagName(args[0].tag()),
        });
    const s = string_collection.asString(args[0]);
    const gpa = rt.gc.infra;
    // Common case: no embedded `\E` → a plain `\Q` + s + `\E`.
    if (std.mem.find(u8, s, "\\E") == null) {
        const buf = try gpa.alloc(u8, s.len + 4);
        defer gpa.free(buf);
        @memcpy(buf[0..2], "\\Q");
        @memcpy(buf[2 .. 2 + s.len], s);
        @memcpy(buf[2 + s.len ..], "\\E");
        return string_collection.alloc(rt, buf);
    }
    // Rare case: each embedded `\E` becomes `\E\\E\Q` so the literal region is
    // closed, the backslash-E emitted literally, then re-opened (JVM idiom).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "\\Q");
    var current: usize = 0;
    while (std.mem.findPos(u8, s, current, "\\E")) |idx| {
        try out.appendSlice(gpa, s[current..idx]);
        try out.appendSlice(gpa, "\\E\\\\E\\Q");
        current = idx + 2;
    }
    try out.appendSlice(gpa, s[current..]);
    try out.appendSlice(gpa, "\\E");
    return string_collection.alloc(rt, out.items);
}

/// Implements `(java.util.regex.Pattern/compile s)` — compile a pattern source
/// into a regex value. Identical semantics to `clojure.core/re-pattern` (shares
/// `regex_value.alloc`); an already-compiled regex passes through. JVM ref:
/// java.util.regex.Pattern#compile. cw v1 tier: A.
fn compile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.regex.Pattern/compile", args, 1, loc);
    if (args[0].tag() == .regex) return args[0];
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "java.util.regex.Pattern/compile",
            .expected = "string",
            .actual = @tagName(args[0].tag()),
        });
    return regex_value.alloc(rt, string_collection.asString(args[0]), .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PatternTooLarge => error_catalog.raise(.regex_pattern_too_large, loc, .{}),
        else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "java.util.regex.Pattern/compile (unsupported pattern syntax)" }),
    };
}

/// Implements `(java.util.regex.Pattern/matches regex input)` — whether `input`
/// matches the pattern string `regex` in FULL (anchored both ends), the static
/// convenience form of `Pattern.compile(regex).matcher(input).matches()`. JVM
/// ref: java.util.regex.Pattern#matches. cw v1 tier: A.
fn matches(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.regex.Pattern/matches", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.util.regex.Pattern/matches", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.util.regex.Pattern/matches", .actual = @tagName(args[1].tag()) });
    var program = compile_mod.compile(rt.gpa, string_collection.asString(args[0]), .{}) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "java.util.regex.Pattern/matches (invalid regex pattern)" });
    defer program.deinit(rt.gpa);
    const m = regex_match.matchFull(rt.gpa, &program, string_collection.asString(args[1])) catch
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "java.util.regex.Pattern/matches" });
    return Value.initBoolean(m != null);
}

/// Implements `(.matcher re s)` — mint a `java.util.regex.Matcher` cursor
/// over the receiver pattern + input string (`clojure.core/re-matcher`'s body).
/// JVM reference: java.util.regex.Pattern#matcher. cw v1 tier: A.
fn matcherMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("matcher", args, 2, loc);
    return matcher_mod.fromPattern(rt, args[0], args[1], loc);
}

/// Implements `(.pattern re)` — the pattern source string the regex was
/// compiled from (e.g. `#"\d+"` → `"\\d+"`). Also Java `Pattern.toString()`.
/// JVM reference: java.util.regex.Pattern#pattern. cw v1 tier: A.
fn patternMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("pattern", args, 1, loc);
    if (args[0].tag() != .regex)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "pattern", .expected = "regex", .actual = @tagName(args[0].tag()) });
    return string_collection.alloc(rt, regex_value.asRegex(args[0]).source());
}

/// Implements `(.split re s)` / `(.split re s limit)` — Java
/// `Pattern.split(CharSequence[, int])`. Delegates to the shared neutral
/// split leaf (the same one behind `clojure.string/split`, F-009), which
/// already carries the JVM limit semantics (0 strips trailing empties).
/// JVM reference: java.util.regex.Pattern#split. cw v1 tier: A.
fn splitMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "split", .got = args.len, .min = 2, .max = 3 });
    if (args[0].tag() != .regex)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "split", .expected = "regex", .actual = @tagName(args[0].tag()) });
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "split", .actual = @tagName(args[1].tag()) });
    const limit: i64 = if (args.len == 3) blk: {
        if (args[2].tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "split", .expected = "integer limit", .actual = @tagName(args[2].tag()) });
        break :blk args[2].asInteger();
    } else 0;
    return regex_replace.splitToVector(rt, regex_value.asRegex(args[0]).program, string_collection.asString(args[1]), limit);
}

/// Install the `.regex`-tag native instance methods (`(.matcher re s)`).
/// Called at runtime init alongside `String.installNativeMethods` (ADR-0050
/// am1 caveat 3) — a native-tag receiver dispatches via `rt.nativeDescriptor`,
/// not this file's `___HOST_EXTENSION` static-surface descriptor.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.regex);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "matcher", &matcherMethod },
        .{ "pattern", &patternMethod },
        .{ "split", &splitMethod },
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

fn initPattern(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "quote", &quote },
        .{ "compile", &compile },
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

/// `___HOST_EXTENSION` declaration scanned by the host aggregator
/// (`runtime/java/_host_api.zig::installAll`, Phase 14 row 14.1).
/// `init` is null because there is no per-Runtime setup beyond
/// descriptor registration; the pattern compile cache lives in
/// `runtime/regex/compile.zig` (or a future `runtime/regex/cache.zig`
/// per D-052 Alt-3 promotion).
pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.regex.Pattern",
    .descriptor = &descriptor,
    .init = &initPattern,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.regex.Pattern",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
