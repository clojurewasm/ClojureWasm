// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Collections` static methods (D-526).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/sort, clojure.core/reverse, clojure.core/max, clojure.core/min
//!
//! The common static surface: `emptyList` / `singletonList` (fresh
//! java.util.ArrayList host instances — the JVM's IMMUTABLE list types are
//! deliberately not mirrored; cljw has no unmodifiable wrapper, and no cljw
//! consumer depends on the mutation-throw) / `sort` + `reverse` (in-place on
//! an ArrayList) / `max` + `min` (natural `compare` over a vector / Java
//! array / ArrayList). `unmodifiable*` / `shuffle` / `synchronized*` are
//! intentionally omitted until a real consumer needs them (dead-interop
//! lesson) — an unmodifiable view faked as a mutable list would be a lie.

const std = @import("std");
const value_sort = @import("../../collection/value_sort.zig");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const array_list_surface = @import("ArrayList.zig");
const java_array = @import("../../collection/java_array.zig");
const vector_mod = @import("../../collection/vector.zig");
const compare_mod = @import("../../compare.zig");

/// `(java.util.Collections/emptyList)` — a fresh empty ArrayList (see the
/// module doc's immutability note). JVM ref: Collections#emptyList.
fn emptyList(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Collections/emptyList", args, 0, loc);
    return array_list_surface.initArrayList(rt, env, &.{}, loc);
}

/// `(java.util.Collections/singletonList x)` — a fresh 1-element ArrayList.
fn singletonList(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Collections/singletonList", args, 1, loc);
    const vec = try vector_mod.fromSlice(rt, args[0..1]);
    return array_list_surface.initArrayList(rt, env, &.{vec}, loc);
}

fn expectArrayList(v: Value, fn_name: []const u8, loc: SourceLocation) !void {
    if (!array_list_surface.isArrayList(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a java.util.ArrayList", .actual = @tagName(v.tag()) });
}

const SortCtx = struct {
    rt: *Runtime,
    loc: SourceLocation,
    err: ?anyerror = null,
};

fn lessThan(opaque_ctx: *anyopaque, a: Value, b: Value) bool {
    const ctx: *SortCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ctx.err != null) return false;
    const ord = compare_mod.valueCompare(ctx.rt, a, b, ctx.loc) catch |e| {
        ctx.err = e;
        return false;
    };
    return ord == .lt;
}

/// `(java.util.Collections/sort list)` — IN-PLACE natural-order stable sort
/// of an ArrayList; returns nil (void in Java).
fn sortFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Collections/sort", args, 1, loc);
    try expectArrayList(args[0], "java.util.Collections/sort", loc);
    var ctx: SortCtx = .{ .rt = rt, .loc = loc };
    value_sort.sort(array_list_surface.itemsOf(args[0]), @ptrCast(&ctx), &lessThan);
    if (ctx.err) |e| return e;
    return .nil_val;
}

/// `(java.util.Collections/reverse list)` — IN-PLACE reversal of an
/// ArrayList; returns nil (void in Java).
fn reverseFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.util.Collections/reverse", args, 1, loc);
    try expectArrayList(args[0], "java.util.Collections/reverse", loc);
    std.mem.reverse(Value, array_list_surface.itemsOf(args[0]));
    return .nil_val;
}

/// The realized element slice of a vector / Java array / ArrayList arg, or
/// a type error. Vectors need a scratch copy (trie, not flat); the caller
/// frees it via `owned`.
const Elems = struct { items: []const Value, owned: ?[]Value = null };
fn elemsOf(rt: *Runtime, v: Value, fn_name: []const u8, loc: SourceLocation) !Elems {
    if (v.tag() == .vector) {
        const n = vector_mod.count(v);
        const buf = try rt.gpa.alloc(Value, n);
        var i: u32 = 0;
        while (i < n) : (i += 1) buf[i] = vector_mod.nth(v, i);
        return .{ .items = buf, .owned = buf };
    }
    if (java_array.isArray(v)) return .{ .items = java_array.asArray(v).items() };
    if (array_list_surface.isArrayList(v)) return .{ .items = array_list_surface.itemsOf(v) };
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a vector, Java array, or ArrayList", .actual = @tagName(v.tag()) });
}

fn extremum(rt: *Runtime, args: []const Value, comptime fn_name: []const u8, comptime want: std.math.Order, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(fn_name, args, 1, loc);
    const es = try elemsOf(rt, args[0], fn_name, loc);
    defer if (es.owned) |b| rt.gpa.free(b);
    if (es.items.len == 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a non-empty collection", .actual = "empty collection" });
    var best = es.items[0];
    for (es.items[1..]) |e| {
        if (try compare_mod.valueCompare(rt, e, best, loc) == want) best = e;
    }
    return best;
}

/// `(java.util.Collections/max coll)` — natural-order maximum.
fn maxFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return extremum(rt, args, "java.util.Collections/max", .gt, loc);
}

/// `(java.util.Collections/min coll)` — natural-order minimum.
fn minFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return extremum(rt, args, "java.util.Collections/min", .lt, loc);
}

fn initCollections(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "emptyList", &emptyList },
        .{ "singletonList", &singletonList },
        .{ "sort", &sortFn },
        .{ "reverse", &reverseFn },
        .{ "max", &maxFn },
        .{ "min", &minFn },
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
    .cljw_ns = "cljw.java.util.Collections",
    .descriptor = &descriptor,
    .init = &initCollections,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.Collections",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
