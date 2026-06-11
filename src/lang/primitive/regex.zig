// SPDX-License-Identifier: EPL-2.0
//! Regex primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! Implements clojure.core/`re-pattern`, `re-find`, `re-matches`
//! against the namespace-neutral implementation in
//! `runtime/regex/{compile,match,value}.zig` per F-009. The same
//! impl is shared with the Java surface in
//! `runtime/java/util/regex/Pattern.zig` (Phase 7 dispatch ABI
//! routes `(java.util.regex.Pattern/compile s)` through this
//! file's `re-pattern` body once method-table dispatch lands).
//!
//! `re-find` / `re-matches` return the whole-match `String` for a
//! group-less pattern and the `[whole g1 g2 …]` capture vector when
//! the pattern has capturing groups (Pike-VM slot arrays via
//! `buildMatchResult`). `re-find-from` backs `re-seq`. Compile-error
//! message fidelity (a `PatternSyntaxException`-aligned rendering) is
//! still a gap — unsupported syntax raises `feature_not_supported`
//! (D-051).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const regex_match = @import("../../runtime/regex/match.zig");
const compile_mod = @import("../../runtime/regex/compile.zig");

// Pulls runtime/regex/{compile,match}.zig into the compile + test
// graph. value.zig is referenced directly via regex_value above;
// match.zig via regex_match; compile.zig comes transitively.
pub const _regex_compile = @import("../../runtime/regex/compile.zig");
pub const _regex_match = @import("../../runtime/regex/match.zig");

/// `(re-pattern s)` — compile a pattern source string into a
/// regex Value. Mirrors `clojure.core/re-pattern`. Unsupported
/// syntax raises `feature_not_supported`; a `PatternSyntaxException`-
/// aligned compile-error rendering is still a gap (D-051).
pub fn rePattern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("re-pattern", args, 1, loc);
    // `(re-pattern r)` where r is already a regex returns it unchanged.
    if (args[0].tag() == .regex) return args[0];
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "re-pattern",
            .actual = @tagName(args[0].tag()),
        });
    }
    const src = string_collection.asString(args[0]);
    return regex_value.alloc(rt, src, .{}) catch |err| switch (err) {
        error.OutOfMemory => err,
        // INV-1: a nested-counted-repetition compile-bomb is a catchable error,
        // not an OOM / process kill.
        error.PatternTooLarge => error_catalog.raise(.regex_pattern_too_large, loc, .{}),
        else => error_catalog.raise(.feature_not_supported, loc, .{
            .name = "re-pattern (unsupported syntax in cycle 1)",
        }),
    };
}

/// `(re-find re s)` — search for the first match of `re` anywhere
/// in `s`. Returns the matched substring (or the `[whole g1 …]`
/// capture vector when the pattern has groups) on success, `nil`
/// on no match.
pub fn reFind(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("re-find", args, 2, loc);
    const r = try coerceRegex(rt, args[0], loc, "re-find");
    if (args[1].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "re-find",
            .actual = @tagName(args[1].tag()),
        });
    }
    const input = string_collection.asString(args[1]);
    const result = (try regex_match.find(rt.gpa, r.program, input)) orelse return .nil_val;
    return try buildMatchResult(rt, r.program, input, result);
}

/// Shape a match into the JVM `re-find`/`re-matches` return: the whole-match
/// string when the pattern has no capturing groups, else a vector
/// `[whole g1 g2 …]` (a group that did not participate is nil). Group 0 is the
/// whole match (`result.start..end`); group `i` is `captures.slots[2i..2i+1]`.
pub fn buildMatchResult(rt: *Runtime, program: *const compile_mod.Program, input: []const u8, result: regex_match.MatchResult) anyerror!Value {
    if (program.capture_count == 0) {
        return string_collection.alloc(rt, input[result.start..result.end]);
    }
    var vec = vector_collection.empty();
    vec = try vector_collection.conj(rt, vec, try string_collection.alloc(rt, input[result.start..result.end]));
    var g: u16 = 1;
    while (g <= program.capture_count) : (g += 1) {
        const s = result.captures.slots[@as(usize, 2) * g];
        const e = result.captures.slots[@as(usize, 2) * g + 1];
        const gv = if (s >= 0 and e >= 0)
            try string_collection.alloc(rt, input[@intCast(s)..@intCast(e)])
        else
            Value.nil_val;
        vec = try vector_collection.conj(rt, vec, gv);
    }
    return vec;
}

/// `(re-matches re s)` — succeeds iff `re` matches the entire
/// input string. Returns the input string (or the `[whole g1 …]`
/// capture vector when the pattern has groups) on full-match,
/// `nil` otherwise.
pub fn reMatches(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("re-matches", args, 2, loc);
    const r = try coerceRegex(rt, args[0], loc, "re-matches");
    if (args[1].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "re-matches",
            .actual = @tagName(args[1].tag()),
        });
    }
    const input = string_collection.asString(args[1]);
    const result = (try regex_match.matchFull(rt.gpa, r.program, input)) orelse return .nil_val;
    return try buildMatchResult(rt, r.program, input, result);
}

/// `(re-find-from re s start)` — like re-find but scanning from byte
/// offset `start`; returns `[match start end]` (the match string + its
/// byte span) or nil. Internal helper for `clojure.core/re-seq` (which
/// loops, advancing past each match's end).
pub fn reFindFrom(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("re-find-from", args, 3, loc);
    const r = try coerceRegex(rt, args[0], loc, "re-find-from");
    if (args[1].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "re-find-from", .actual = @tagName(args[1].tag()) });
    }
    if (args[2].tag() != .integer) {
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "re-find-from", .actual = @tagName(args[2].tag()) });
    }
    const input = string_collection.asString(args[1]);
    const start_i = args[2].asInteger();
    if (start_i < 0 or start_i > input.len) return .nil_val;
    const result = (try regex_match.findFrom(rt.gpa, r.program, input, @intCast(start_i))) orelse return .nil_val;
    // PERF: D-386 (O-024) build `[match start end]` in ONE `fromSlice` alloc, not
    // three persistent-vector `conj` copies (re-seq calls this per match ×10000;
    // the 3-conj churn dominated regex_count's malloc profile). The match element
    // is the `re-find` shape (group vector / whole-match string); start/end advance
    // the re-seq loop. [refs: O-024]
    const match_val = try buildMatchResult(rt, r.program, input, result);
    return try vector_collection.fromSlice(rt, &.{
        match_val,
        Value.initInteger(@intCast(result.start)),
        Value.initInteger(@intCast(result.end)),
    });
}

/// Coerce a Value to `*const Regex`. Accepts an existing regex
/// Value directly, or a string (compiled on the spot — matches
/// JVM `Pattern.compile` flexibility). Other types raise a
/// type error.
fn coerceRegex(rt: *Runtime, v: Value, loc: SourceLocation, fn_name: []const u8) anyerror!*const regex_value.Regex {
    if (v.tag() == .regex) return regex_value.asRegex(v);
    if (v.tag() == .string) {
        const src = string_collection.asString(v);
        const compiled = regex_value.alloc(rt, src, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // INV-1: compile-bomb pattern is a catchable error, not an OOM.
            error.PatternTooLarge => return error_catalog.raise(.regex_pattern_too_large, loc, .{}),
            else => return error_catalog.raise(.feature_not_supported, loc, .{
                .name = "re-find / re-matches with invalid pattern (cycle 1)",
            }),
        };
        return regex_value.asRegex(compiled);
    }
    return error_catalog.raise(.type_arg_not_string, loc, .{
        .fn_name = fn_name,
        .actual = @tagName(v.tag()),
    });
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "re-pattern", .f = &rePattern },
    .{ .name = "re-find", .f = &reFind },
    .{ .name = "re-matches", .f = &reMatches },
    .{ .name = "re-find-from", .f = &reFindFrom },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// Zig 0.16 analyses decls lazily — an unreferenced `pub const X
// = @import(...)` does not pull X's test blocks into the
// discovery set. The refAllDecls calls below force analysis of
// every decl in compile.zig and match.zig so their unit tests
// run as part of `zig build test`. See zig_tips.md.
test {
    @import("std").testing.refAllDecls(_regex_compile);
    @import("std").testing.refAllDecls(_regex_match);
}

// --- primitive smoke tests ---

const std = @import("std");
const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init() !Fixture {
        var f: Fixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
            .env = undefined,
        };
        f.rt = Runtime.init(f.threaded.io(), testing.allocator);
        f.env = try Env.init(&f.rt);
        return f;
    }
    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "re-pattern compiles a string into a .regex Value" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const src = try string_collection.alloc(&fx.rt, "\\d+");
    const result = try rePattern(&fx.rt, &fx.env, &[_]Value{src}, .{});
    try testing.expect(result.tag() == .regex);
}

test "re-pattern on an existing regex returns it unchanged" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "a", .{});
    const result = try rePattern(&fx.rt, &fx.env, &[_]Value{re}, .{});
    try testing.expectEqual(re, result);
}

test "ADR-0031 Phase 6.6 exit smoke (primitive level): re-find re \"abc123\" → \"123\"" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "\\d+", .{});
    const input = try string_collection.alloc(&fx.rt, "abc123");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ re, input }, .{});
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("123", string_collection.asString(result));
}

test "re-find returns nil on no match" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "z", .{});
    const input = try string_collection.alloc(&fx.rt, "abc");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ re, input }, .{});
    try testing.expect(result.isNil());
}

test "re-matches succeeds on exact match, nil on prefix-only" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "\\d+", .{});
    const exact = try string_collection.alloc(&fx.rt, "123");
    const r1 = try reMatches(&fx.rt, &fx.env, &[_]Value{ re, exact }, .{});
    try testing.expect(r1.tag() == .string);
    try testing.expectEqualStrings("123", string_collection.asString(r1));

    const partial = try string_collection.alloc(&fx.rt, "123abc");
    const r2 = try reMatches(&fx.rt, &fx.env, &[_]Value{ re, partial }, .{});
    try testing.expect(r2.isNil());
}

test "re-find accepts a string pattern (re-pattern coercion)" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pat = try string_collection.alloc(&fx.rt, "\\w+");
    const input = try string_collection.alloc(&fx.rt, " hello ");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ pat, input }, .{});
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("hello", string_collection.asString(result));
}
