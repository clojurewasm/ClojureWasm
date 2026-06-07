// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.Util` static methods (ADR-0108).
//!
//! Backend: impl-only
//! Impl deps: equal, compare, hash
//! Clojure peer: clojure.core/= , clojure.core/compare, clojure.core/hash,
//!   clojure.core/identical?, clojure.core/integer?
//!
//! Real pure-Clojure libraries (data.finger-tree, data.avl, ~95 corpus call
//! sites) drop to `clojure.lang.Util` runtime statics. This is the first member
//! of the third host-surface tree `runtime/clojure/lang/` (ADR-0108, after
//! ADR-0029's java/ + cljw/). Registered as `cljw.clojure.lang.Util`, so
//! `resolveJavaSurface("clojure.lang.Util")` hits via the `cljw.<fqcn>` path.
//!
//! Each static is a thin wrapper over an existing neutral `runtime/` impl
//! (F-009). `hash`/`hasheq` return cljw-native hashes (AD-009 — intra-cljw
//! consistency only). `classOf` is deferred to a follow-up (it needs the
//! `classPrim` logic factored into a runtime-layer helper — D-303).

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const equal = @import("../../equal.zig");
const compare_mod = @import("../../compare.zig");

/// `(clojure.lang.Util/equiv a b)` — Clojure `=` equality (category-strict;
/// `(equiv 1 1.0)` → false, matching cljw `=` and clj's Util.equiv per F-005).
fn equiv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.Util/equiv", args, 2, loc);
    return if (try equal.valueEqual(rt, env, args[0], args[1])) .true_val else .false_val;
}

/// `(clojure.lang.Util/equals a b)` — Java `.equals`: type-sensitive, so
/// `(equals 1 1N)` → false (Long vs BigInt) where `equiv` → true. cljw uses the
/// Value tag as the class proxy: equal only when SAME tag AND value-equal.
fn equals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.Util/equals", args, 2, loc);
    if (args[0].tag() != args[1].tag()) return .false_val;
    return if (try equal.valueEqual(rt, env, args[0], args[1])) .true_val else .false_val;
}

/// `(clojure.lang.Util/pcequiv a b)` — persistent-collection equiv = `=`.
fn pcequiv(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.Util/pcequiv", args, 2, loc);
    return if (try equal.valueEqual(rt, env, args[0], args[1])) .true_val else .false_val;
}

/// `(clojure.lang.Util/identical a b)` — reference identity (cljw Value
/// bit-equality: immediates compare by value, heap values by pointer).
fn identical(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/identical", args, 2, loc);
    return if (args[0] == args[1]) .true_val else .false_val;
}

/// `(clojure.lang.Util/isInteger x)` — true for Long / BigInt. cljw has no
/// distinct Short/Byte (F-005), so `(isInteger (short 5))` → true here vs clj
/// false; that divergence derives from F-005 (no boxed sub-Long integers).
fn isInteger(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/isInteger", args, 1, loc);
    return switch (args[0].tag()) {
        .integer, .big_int => .true_val,
        else => .false_val,
    };
}

/// `(clojure.lang.Util/hash o)` / `(…/hasheq o)` — cljw-native value hash.
/// Values differ from clj/JVM (AD-009): only intra-cljw consistency (equal
/// values hash equal — the HAMT key contract) is guaranteed. Both Util.hash
/// (Java hashCode) and Util.hasheq (Clojure hasheq) map here — cljw has a
/// single value-hash, not the JVM's two.
fn hash(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/hash", args, 1, loc);
    return Value.initInteger(@as(i32, @bitCast(equal.valueHash(args[0]))));
}

/// `(clojure.lang.Util/compare a b)` — three-way comparison (-1/0/1). A NaN
/// operand compares EQUAL (0) to everything, matching clj's Util.compare.
fn compare(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/compare", args, 2, loc);
    if (isNanFloat(args[0]) or isNanFloat(args[1])) return Value.initInteger(0);
    const order = try compare_mod.valueCompare(rt, args[0], args[1], loc);
    return Value.initInteger(@as(i64, switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    }));
}

fn isNanFloat(v: Value) bool {
    return v.tag() == .float and std.math.isNan(v.asFloat());
}

/// `(clojure.lang.Util/hashCombine seed hash)` — JVM Util.hashCombine bit-mix.
/// Inputs/outputs are i32; under AD-009 the value is intra-cljw only.
fn hashCombine(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/hashCombine", args, 2, loc);
    const seed: i32 = @truncate(try error_catalog.expectInteger(args[0], "clojure.lang.Util/hashCombine", loc));
    const h: i32 = @truncate(try error_catalog.expectInteger(args[1], "clojure.lang.Util/hashCombine", loc));
    // JVM: seed ^ (hash + 0x9e3779b9 + (seed<<6) + (seed>>2)). Wrapping i32.
    const su: u32 = @bitCast(seed);
    const hu: u32 = @bitCast(h);
    const mixed: u32 = hu +% 0x9e3779b9 +% (su << 6) +% (su >> 2);
    return Value.initInteger(@as(i32, @bitCast(su ^ mixed)));
}

/// `(clojure.lang.Util/isPrimitive c)` — cljw has no primitive Classes
/// (F-005/ADR-0059: a class value is a TypeDescriptor, never a JVM primitive),
/// so this is uniformly false.
fn isPrimitive(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("clojure.lang.Util/isPrimitive", args, 1, loc);
    return .false_val;
}

fn initUtil(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "equiv", &equiv },             .{ "equals", &equals },       .{ "pcequiv", &pcequiv },
        .{ "identical", &identical },     .{ "isInteger", &isInteger }, .{ "hash", &hash },
        .{ "hasheq", &hash },             .{ "compare", &compare },     .{ "hashCombine", &hashCombine },
        .{ "isPrimitive", &isPrimitive },
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
    .cljw_ns = "cljw.clojure.lang.Util",
    .descriptor = &descriptor,
    .init = &initUtil,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.clojure.lang.Util",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
