// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.StringBuilder` — a mutable growable byte buffer
//! (ADR-0106 host_instance container). Landed to unblock hiccup, whose compiler
//! builds HTML with `(let [sb (StringBuilder.)] (.append sb …) (.toString sb))`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none.
//!
//! The instance is a `.host_instance` whose state[0] holds a pointer to a
//! gc.infra-allocated `std.ArrayList(u8)`. `.append` str-ifies its argument
//! through `print.writeStrValue` (so it matches `(str x)` / Java
//! String.valueOf) and grows the buffer; the descriptor's `host_finalise` hook
//! frees the buffer + the list struct when the instance is swept.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const string_collection = @import("../../collection/string.zig");
const print_mod = @import("../../print.zig");

const ByteList = std.ArrayList(u8);

var sb_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn listOf(recv: Value) *ByteList {
    return @ptrFromInt(host_instance.asHostInstance(recv).state[0]);
}

/// Append `v`'s `str`-rendering to `lp`. Shared by `<init>` (1-arg) and append.
fn appendStr(rt: *Runtime, env: *Env, lp: *ByteList, v: Value) !void {
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try print_mod.writeStrValue(rt, env, &aw.writer, v);
    try lp.appendSlice(rt.gc.infra, aw.writer.buffered());
}

/// `(StringBuilder.)` / `(StringBuilder. "seed")` / `(StringBuilder. n)` —
/// a 1-arg integer is the JVM int-capacity ctor (a hint; cljw's buffer grows
/// on demand, so it is accepted and ignored — NOT seeded as "n"); any other
/// 1-arg value seeds the buffer with its str-form.
fn initSb(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.lang.StringBuilder.", .expected = 1 });
    const lp = try rt.gc.infra.create(ByteList);
    lp.* = .empty;
    if (args.len == 1 and args[0].tag() != .integer) try appendStr(rt, env, lp, args[0]);
    const td = sb_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromPtr(lp), 0, 0, 0 });
}

/// `(.append sb x)` — append `x`'s str-form; returns the builder (Java chains).
/// `(.append sb s start end)` — the JVM CharSequence sub-range arity: append
/// the `[start, end)` codepoint slice of `s`'s str-form (instaparse's
/// Segment.toString drives this arm).
fn append(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len == 2) {
        try appendStr(rt, env, listOf(args[0]), args[1]);
        return args[0];
    }
    if (args.len != 4)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = ".append", .got = args.len, .min = 2, .max = 4 });
    if (args[2].tag() != .integer or args[3].tag() != .integer)
        return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = ".append", .actual = @tagName(if (args[2].tag() != .integer) args[2].tag() else args[3].tag()) });
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try print_mod.writeStrValue(rt, env, &aw.writer, args[1]);
    const s = aw.writer.buffered();
    const from_i = args[2].asInteger();
    const to_i = args[3].asInteger();
    const from = byteOffsetOfCodepoint(s, from_i);
    const to = byteOffsetOfCodepoint(s, to_i);
    if (from_i < 0 or to_i < from_i or from == null or to == null)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "java.lang.StringBuilder/append" });
    try listOf(args[0]).appendSlice(rt.gc.infra, s[from.?..to.?]);
    return args[0];
}

/// Byte offset of codepoint index `i` in `s` (s.len when `i` == codepoint
/// count); null when `i` is negative or past the end.
fn byteOffsetOfCodepoint(s: []const u8, i: i64) ?usize {
    if (i < 0) return null;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var n: i64 = 0;
    while (n < i) : (n += 1) {
        if (it.nextCodepointSlice() == null) return null;
    }
    return it.i;
}

/// `(.toString sb)` / `(str sb)` — the accumulated bytes as a cljw String.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    return string_collection.alloc(rt, listOf(args[0]).items);
}

/// `(.length sb)` — byte length of the buffer.
fn length(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("length", args, 1, loc);
    return Value.initInteger(@intCast(listOf(args[0]).items.len));
}

fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const lp: *ByteList = @ptrFromInt(state[0]);
    lp.deinit(infra);
    infra.destroy(lp);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initSb },
    .{ .name = "append", .f = &append },
    .{ .name = "toString", .f = &toString },
    .{ .name = "length", .f = &length },
};

fn initSbDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    sb_descriptor = td;
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
    .cljw_ns = "cljw.java.lang.StringBuilder",
    .descriptor = &descriptor,
    .init = &initSbDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    // cljw-prefixed (like Math/System/Thread) so a BARE `(StringBuilder.)` resolves
    // via the always-on `cljw.java.lang.*` auto-import (resolveJavaSurface step 3).
    .fqcn = "cljw.java.lang.StringBuilder",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
