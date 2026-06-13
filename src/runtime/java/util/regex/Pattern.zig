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
//! Status: `quote` (the static literal-quoting method) is wired; the
//! remaining static surface (`compile` / `matches` + flag constants) is
//! still an empty reservation. The `runtime/regex/` impl is complete and
//! already honors `\Q…\E`, so `quote` is a pure string transform over it.

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

/// Implements `(.matcher re s)` — mint a `java.util.regex.Matcher` cursor
/// over the receiver pattern + input string (`clojure.core/re-matcher`'s body).
/// JVM reference: java.util.regex.Pattern#matcher. cw v1 tier: A.
fn matcherMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("matcher", args, 2, loc);
    return matcher_mod.fromPattern(rt, args[0], args[1], loc);
}

/// Install the `.regex`-tag native instance methods (`(.matcher re s)`).
/// Called at runtime init alongside `String.installNativeMethods` (ADR-0050
/// am1 caveat 3) — a native-tag receiver dispatches via `rt.nativeDescriptor`,
/// not this file's `___HOST_EXTENSION` static-surface descriptor.
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.regex);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "matcher"),
        .method_val = Value.initBuiltinFn(&matcherMethod),
    };
    td.method_table = entries;
}

fn initPattern(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "quote"),
        .method_val = Value.initBuiltinFn(&quote),
    };
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
    .fqcn = "cljw.java.util.regex.Pattern",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
