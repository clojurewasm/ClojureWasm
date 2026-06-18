// SPDX-License-Identifier: EPL-2.0
//! Tier-A transient primitives (ROADMAP §9.10 row 8.5, D-074).
//! Layer-2 thin wrappers over `runtime/collection/transient/*.zig`.
//!
//! All 7 transient ops are implemented: `transient` (the
//! `(transient coll)` constructor — no `!` because it does not
//! mutate), `persistent!`, `conj!`, `pop!`, `assoc!`, `disj!`,
//! `dissoc!`, backed by TransientVector / TransientArrayMap /
//! TransientHashSet.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: vector, transient_vector, transient_array_map, transient_hash_set
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

const transient_vector = @import("../../runtime/collection/transient/transient_vector.zig");
const transient_array_map = @import("../../runtime/collection/transient/transient_array_map.zig");
const transient_hash_set = @import("../../runtime/collection/transient/transient_hash_set.zig");

/// Implements clojure.core/transient.
/// Spec: `(transient coll)` returns an editable transient version of
///   coll. Supports vector, array_map / hash_map, and hash_set
///   sources (nil → empty transient vector).
/// JVM reference: clojure.core/transient → IEditableCollection.asTransient
/// cw v1 tier: A (Phase 8.5 cycle 1)
pub fn transientFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("transient", args, 1, loc);
    const coll = args[0];
    return switch (coll.tag()) {
        .vector => try transient_vector.fromVector(rt, coll),
        // Both map variants route through fromMap: `.array_map` copies
        // entries (flat mode), `.hash_map` is held directly (hash mode).
        // Past 8 entries the transient promotes to a persistent HAMT
        // (ADR-0064; was an error.HashMapNotImplemented stub pre-D-045).
        .array_map => try transient_array_map.fromMap(rt, coll),
        .hash_map => try transient_array_map.fromMap(rt, coll),
        .hash_set => try transient_hash_set.fromSet(rt, coll),
        .nil => try transient_vector.fromVector(rt, coll),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "transient",
            .expected = "vector, array_map, or hash_map",
            .actual = @tagName(coll.tag()),
        }),
    };
}

/// Implements clojure.core/persistent!.
/// Spec: `(persistent! tcoll)` returns a persistent version of tcoll
///   and renders tcoll dead. JVM raises IllegalAccessError on later
///   mutating calls; cw v1 raises `transient_used_after_persistent`.
/// JVM reference: clojure.core/persistent! → ITransientCollection.persistent
/// cw v1 tier: A (Phase 8.5 cycle 1)
pub fn persistentBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("persistent!", args, 1, loc);
    const tcoll = args[0];
    return switch (tcoll.tag()) {
        .transient_vector => try transient_vector.toPersistent(rt, tcoll, loc),
        .transient_map => try transient_array_map.toPersistent(rt, tcoll, loc),
        .transient_set => try transient_hash_set.toPersistent(rt, tcoll, loc),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "persistent!",
            .expected = "transient",
            .actual = @tagName(tcoll.tag()),
        }),
    };
}

/// Implements clojure.core/conj!.
/// Spec: `(conj! tcoll x)` adds x to tcoll in place and returns the
///   (possibly different) transient. JVM `conj!` is variadic-via-reduce
///   in clojure.core; the underlying primitive is 2-arity. cw v1
///   exposes the 2-arity primitive (matches JVM IEditableCollection).
/// JVM reference: clojure.core/conj! → ITransientCollection.conj
/// cw v1 tier: A (Phase 8.5 cycle 1)
pub fn conjBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // clj conj! (D-446): `(conj!)` → (transient []), `(conj! coll)` → coll,
    // `(conj! coll x)` → in-place add. The 0/1 arities are the transducer
    // identity/completion arities (clojure.core 1.7+).
    if (args.len == 0) return try transient_vector.fromVector(rt, Value.nil_val);
    if (args.len == 1) return args[0];
    try error_catalog.checkArity("conj!", args, 2, loc);
    const tcoll = args[0];
    const x = args[1];
    return switch (tcoll.tag()) {
        .transient_vector => try transient_vector.conj(rt, tcoll, x, loc),
        .transient_map => try transient_array_map.conjEntry(rt, tcoll, x, loc),
        .transient_set => try transient_hash_set.conj(rt, tcoll, x, loc),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "conj!",
            .expected = "transient",
            .actual = @tagName(tcoll.tag()),
        }),
    };
}

/// Implements clojure.core/disj!.
/// Spec: `(disj! tset e)` removes e from tset in place; set-only.
/// JVM reference: clojure.core/disj! → ITransientSet.disjoin
/// cw v1 tier: A (Phase 8.5 cycle 3)
pub fn disjBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("disj!", args, 2, loc);
    const tcoll = args[0];
    return switch (tcoll.tag()) {
        .transient_set => try transient_hash_set.disj(rt, tcoll, args[1], loc),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "disj!",
            .expected = "transient_set",
            .actual = @tagName(tcoll.tag()),
        }),
    };
}

/// Implements clojure.core/assoc!.
/// Spec: `(assoc! tcoll k v)` — vector: integer key in [0, count]
///   (`idx == count` appends, D-199); map: arbitrary key.
/// JVM reference: clojure.core/assoc! → ITransientAssociative.assoc
/// cw v1 tier: A (Phase 8.5 cycle 2)
pub fn assocBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    // `(assoc! tmap k v)` + `(assoc! tmap k1 v1 k2 v2 …)` — odd arg count ≥ 3
    // (clj's `[coll key val & kvs]`). Even = a key without a value.
    if (args.len % 2 == 0)
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    if (args.len < 3)
        return error_catalog.raise(.arity_out_of_range, loc, .{ .fn_name = "assoc!", .got = args.len, .min = 3, .max = 3 });
    var tcoll = args[0];
    switch (tcoll.tag()) {
        .transient_map => {
            var i: usize = 1;
            while (i < args.len) : (i += 2) {
                tcoll = try transient_array_map.assoc(rt, tcoll, args[i], args[i + 1], loc);
            }
        },
        // D-199: a transient vector is Associative by integer index (clj's
        // `(assoc! tv idx v)`); `idx == count` appends, else overwrites.
        .transient_vector => {
            var i: usize = 1;
            while (i < args.len) : (i += 2) {
                const k = args[i];
                // Non-integer key on a transient vector → IllegalArgumentException
                // (clj parity, mirrors persistent `(assoc [1 2] "k" v)`). D-459.
                if (k.tag() != .integer)
                    return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "assoc!", .expected = "an integer key for a vector", .actual = @tagName(k.tag()) });
                tcoll = try transient_vector.assoc(rt, tcoll, k.asInteger(), args[i + 1], loc);
            }
        },
        else => return error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "assoc!",
            .expected = "transient_map or transient_vector",
            .actual = @tagName(tcoll.tag()),
        }),
    }
    return tcoll;
}

/// Implements clojure.core/dissoc!.
/// Spec: `(dissoc! tmap k)` — removes k from tmap in place.
/// JVM reference: clojure.core/dissoc! → ITransientMap.without
/// cw v1 tier: A (Phase 8.5 cycle 2)
pub fn dissocBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("dissoc!", args, 2, loc);
    const tcoll = args[0];
    return switch (tcoll.tag()) {
        .transient_map => try transient_array_map.dissoc(rt, tcoll, args[1], loc),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "dissoc!",
            .expected = "transient_map",
            .actual = @tagName(tcoll.tag()),
        }),
    };
}

/// Implements clojure.core/pop!.
/// Spec: `(pop! tcoll)` removes the last item in place; vector-only.
///   Throws on empty (JVM IllegalStateException).
/// JVM reference: clojure.core/pop! → ITransientVector.pop
/// cw v1 tier: A (Phase 8.5 cycle 1)
pub fn popBangFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("pop!", args, 1, loc);
    const tcoll = args[0];
    return switch (tcoll.tag()) {
        .transient_vector => try transient_vector.pop(tcoll, loc),
        else => error_catalog.raise(.transient_kind_mismatch, loc, .{
            .fn_name = "pop!",
            .expected = "transient vector",
            .actual = @tagName(tcoll.tag()),
        }),
    };
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "transient", .f = &transientFn },
    .{ .name = "persistent!", .f = &persistentBangFn },
    .{ .name = "conj!", .f = &conjBangFn },
    .{ .name = "pop!", .f = &popBangFn },
    .{ .name = "assoc!", .f = &assocBangFn },
    .{ .name = "dissoc!", .f = &dissocBangFn },
    .{ .name = "disj!", .f = &disjBangFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "transient → conj! → persistent! round-trip via primitive layer" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const vector = @import("../../runtime/collection/vector.zig");
    const loc = SourceLocation{ .line = 0, .column = 0 };

    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));

    const tv = try transientFn(&fix.rt, &fix.env, &.{v}, loc);
    _ = try conjBangFn(&fix.rt, &fix.env, &.{ tv, Value.initInteger(2) }, loc);
    const p = try persistentBangFn(&fix.rt, &fix.env, &.{tv}, loc);

    try testing.expectEqual(@as(u32, 2), vector.count(p));
    try testing.expectEqual(@as(i48, 1), vector.nth(p, 0).asInteger());
    try testing.expectEqual(@as(i48, 2), vector.nth(p, 1).asInteger());
}

test "transient on unsupported tag raises transient_kind_mismatch" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const loc = SourceLocation{ .line = 0, .column = 0 };
    error_mod.clearLastError();
    try testing.expectError(
        error_mod.ClojureWasmError.TypeError,
        transientFn(&fix.rt, &fix.env, &.{Value.initInteger(0)}, loc),
    );
}
