// SPDX-License-Identifier: EPL-2.0
//! Java-array primitives: the Layer-1 host surface over
//! `runtime/collection/java_array.zig` (ADR-0105 / D-287, ADR-0204).
//!
//! The irreducible host operations: the three constructors `__array-make`
//! (sized, default-filled), `__array-from` (a bulk copy of a vector or array,
//! converting each element) and `__array-fill` (every slot one value), then
//! `aget`, `aset`, `alength`, `aclone`, `array?` and `__array-kind`. The
//! clojure.core surface (object-array / int-array / byte-array / make-array /
//! to-array / into-array / aset-* / amap / areduce) is composed from these in
//! `core.clj`. The constructors are native so building an n-element array is
//! one call, not n `aset`s.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const java_array = @import("../../runtime/collection/java_array.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const sub_vector = @import("../../runtime/collection/sub_vector.zig");
const keyword_mod = @import("../../runtime/keyword.zig");

fn requireArray(v: Value, fn_name: []const u8, loc: SourceLocation) !void {
    if (v.tag() != .array)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = fn_name,
            .expected = "an array",
            .actual = @tagName(v.tag()),
        });
}

fn asIndex(v: Value, fn_name: []const u8, loc: SourceLocation) !i64 {
    if (v.tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = fn_name,
            .expected = "an integer index",
            .actual = @tagName(v.tag()),
        });
    return v.asInteger();
}

fn asSize(v: Value, fn_name: []const u8, loc: SourceLocation) !u32 {
    const n = try asIndex(v, fn_name, loc);
    if (n < 0 or n > std_max_u32)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a non-negative size", .actual = "out of range" });
    return @intCast(n);
}

const std_max_u32: i64 = 0xFFFF_FFFF;

/// The element kind a keyword (`:long`, `:object`, …) names.
fn asKind(v: Value, fn_name: []const u8, loc: SourceLocation) !java_array.Kind {
    if (v.tag() == .keyword) {
        if (java_array.Kind.fromName(keyword_mod.asKeyword(v).name)) |k| return k;
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "an array element kind keyword", .actual = @tagName(v.tag()) });
}

/// `(__array-make kind size)`: a `size`-element array of `kind`, every slot
/// at the kind's default.
fn arrayMakeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__array-make", args, 2, loc);
    return java_array.make(rt, try asKind(args[0], "__array-make", loc), try asSize(args[1], "__array-make", loc));
}

/// `(__array-from kind src size)`: an array of `kind` holding `src`'s
/// elements, each converted as clj's `RT.longArray` and friends do (a float
/// truncates into an integer kind, an integer wraps to the width). `src` is a
/// vector or an array; `size` nil means `(count src)`, a number pads with the
/// default or keeps the first `size` elements. The fill runs after the one
/// allocation, so no element is live across a GC.
fn arrayFromFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__array-from", args, 3, loc);
    const kind = try asKind(args[0], "__array-from", loc);
    const src = args[1];
    const n_src: u32 = switch (src.tag()) {
        .vector => vector_mod.count(src),
        .sub_vector => sub_vector.count(src),
        .array => java_array.alength(src),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "__array-from", .expected = "a vector or an array", .actual = @tagName(src.tag()) }),
    };
    const n = if (args[2].isNil()) n_src else try asSize(args[2], "__array-from", loc);
    const out = try java_array.make(rt, kind, n);
    const dst = java_array.asArray(out);
    const m = @min(n, n_src);
    if (src.tag() == .array and java_array.asArray(src).kind == kind) {
        java_array.copy(java_array.asArray(src), 0, dst, 0, m);
        return out;
    }
    for (0..m) |i| {
        const e = switch (src.tag()) {
            .vector => vector_mod.nth(src, @intCast(i)),
            .sub_vector => sub_vector.nth(src, @intCast(i)),
            else => try java_array.get(rt, java_array.asArray(src), i),
        };
        try java_array.store(dst, i, e, .convert, "array constructor", loc);
    }
    return out;
}

/// `(__array-fill array v)`: every slot set to `v` (converted), returns the
/// array. The `(int-array n init)` form.
fn arrayFillFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__array-fill", args, 2, loc);
    try requireArray(args[0], "__array-fill", loc);
    try java_array.fill(java_array.asArray(args[0]), args[1], .convert, "array constructor", loc);
    return args[0];
}

/// `(__array-kind array)`: the element kind keyword (`:byte`, `:object`, …).
fn arrayKindFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__array-kind", args, 1, loc);
    try requireArray(args[0], "__array-kind", loc);
    return keyword_mod.intern(rt, null, @tagName(java_array.asArray(args[0]).kind));
}

/// `(aget array idx & idxs)`: element read, multi-dim by recursion exactly
/// as clj's variadic `aget` composes: `(aget a i j)` reads the nested array
/// at `i`, then `j` within it. Implemented directly in the builtin rather
/// than as a core.clj variadic (the D-446 barrier sketched that shape) so the
/// hot 2-arg path stays a single builtin call.
fn agetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("aget", args, 2, loc);
    var v = args[0];
    for (args[1..]) |idx| {
        try requireArray(v, "aget", loc);
        v = try java_array.aget(rt, v, try asIndex(idx, "aget", loc), "aget", loc);
    }
    return v;
}

/// `(aset array idx val)`: 3-arg in-place write, returns `val`. The value
/// must fit the element kind (clj's "argument type mismatch" otherwise).
fn asetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("aset", args, 3, loc);
    // `(aset a i j … v)`: every arg but the last two walks into a nested
    // array; the final pair is the ordinary element store, which returns the
    // stored value as clj does.
    var v = args[0];
    for (args[1 .. args.len - 2]) |idx| {
        try requireArray(v, "aset", loc);
        v = try java_array.aget(rt, v, try asIndex(idx, "aset", loc), "aset", loc);
    }
    try requireArray(v, "aset", loc);
    return java_array.aset(v, try asIndex(args[args.len - 2], "aset", loc), args[args.len - 1], "aset", loc);
}

fn alengthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("alength", args, 1, loc);
    try requireArray(args[0], "alength", loc);
    return Value.initInteger(@intCast(java_array.alength(args[0])));
}

fn acloneFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("aclone", args, 1, loc);
    try requireArray(args[0], "aclone", loc);
    return java_array.aclone(rt, args[0]);
}

fn arrayQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("array?", args, 1, loc);
    return Value.initBoolean(args[0].tag() == .array);
}

const Entry = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const ENTRIES = [_]Entry{
    .{ .name = "__array-make", .f = &arrayMakeFn },
    .{ .name = "__array-from", .f = &arrayFromFn },
    .{ .name = "__array-fill", .f = &arrayFillFn },
    .{ .name = "__array-kind", .f = &arrayKindFn },
    .{ .name = "aget", .f = &agetFn },
    .{ .name = "aset", .f = &asetFn },
    .{ .name = "alength", .f = &alengthFn },
    .{ .name = "aclone", .f = &acloneFn },
    .{ .name = "array?", .f = &arrayQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
