// SPDX-License-Identifier: EPL-2.0
//! Higher-order primitives — `apply` / `reduce` (素朴版) / `into` /
//! `every?` / `some` / `some?` per ADR-0033 D6 + ROADMAP §9.8 row
//! 6.16.a-3 + v5 §5.2 + §7 transducer 先取り spec.
//!
//! ## Phase 6.16.a-3.1 scope
//!
//! This cycle (.1) lands the eager core of higher-order: apply,
//! 素朴 reduce (seq walk, no IReduce protocol layer yet — that
//! lands at Phase 7 per D-069), into (2-arg eager only), every?,
//! some, some?. The .2 cycle adds Layer 2 eager leaves
//! (`-map-eager`/`-filter-eager`/etc.) + Layer 3 `.clj` defn
//! (`map`/`filter`/`take`/`drop`/`keep`/`remove` + `partial`/`comp`/
//! `complement`/`constantly`/`juxt`) + transducer rf protocol formal
//! registration.
//!
//! ## Pattern
//!
//! Same shape as sequence.zig (d35dc3b) + collection.zig (a4bfca5):
//! Layer 2 Tag switch dispatching to Layer 0 helpers + `rt.vtable.callFn`
//! for invoking user fns. Phase 7 D-069 adds `.protocol_extended`
//! slow-path arms to every relevant switch.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: list, vector, map, set, reduced, sequence (Layer 2)
//! Clojure peer: none (Pattern B1 direct intern, public surface)

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

const reduced = @import("../../runtime/collection/reduced.zig");
const sequence = @import("sequence.zig");
const collection = @import("collection.zig");

// --- apply ---

/// Implements clojure.core/apply.
/// Spec: `(apply f args...)` calls f with the trailing args expanded.
///   - `(apply f xs)`             — call f with each element of xs
///   - `(apply f a b xs)`         — call f with a, b, then xs elements
///   - `(apply f a b c d e xs)`   — 5 leading args + xs
/// JVM reference: clojure.lang.RT.applyTo / clojure.core/apply
/// cw v1 tier: A (Phase 6.16.a-3.1)
///
/// Phase 6.16.a-3.1 takes the simple path: collect all args into a
/// flat Zig slice and call via `rt.vtable.callFn`. Lazy-seq tail
/// integration (= JVM's `apply f (range)` infinite stream pattern)
/// deferred per survey R3 to Phase 7 entry when `IReduce` lands.
pub fn applyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2) {
        return error_catalog.raise(.arity_below_min, loc, .{
            .fn_name = "apply",
            .got = args.len,
            .min = 2,
        });
    }
    const f = args[0];
    // Leading positional args = args[1..args.len-1]
    // Trailing seqable     = args[args.len-1]
    const trailing = args[args.len - 1];
    const leading = args[1 .. args.len - 1];

    // Walk the trailing seqable, collecting into a flat slice.
    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(rt.gpa);
    try collected.appendSlice(rt.gpa, leading);

    var cur: Value = trailing;
    // Normalize: if not already seq-shaped, call seq to get a list view.
    if (!cur.isNil()) {
        switch (cur.tag()) {
            .list, .cons, .chunked_cons, .lazy_seq => {},
            else => {
                cur = try sequence.seqFn(rt, env, &.{cur}, loc);
            },
        }
    }
    while (!cur.isNil()) {
        try collected.append(rt.gpa, try sequence.firstFn(rt, env, &.{cur}, loc));
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    return try invokeCallable(rt, env, f, collected.items, loc);
}

/// Invoke a callable Value (builtin or Function) with args via the
/// runtime vtable.
fn invokeCallable(rt: *Runtime, env: *Env, f: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (f.tag() == .builtin_fn) {
        const fn_ptr = f.asBuiltinFn(dispatch.BuiltinFn);
        return fn_ptr(rt, env, args, loc);
    }
    if (rt.vtable) |vt| {
        return try vt.callFn(rt, env, f, args, loc);
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "apply",
        .expected = "callable (fn or builtin)",
        .actual = @tagName(f.tag()),
    });
}

// --- reduce ---

/// Implements clojure.core/reduce.
/// Spec:
///   `(reduce f coll)`      — reduces coll, using (first coll) as init
///   `(reduce f init coll)` — reduces with explicit init
/// `(reduced x)` returned by f terminates the reduction early with x.
/// JVM reference: clojure.lang.RT.reduce / clojure.core.protocols/IReduce
/// cw v1 tier: A (Phase 6.16.a-3.1, 素朴 seq-walk; IReduce protocol
/// layer lands at Phase 7 per D-069)
pub fn reduceFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2 or args.len > 3) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "reduce",
            .expected = 2,
            .got = args.len,
        });
    }
    const f = args[0];
    var acc: Value = undefined;
    var cur: Value = undefined;
    if (args.len == 3) {
        acc = args[1];
        cur = try sequence.seqFn(rt, env, &.{args[2]}, loc);
    } else {
        // (reduce f coll): use (first coll) as init.
        cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
        if (cur.isNil()) {
            // Empty coll, no init → call (f) with zero args (= rf init).
            return try invokeCallable(rt, env, f, &.{}, loc);
        }
        acc = try sequence.firstFn(rt, env, &.{cur}, loc);
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    while (!cur.isNil()) {
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const step = try invokeCallable(rt, env, f, &.{ acc, elt }, loc);
        if (reduced.isReduced(step)) {
            return reduced.unreduce(step);
        }
        acc = step;
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    return acc;
}

// --- into ---

/// Implements clojure.core/into (2-arg eager form).
/// Spec: `(into to from)` — `(reduce conj to from)`.
/// JVM reference: clojure.core/into
/// cw v1 tier: A (Phase 6.16.a-3.1, 2-arg eager only;
/// 3-arg `(into to xform from)` transducer-aware form lands at .a-3.2
/// when xform protocol formal registration completes)
pub fn intoFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("into", args, 2, loc);
    const to = args[0];
    const from = args[1];
    var acc: Value = to;
    var cur = try sequence.seqFn(rt, env, &.{from}, loc);
    while (!cur.isNil()) {
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        acc = try collection.conjFn(rt, env, &.{ acc, elt }, loc);
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    return acc;
}

// --- every? ---

/// Implements clojure.core/every?.
/// Spec: `(every? pred coll)` — returns true iff pred is truthy for
/// every element; vacuously true on empty coll.
/// JVM reference: clojure.core/every?
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn everyQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("every?", args, 2, loc);
    const pred = args[0];
    var cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
    while (!cur.isNil()) {
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const r = try invokeCallable(rt, env, pred, &.{elt}, loc);
        if (isFalsy(r)) return .false_val;
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    return .true_val;
}

// --- some ---

/// Implements clojure.core/some.
/// Spec: `(some pred coll)` — returns the first truthy `(pred x)`
/// result, or `nil` if none truthy.
/// JVM reference: clojure.core/some
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn someFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("some", args, 2, loc);
    const pred = args[0];
    var cur = try sequence.seqFn(rt, env, &.{args[1]}, loc);
    while (!cur.isNil()) {
        const elt = try sequence.firstFn(rt, env, &.{cur}, loc);
        const r = try invokeCallable(rt, env, pred, &.{elt}, loc);
        if (!isFalsy(r)) return r;
        cur = try sequence.restFn(rt, env, &.{cur}, loc);
    }
    return .nil_val;
}

// --- some? ---

/// Implements clojure.core/some?.
/// Spec: `(some? x)` — true iff `x` is not nil.
/// JVM reference: clojure.core/some?
/// cw v1 tier: A (Phase 6.16.a-3.1)
pub fn someQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("some?", args, 1, loc);
    return if (args[0].isNil()) .false_val else .true_val;
}

// --- helpers ---

/// Clojure truthiness: only `nil` and `false` are falsy.
fn isFalsy(v: Value) bool {
    return v.isNil() or v == Value.false_val;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "apply", .f = &applyFn },
    .{ .name = "reduce", .f = &reduceFn },
    .{ .name = "into", .f = &intoFn },
    .{ .name = "every?", .f = &everyQFn },
    .{ .name = "some", .f = &someFn },
    .{ .name = "some?", .f = &someQFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

test "some? true for non-nil, false for nil" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    try testing.expectEqual(Value.true_val, try someQFn(&rt, &env, &.{Value.initInteger(0)}, .{ .line = 0, .column = 0 }));
    try testing.expectEqual(Value.false_val, try someQFn(&rt, &env, &.{Value.nil_val}, .{ .line = 0, .column = 0 }));
}

test "isFalsy: only nil + false are falsy" {
    try testing.expect(isFalsy(Value.nil_val));
    try testing.expect(isFalsy(Value.false_val));
    try testing.expect(!isFalsy(Value.true_val));
    try testing.expect(!isFalsy(Value.initInteger(0))); // 0 is truthy in Clojure
}
