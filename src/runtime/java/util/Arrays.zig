// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Arrays` static methods (D-526).
//!
//! Backend: impl-only
//! Impl deps: java_array
//! Clojure peer: none
//!
//! The common static surface over cljw's `.array` tag (ADR-0105 JavaArray —
//! Object[] semantics; Value slots): `asList` (an ArrayList host instance,
//! the D-294 surface) / `toString` ("[e1, e2, …]") / `copyOf` (nil-padded
//! like Java's null pad) / `sort` (in-place, natural `compare` order) /
//! `equals` (element value equality) / `fill`. `binarySearch` / `hashCode` /
//! the typed-primitive-array overload family are intentionally omitted until
//! a real consumer needs them (dead-interop lesson).

const std = @import("std");
const value_sort = @import("../../collection/value_sort.zig");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const java_array = @import("../../collection/java_array.zig");
const array_list_surface = @import("ArrayList.zig");
const vector_mod = @import("../../collection/vector.zig");
const equal = @import("../../equal.zig");
const compare_mod = @import("../../compare.zig");
const print_mod = @import("../../print.zig");
const string_mod = @import("../../collection/string.zig");

/// Arity-1 array-argument prelude shared by the statics.
fn expectArray(v: Value, fn_name: []const u8, loc: SourceLocation) !void {
    if (!java_array.isArray(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a Java array", .actual = @tagName(v.tag()) });
}

/// `(java.util.Arrays/asList arr)` — a java.util.ArrayList holding the
/// array's elements. JVM returns a fixed-size List VIEW; cljw returns the
/// existing ArrayList host surface (mutable, not write-through — the view
/// aliasing is JVM-internal and no cljw consumer depends on it).
fn asList(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Arrays/asList", args, 1, loc);
    try expectArray(args[0], "java.util.Arrays/asList", loc);
    const vec = try vector_mod.fromSlice(rt, java_array.asArray(args[0]).items());
    return array_list_surface.initArrayList(rt, env, &.{vec}, loc);
}

/// `(java.util.Arrays/toString arr)` — "[e1, e2, …]" with `str`-form
/// elements (Java String.valueOf). nil array → "null" (JVM parity).
fn toStringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Arrays/toString", args, 1, loc);
    if (args[0].tag() == .nil) return string_mod.alloc(rt, "null");
    try expectArray(args[0], "java.util.Arrays/toString", loc);
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    try aw.writer.writeByte('[');
    for (java_array.asArray(args[0]).items(), 0..) |e, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        if (e.tag() == .nil) {
            try aw.writer.writeAll("null"); // Java String.valueOf(null)
        } else {
            try print_mod.writeStrValue(rt, env, &aw.writer, e);
        }
    }
    try aw.writer.writeByte(']');
    return string_mod.alloc(rt, aw.writer.buffered());
}

/// `(java.util.Arrays/copyOf arr n)` — a fresh array of length `n`: truncated
/// or nil-padded (Java pads Object[] with null). JVM ref: Arrays#copyOf.
fn copyOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Arrays/copyOf", args, 2, loc);
    try expectArray(args[0], "java.util.Arrays/copyOf", loc);
    const n_i64 = try error_catalog.expectInteger(args[1], "java.util.Arrays/copyOf", loc);
    if (n_i64 < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.Arrays/copyOf", .expected = "a non-negative length", .actual = "negative int" });
    const n: u32 = @intCast(n_i64);
    const out = try java_array.make(rt, n, .nil_val);
    const src = java_array.asArray(args[0]).items();
    const dst = java_array.asArray(out).items();
    const keep = @min(src.len, dst.len);
    @memcpy(dst[0..keep], src[0..keep]);
    return out;
}

const SortCtx = struct {
    rt: *Runtime,
    loc: SourceLocation,
    err: ?anyerror = null,
};

fn arrayLessThan(opaque_ctx: *anyopaque, a: Value, b: Value) bool {
    const ctx: *SortCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ctx.err != null) return false;
    const ord = compare_mod.valueCompare(ctx.rt, a, b, ctx.loc) catch |e| {
        ctx.err = e;
        return false;
    };
    return ord == .lt;
}

/// `(java.util.Arrays/sort arr)` — IN-PLACE natural-order sort (cljw
/// `compare`), returning nil like the void Java method. Stable block sort.
fn sortFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Arrays/sort", args, 1, loc);
    try expectArray(args[0], "java.util.Arrays/sort", loc);
    var ctx: SortCtx = .{ .rt = rt, .loc = loc };
    value_sort.sort(java_array.asArray(args[0]).items(), @ptrCast(&ctx), &arrayLessThan);
    if (ctx.err) |e| return e;
    return .nil_val;
}

/// `(java.util.Arrays/equals a b)` — same length + element value equality
/// (nil-safe: two nils true, one nil false). JVM ref: Arrays#equals.
fn equalsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Arrays/equals", args, 2, loc);
    const a = args[0];
    const b = args[1];
    if (a.tag() == .nil and b.tag() == .nil) return .true_val;
    if (a.tag() == .nil or b.tag() == .nil) return .false_val;
    try expectArray(a, "java.util.Arrays/equals", loc);
    try expectArray(b, "java.util.Arrays/equals", loc);
    const as = java_array.asArray(a).items();
    const bs = java_array.asArray(b).items();
    if (as.len != bs.len) return .false_val;
    for (as, bs) |x, y| {
        if (!try equal.valueEqual(rt, env, x, y)) return .false_val;
    }
    return .true_val;
}

/// `(java.util.Arrays/fill arr v)` — set every slot to `v`; returns nil
/// (void in Java). JVM ref: Arrays#fill.
fn fillFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.util.Arrays/fill", args, 2, loc);
    try expectArray(args[0], "java.util.Arrays/fill", loc);
    @memset(java_array.asArray(args[0]).items(), args[1]);
    return .nil_val;
}

fn initArrays(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "asList", &asList },
        .{ "toString", &toStringFn },
        .{ "copyOf", &copyOf },
        .{ "sort", &sortFn },
        .{ "equals", &equalsFn },
        .{ "fill", &fillFn },
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
    .cljw_ns = "cljw.java.util.Arrays",
    .descriptor = &descriptor,
    .init = &initArrays,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.Arrays",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
