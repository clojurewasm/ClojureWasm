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
//! `buildMatchResult`). `re-find-all` backs `re-seq` (one-pass scan, O-035);
//! `re-find-from` is the public scan-from-offset primitive. Compile-error
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
const list_collection = @import("../../runtime/collection/list.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const regex_match = @import("../../runtime/regex/match.zig");
const compile_mod = @import("../../runtime/regex/compile.zig");
const char_sequence = @import("../../runtime/char_sequence.zig");

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
    return regex_value.alloc(rt, src, .{}) catch |err|
        regex_value.raiseCompileError(err, loc);
}

/// `(re-find re s)` — search for the first match of `re` anywhere
/// in `s`. Returns the matched substring (or the `[whole g1 …]`
/// capture vector when the pattern has groups) on success, `nil`
/// on no match.
pub fn reFind(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("__re-find", args, 2, loc);
    // The text first: see reFindAll.
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const input = try char_sequence.textArg(rt, env, args[1], "__re-find", loc, &aw);
    const r = try coerceRegex(rt, args[0], loc, "__re-find");
    const result = (try regex_match.find(rt.gpa, r.program, input)) orelse return .nil_val;
    defer result.deinit(rt.gpa);
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
    var g: usize = 1;
    while (g <= program.capture_count) : (g += 1) {
        const gv = if (result.group(g)) |span|
            try string_collection.alloc(rt, input[span.start..span.end])
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
    try error_catalog.checkArity("re-matches", args, 2, loc);
    // The text first: see reFindAll.
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const input = try char_sequence.textArg(rt, env, args[1], "re-matches", loc, &aw);
    const r = try coerceRegex(rt, args[0], loc, "re-matches");
    const result = (try regex_match.matchFull(rt.gpa, r.program, input)) orelse return .nil_val;
    defer result.deinit(rt.gpa);
    return try buildMatchResult(rt, r.program, input, result);
}

/// `(re-find-from re s start)` — like re-find but scanning from byte
/// offset `start`; returns `[match start end]` (the match string + its
/// byte span) or nil. Internal helper for `clojure.core/re-seq` (which
/// loops, advancing past each match's end).
pub fn reFindFrom(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("re-find-from", args, 3, loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const input = try char_sequence.textArg(rt, env, args[1], "re-find-from", loc, &aw);
    if (args[2].tag() != .integer) {
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "re-find-from", .actual = @tagName(args[2].tag()) });
    }
    const r = try coerceRegex(rt, args[0], loc, "re-find-from");
    const start_i = args[2].asInteger();
    if (start_i < 0 or start_i > input.len) return .nil_val;
    const result = (try regex_match.findFrom(rt.gpa, r.program, input, @intCast(start_i))) orelse return .nil_val;
    defer result.deinit(rt.gpa);
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

/// `(re-find-all re s)` — the one-pass Zig backing for `clojure.core/re-seq`.
/// Returns a seq of the successive non-overlapping match elements (each the
/// `re-find` shape: the whole-match string, or `[whole g1 …]` when the pattern
/// has groups) in order, or `nil` when there are no matches (matching the
/// `.clj` `re-seq`'s `(seq acc)` → nil on empty). Replaces re-seq's `.clj`
/// `loop/recur` over `re-find-from`: one Zig scan (reusing a single ThreadList
/// pair across all matches) instead of N `re-find-from` calls each round-
/// tripping a `[match start end]` vector through the interpreter. [O-035]
pub fn reFindAll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("re-find-all", args, 2, loc);
    // The text first: rendering a non-string CharSequence can allocate, and
    // nothing roots a regex coerceRegex compiles from a string pattern.
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const input = try char_sequence.textArg(rt, env, args[1], "re-find-all", loc, &aw);
    const r = try coerceRegex(rt, args[0], loc, "re-find-all");

    // Phase 1: collect match bounds (plain structs, no GC Values) — reuses ONE
    // ThreadList pair across the whole scan (vs re-find-from's per-call pair).
    var bounds: std.ArrayList(regex_match.MatchResult) = .empty;
    defer {
        for (bounds.items) |m| m.deinit(rt.gpa);
        bounds.deinit(rt.gpa);
    }
    try regex_match.findAll(rt.gpa, r.program, input, &bounds);
    if (bounds.items.len == 0) return .nil_val; // (seq []) → nil

    // Phase 2: build the PersistentList from the end, rooting the growing tail
    // (slot 0) + each freshly-built match value (slot 1) across the
    // buildMatchResult + consHeap allocs (the O-032 reentrant-alloc frame).
    // GC-ROOT: O-035 — [list, head] [ref: .dev/gc_rooting.md]
    var gc_roots: [2]Value = .{ .nil_val, .nil_val };
    var gc_sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;

    var list = try list_collection.emptyList(rt);
    gc_roots[0] = list;
    var i: usize = bounds.items.len;
    while (i > 0) {
        i -= 1;
        const head = try buildMatchResult(rt, r.program, input, bounds.items[i]);
        gc_roots[1] = head;
        list = try list_collection.consHeap(rt, head, list);
        gc_roots[0] = list;
    }
    return list;
}

/// Coerce a Value to `*const Regex`. Accepts an existing regex
/// Value directly, or a string (compiled on the spot — matches
/// JVM `Pattern.compile` flexibility). Other types raise a
/// type error.
fn coerceRegex(rt: *Runtime, v: Value, loc: SourceLocation, fn_name: []const u8) anyerror!*const regex_value.Regex {
    if (v.tag() == .regex) return regex_value.asRegex(v);
    if (v.tag() == .string) {
        const src = string_collection.asString(v);
        const compiled = regex_value.alloc(rt, src, .{}) catch |err|
            return regex_value.raiseCompileError(err, loc);
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
    .{ .name = "__re-find", .f = &reFind },
    .{ .name = "re-matches", .f = &reMatches },
    .{ .name = "re-find-from", .f = &reFindFrom },
    .{ .name = "re-find-all", .f = &reFindAll },
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

    // D-413: init in place — env.rt / rt.io self-references require a stable
    // address, so the fixture must be built at its final address and never
    // moved by value (a return-by-value init leaves env.rt dangling).
    fn init(f: *Fixture) !void {
        f.threaded = std.Io.Threaded.init(testing.allocator, .{});
        f.rt = Runtime.init(f.threaded.io(), testing.allocator);
        f.env = try Env.init(&f.rt);
    }
    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "re-pattern compiles a string into a .regex Value" {
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
    defer fx.deinit();
    const src = try string_collection.alloc(&fx.rt, "\\d+");
    const result = try rePattern(&fx.rt, &fx.env, &[_]Value{src}, .{});
    try testing.expect(result.tag() == .regex);
}

test "re-pattern on an existing regex returns it unchanged" {
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "a", .{});
    const result = try rePattern(&fx.rt, &fx.env, &[_]Value{re}, .{});
    try testing.expectEqual(re, result);
}

test "ADR-0031 Phase 6.6 exit smoke (primitive level): re-find re \"abc123\" → \"123\"" {
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "\\d+", .{});
    const input = try string_collection.alloc(&fx.rt, "abc123");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ re, input }, .{});
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("123", string_collection.asString(result));
}

test "re-find returns nil on no match" {
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
    defer fx.deinit();
    const re = try regex_value.alloc(&fx.rt, "z", .{});
    const input = try string_collection.alloc(&fx.rt, "abc");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ re, input }, .{});
    try testing.expect(result.isNil());
}

test "re-matches succeeds on exact match, nil on prefix-only" {
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
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
    var fx: Fixture = undefined;
    try Fixture.init(&fx);
    defer fx.deinit();
    const pat = try string_collection.alloc(&fx.rt, "\\w+");
    const input = try string_collection.alloc(&fx.rt, " hello ");
    const result = try reFind(&fx.rt, &fx.env, &[_]Value{ pat, input }, .{});
    try testing.expect(result.tag() == .string);
    try testing.expectEqualStrings("hello", string_collection.asString(result));
}
