// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.regex.Matcher` — a stateful match cursor over
//! a compiled regex + input string (ADR-0106 host_instance container). Minted
//! by `(.matcher re s)` (Pattern's instance method backing
//! `clojure.core/re-matcher`); landed to unblock instaparse, whose
//! `re-match-at-front` drives `(.lookingAt m)` + `(.group m)`.
//!
//! Backend: impl-only
//! Impl deps: regex
//! Clojure peer: clojure.core/re-matcher, clojure.core/re-groups,
//!   clojure.core/re-find (matcher 1-arity)
//!
//! state[0] = the regex Value, state[1] = the input string Value (both GC-
//! marked via `host_trace` — the Iterator precedent), state[2] = *MutState on
//! gc.infra (freed by `host_finalise` — the StringBuilder precedent). Match
//! spans are byte offsets internally; `.start`/`.end` convert to codepoint
//! indices (the cljw string-index convention; JVM reports UTF-16 char
//! indices, identical for BMP-only input).

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const host_instance = @import("../../../host_instance.zig");
const string_collection = @import("../../../collection/string.zig");
const charset = @import("../../../charset.zig");
const regex_value = @import("../../../regex/value.zig");
const regex_match = @import("../../../regex/match.zig");
const compile_mod = @import("../../../regex/compile.zig");
const mark_sweep = @import("../../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../../gc/gc_heap.zig");

var matcher_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// Mutable cursor state, allocated on `gc.infra` (freed by the descriptor's
/// `host_finalise`). All spans are byte offsets into the input.
const MutState = struct {
    /// Where the next `.find` starts scanning. Advanced past the previous
    /// match on success (one extra codepoint after an empty match, the JVM
    /// no-infinite-loop rule); pushed past `input.len` on a failed `.find`
    /// so repeated finds keep returning false (JVM parity).
    pos: u32 = 0,
    /// Whether the last match op succeeded (`group`/`start`/`end` legal).
    found: bool = false,
    /// Last successful match span (group 0).
    start: u32 = 0,
    end: u32 = 0,
    /// Capture-slot snapshot of the last successful match (2 per group).
    slots: [regex_match.MAX_SLOTS_INLINE]i32 = [_]i32{-1} ** regex_match.MAX_SLOTS_INLINE,
};

fn stateOf(recv: Value) *MutState {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[2]);
}

fn inputOf(recv: Value) []const u8 {
    return string_collection.asString(@enumFromInt(host_instance.asHostInstance(recv).state[1]));
}

fn programOf(recv: Value) *const compile_mod.Program {
    return regex_value.asRegex(@enumFromInt(host_instance.asHostInstance(recv).state[0])).program;
}

/// Mint a Matcher over `re` + `s`. Called from Pattern's `matcher` instance
/// method (the `(.matcher re s)` / `re-matcher` producer).
pub fn fromPattern(rt: *Runtime, re: Value, s: Value, loc: SourceLocation) anyerror!Value {
    if (s.tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "java.util.regex.Pattern/matcher",
            .actual = @tagName(s.tag()),
        });
    const ms = try rt.gc.infra.create(MutState);
    errdefer rt.gc.infra.destroy(ms);
    ms.* = .{};
    const td = matcher_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(re), @intFromEnum(s), @intFromPtr(ms), 0 });
}

/// Where the find after a successful match resumes: match end, plus one
/// codepoint when the match was empty (JVM rule, prevents `a*` looping).
fn nextFindPos(input: []const u8, r: regex_match.MatchResult) u32 {
    if (r.end > r.start) return r.end;
    if (r.end >= input.len) return @intCast(input.len + 1);
    const len = std.unicode.utf8ByteSequenceLength(input[r.end]) catch 1;
    return r.end + len;
}

fn record(ms: *MutState, input: []const u8, r: regex_match.MatchResult) void {
    ms.found = true;
    ms.start = r.start;
    ms.end = r.end;
    ms.slots = r.captures.slots;
    ms.pos = nextFindPos(input, r);
}

/// `(.find m)` — scan for the next match from the cursor position.
fn find(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("find", args, 1, loc);
    const ms = stateOf(args[0]);
    const input = inputOf(args[0]);
    if (ms.pos <= input.len) {
        if (try regex_match.findFrom(rt.gpa, programOf(args[0]), input, ms.pos)) |r| {
            record(ms, input, r);
            return Value.initBoolean(true);
        }
    }
    ms.found = false;
    ms.pos = @intCast(input.len + 1);
    return Value.initBoolean(false);
}

/// `(.lookingAt m)` — true iff the pattern matches a prefix of the input
/// (anchored at 0, not necessarily the whole input). A failure does not
/// move the find cursor (JVM parity).
fn lookingAt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("lookingAt", args, 1, loc);
    const ms = stateOf(args[0]);
    const input = inputOf(args[0]);
    // The Pike VM returns the leftmost match; lookingAt holds iff it starts at 0.
    if (try regex_match.findFrom(rt.gpa, programOf(args[0]), input, 0)) |r| {
        if (r.start == 0) {
            record(ms, input, r);
            return Value.initBoolean(true);
        }
    }
    ms.found = false;
    return Value.initBoolean(false);
}

/// `(.matches m)` — true iff the pattern matches the ENTIRE input.
fn matches(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("matches", args, 1, loc);
    const ms = stateOf(args[0]);
    const input = inputOf(args[0]);
    if (try regex_match.matchFull(rt.gpa, programOf(args[0]), input)) |r| {
        record(ms, input, r);
        return Value.initBoolean(true);
    }
    ms.found = false;
    return Value.initBoolean(false);
}

/// `(.group m)` / `(.group m n)` — the last match (n = 0) or capture group n
/// of it (nil when the group did not participate). Raises when no match op
/// has succeeded (JVM IllegalStateException "No match found").
fn group(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".group", .got = args.len, .min = 1, .max = 2 });
    const ms = stateOf(args[0]);
    if (!ms.found) return error_catalog.raise(.matcher_not_matched, loc, .{});
    const input = inputOf(args[0]);
    if (args.len == 1)
        return string_collection.alloc(rt, input[ms.start..ms.end]);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = ".group", .actual = @tagName(args[1].tag()) });
    const n = args[1].asInteger();
    if (n == 0) return string_collection.alloc(rt, input[ms.start..ms.end]);
    if (n < 0 or n > programOf(args[0]).capture_count)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.util.regex.Matcher/group" });
    const s = ms.slots[@intCast(2 * n)];
    const e = ms.slots[@intCast(2 * n + 1)];
    if (s < 0 or e < 0) return Value.nil_val;
    return string_collection.alloc(rt, input[@intCast(s)..@intCast(e)]);
}

/// `(.groupCount m)` — number of capturing groups in the pattern.
fn groupCount(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("groupCount", args, 1, loc);
    return Value.initInteger(@intCast(programOf(args[0]).capture_count));
}

/// `(.start m)` — codepoint index of the last match's start.
fn startIndex(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("start", args, 1, loc);
    const ms = stateOf(args[0]);
    if (!ms.found) return error_catalog.raise(.matcher_not_matched, loc, .{});
    return Value.initInteger(@intCast(try charset.codepointCount(inputOf(args[0])[0..ms.start])));
}

/// `(.end m)` — codepoint index one past the last match's end.
fn endIndex(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("end", args, 1, loc);
    const ms = stateOf(args[0]);
    if (!ms.found) return error_catalog.raise(.matcher_not_matched, loc, .{});
    return Value.initInteger(@intCast(try charset.codepointCount(inputOf(args[0])[0..ms.end])));
}

/// `(.reset m)` — rewind the cursor to the input start; returns the matcher.
fn reset(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("reset", args, 1, loc);
    stateOf(args[0]).* = .{};
    return args[0];
}

/// GC-trace the regex (state[0]) + input string (state[1]) Values held in raw
/// `u64` slots. Decode goes through `heapHeader` (the G1 membrane), so an
/// immediate is correctly skipped.
/// GC-ROOT: §H — raw-slot Values the field-walker can't see; a future moving
/// GC must RELOCATE here, not just mark [ref: .dev/gc_rooting.md §H, debt D-318].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    inline for (.{ 0, 1 }) |i| {
        const v: Value = @enumFromInt(state[i]);
        if (v.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const ms: *MutState = @ptrFromInt(state[2]);
    infra.destroy(ms);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "find", .f = &find },
    .{ .name = "lookingAt", .f = &lookingAt },
    .{ .name = "matches", .f = &matches },
    .{ .name = "group", .f = &group },
    .{ .name = "groupCount", .f = &groupCount },
    .{ .name = "start", .f = &startIndex },
    .{ .name = "end", .f = &endIndex },
    .{ .name = "reset", .f = &reset },
};

fn initMatcherDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    matcher_descriptor = td;
    td.host_trace = &traceState;
    td.host_finalise = &finaliseState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.regex.Matcher",
    .descriptor = &descriptor,
    .init = &initMatcherDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.regex.Matcher",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
