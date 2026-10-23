// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Arrays` static methods (D-526).
//!
//! Backend: impl-only
//! Impl deps: java_array
//! Clojure peer: none
//!
//! The common static surface over cljw's `.array` tag (ADR-0105 JavaArray,
//! typed per ADR-0204): `asList` (an ArrayList host instance, the D-294
//! surface) / `toString` ("[e1, e2, …]") / `copyOf` (padded with the kind's
//! default, Java's null / 0 / false) / `sort` (in place: natural `compare`
//! order for an object array, numeric order for a primitive one, `-0.0`
//! before `0.0` and NaN last as `Double.compare`) / `equals` (same kind, same
//! length, equal elements) / `fill`. `binarySearch` / `hashCode` are
//! intentionally omitted until a real consumer needs them (dead-interop lesson).

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
    const vec = try java_array.toVector(rt, java_array.asArray(args[0]));
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
    const arr = java_array.asArray(args[0]);
    for (0..arr.len) |i| {
        const e = try java_array.get(rt, arr, i);
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

/// `(java.util.Arrays/copyOf arr n)` — a fresh array of the same kind and
/// length `n`: truncated, or padded with the kind's default (Java's null / 0 /
/// false). JVM ref: Arrays#copyOf.
fn copyOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Arrays/copyOf", args, 2, loc);
    try expectArray(args[0], "java.util.Arrays/copyOf", loc);
    const n_i64 = try error_catalog.expectInteger(args[1], "java.util.Arrays/copyOf", loc);
    if (n_i64 < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.Arrays/copyOf", .expected = "a non-negative length", .actual = "negative int" });
    const n: u32 = @intCast(n_i64);
    const src = java_array.asArray(args[0]);
    const out = try java_array.make(rt, src.kind, n);
    java_array.copy(src, 0, java_array.asArray(out), 0, @min(src.len, n));
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

/// `Double.compare` order: `-0.0` before `0.0`, every NaN after +Inf.
fn floatLessThan(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn lt(_: void, a: T, b: T) bool {
            if (std.math.isNan(a)) return false;
            if (std.math.isNan(b)) return true;
            if (a == b) return std.math.signbit(a) and !std.math.signbit(b);
            return a < b;
        }
    }.lt;
}

/// `(java.util.Arrays/sort arr)` — IN-PLACE sort returning nil like the void
/// Java method. An object array sorts by cljw `compare` (stable block sort),
/// a primitive one by element value.
fn sortFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.Arrays/sort", args, 1, loc);
    try expectArray(args[0], "java.util.Arrays/sort", loc);
    const arr = java_array.asArray(args[0]);
    switch (arr.kind) {
        .object => {
            var ctx: SortCtx = .{ .rt = rt, .loc = loc };
            value_sort.sort(arr.objects(), @ptrCast(&ctx), &arrayLessThan);
            if (ctx.err) |e| return e;
        },
        inline .float, .double => |k| std.mem.sort(k.Elem(), arr.slice(k), {}, floatLessThan(k.Elem())),
        inline else => |k| std.mem.sort(k.Elem(), arr.slice(k), {}, std.sort.asc(k.Elem())),
    }
    return .nil_val;
}

/// Element equality of two primitive arrays of kind `k`; a float compares as
/// `Double.equals` (bit equality with every NaN equal).
fn primEqual(comptime k: java_array.Kind, a: *const java_array.JavaArray, b: *const java_array.JavaArray) bool {
    const T = k.Elem();
    if (comptime T == f32 or T == f64) {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        for (a.slice(k), b.slice(k)) |x, y| {
            if (std.math.isNan(x) and std.math.isNan(y)) continue;
            if (@as(U, @bitCast(x)) != @as(U, @bitCast(y))) return false;
        }
        return true;
    } else return std.mem.eql(u8, a.bytes(), b.bytes());
}

/// `(java.util.Arrays/equals a b)` — same kind, same length, element value
/// equality (nil-safe: two nils true, one nil false). Arrays of different
/// kinds are unequal (no Java overload takes two). JVM ref: Arrays#equals.
fn equalsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.Arrays/equals", args, 2, loc);
    const a = args[0];
    const b = args[1];
    if (a.tag() == .nil and b.tag() == .nil) return .true_val;
    if (a.tag() == .nil or b.tag() == .nil) return .false_val;
    try expectArray(a, "java.util.Arrays/equals", loc);
    try expectArray(b, "java.util.Arrays/equals", loc);
    const aa = java_array.asArray(a);
    const ba = java_array.asArray(b);
    if (aa.kind != ba.kind or aa.len != ba.len) return .false_val;
    switch (aa.kind) {
        .object => for (aa.objects(), ba.objects()) |x, y| {
            if (!try equal.valueEqual(rt, env, x, y)) return .false_val;
        },
        inline else => |k| if (!primEqual(k, aa, ba)) return .false_val,
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
    try java_array.fill(java_array.asArray(args[0]), args[1], .strict, "java.util.Arrays/fill", loc);
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
