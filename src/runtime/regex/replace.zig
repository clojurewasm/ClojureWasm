// SPDX-License-Identifier: EPL-2.0
//! Namespace-neutral regex string-replace + split (F-009 shared impl).
//!
//! Backend: impl-only
//! Impl deps: regex
//! Clojure peer: clojure.string/replace, clojure.string/split
//!
//! The string-template replace loop (`$N` backref / `\c` escape, JVM
//! `Matcher.appendReplacement` semantics) and the regex split loop live
//! here so they can be shared between the Clojure-ns surface
//! (`clojure.string/replace` / `split` in `lang/primitive/string.zig`)
//! and the Java surface (`java.lang.String.replaceAll` / `replaceFirst`
//! / `split` in `runtime/java/lang/String.zig`) per F-009 — `runtime/`
//! may not import `lang/`, so the body cannot live in the Layer-2
//! primitives file. The fn-replacement arm of `clojure.string/replace`
//! stays in Layer 2: it calls back into the interpreter via the vtable,
//! which a neutral leaf does not own.

const std = @import("std");
const compile = @import("compile.zig");
const regex_match = @import("match.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Value = @import("../value/value.zig").Value;
const string_collection = @import("../collection/string.zig");
const vector_collection = @import("../collection/vector.zig");

pub const ReplaceKind = enum { all, first };

/// Expand a string replacement template against `match`, JVM
/// `Matcher.appendReplacement`-style: `$N` (single digit) is group N's
/// text (`$0` = the whole match; a non-participating group contributes
/// nothing), `\c` emits `c` literally, everything else is copied
/// verbatim (D-093).
pub fn expandReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u8),
    template: []const u8,
    match: regex_match.MatchResult,
    program: *const compile.Program,
    haystack: []const u8,
) anyerror!void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '\\' and i + 1 < template.len) {
            try out.append(rt.gc.infra, template[i + 1]);
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < template.len and template[i + 1] >= '0' and template[i + 1] <= '9') {
            const g: u16 = template[i + 1] - '0';
            i += 2;
            if (g == 0) {
                try out.appendSlice(rt.gc.infra, haystack[match.start..match.end]);
            } else if (g <= program.capture_count) {
                const s = match.captures.slots[@as(usize, 2) * g];
                const e = match.captures.slots[@as(usize, 2) * g + 1];
                if (s >= 0 and e >= 0) try out.appendSlice(rt.gc.infra, haystack[@intCast(s)..@intCast(e)]);
            }
            continue;
        }
        try out.append(rt.gc.infra, c);
        i += 1;
    }
}

/// String-template regex replace over `haystack`, returning the result
/// string Value. `kind == .first` stops after the first match. Shared
/// by `clojure.string/replace` (string-replacement arm) and the Java
/// `.replaceAll` / `.replaceFirst` String methods. The interpreter
/// fn-replacement arm is NOT here — it needs the vtable (Layer 2).
pub fn replaceString(
    rt: *Runtime,
    program: *const compile.Program,
    haystack: []const u8,
    template: []const u8,
    kind: ReplaceKind,
) anyerror!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gc.infra);
    var pos: u32 = 0;
    while (pos <= haystack.len) {
        const match = (try regex_match.findFrom(rt.gc.infra, program, haystack, pos)) orelse break;
        try out.appendSlice(rt.gc.infra, haystack[pos..match.start]);
        try expandReplacement(rt, &out, template, match, program, haystack);
        // Advance past the match. An empty match advances by one byte to
        // avoid an infinite loop (mirrors JVM `Matcher.replaceAll` on `""`).
        pos = if (match.end > match.start) match.end else match.start + 1;
        if (kind == .first) break;
    }
    if (pos <= haystack.len) try out.appendSlice(rt.gc.infra, haystack[pos..]);
    return try string_collection.alloc(rt, out.items);
}

/// Regex split of `haystack` into a vector of substrings, matching
/// `Pattern.split` / `clojure.string/split` semantics:
///   - `limit > 0`: at most `limit` parts; the unmatched remainder is last.
///   - `limit == 0` (default): unlimited parts, trailing empty strings removed.
///   - `limit < 0`: unlimited parts, trailing empties kept.
/// Empty input yields `[""]`. A no-match input returns `[haystack]`
/// (single element, never stripped — JVM's `index == 0` short-circuit).
/// Zero-width matches advance by one byte to guarantee termination.
pub fn splitToVector(
    rt: *Runtime,
    program: *const compile.Program,
    haystack: []const u8,
    limit: i64,
) anyerror!Value {
    var parts: std.ArrayList(Value) = .empty;
    defer parts.deinit(rt.gpa);

    if (haystack.len == 0) {
        try parts.append(rt.gpa, try string_collection.alloc(rt, ""));
    } else {
        // JVM `Pattern.split`: a piece spans `[index .. match.start]` where
        // `index` is the PREVIOUS match's end (NOT the search cursor). For a
        // zero-width match the cursor advances one codepoint to make progress,
        // but the piece boundary stays at the match positions — so
        // `(split "abc" #"")` → `["a" "b" "c"]`, not empties. A zero-width
        // match at the very start (index 0) yields no leading empty. The
        // remainder `[index ..]` is appended once after the loop.
        var index: u32 = 0; // start of the current piece (prev match end)
        var cursor: u32 = 0; // next search position
        var nsplits: i64 = 0;
        var matched = false;
        while (true) {
            if (limit > 0 and nsplits >= limit - 1) break;
            const match = (try regex_match.findFrom(rt.gpa, program, haystack, cursor)) orelse break;
            if (index == 0 and match.start == 0 and match.end == 0) {
                if (match.end >= haystack.len) break;
                cursor = match.end + 1;
                continue;
            }
            matched = true;
            nsplits += 1;
            try parts.append(rt.gpa, try string_collection.alloc(rt, haystack[index..match.start]));
            index = match.end;
            if (match.end == match.start) {
                if (match.end >= haystack.len) break;
                cursor = match.end + 1;
            } else {
                cursor = match.end;
            }
        }
        try parts.append(rt.gpa, try string_collection.alloc(rt, haystack[index..]));
        // limit == 0: strip trailing empty strings, but only once a match was
        // consumed (a no-match `[haystack]` keeps its single element).
        if (limit == 0 and matched) {
            while (parts.items.len > 0 and
                string_collection.asString(parts.items[parts.items.len - 1]).len == 0)
            {
                _ = parts.pop();
            }
        }
    }

    var result = vector_collection.empty();
    for (parts.items) |p| result = try vector_collection.conj(rt, result, p);
    return result;
}

// --- tests ---

const testing = std.testing;

test "replaceString global + first + backref" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    var prog = try compile.compile(rt.gc.infra, "[0-9]", .{});
    defer prog.deinit(rt.gc.infra);
    const all = try replaceString(&rt, &prog, "a1b2", "X", .all);
    try testing.expectEqualStrings("aXbX", string_collection.asString(all));
    const first = try replaceString(&rt, &prog, "a1b2", "X", .first);
    try testing.expectEqualStrings("aXb2", string_collection.asString(first));

    var grp = try compile.compile(rt.gc.infra, "(.)", .{});
    defer grp.deinit(rt.gc.infra);
    const dup = try replaceString(&rt, &grp, "abc", "$1$1", .all);
    try testing.expectEqualStrings("aabbcc", string_collection.asString(dup));
}

test "splitToVector strips trailing empties at limit 0" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();

    var prog = try compile.compile(rt.gc.infra, ",", .{});
    defer prog.deinit(rt.gc.infra);
    const v = try splitToVector(&rt, &prog, "a,b,,", 0);
    try testing.expectEqual(@as(u32, 2), vector_collection.count(v));
}
