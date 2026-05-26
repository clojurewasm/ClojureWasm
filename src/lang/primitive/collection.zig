// SPDX-License-Identifier: EPL-2.0
//! Collection ops — `conj` / `disj` / `contains?` / `get` / `nth` /
//! `assoc` / `dissoc` / `keys` / `vals` per ADR-0033 D6 + ROADMAP §9.8
//! row 6.16.a-2 + v5 §5.2.
//!
//! ## Pattern (continues sequence.zig from Phase 6.16.a-1)
//!
//! Same shape as `lang/primitive/sequence.zig` (d35dc3b): Layer 2
//! Tag switch dispatching to existing Layer 0 collection helpers
//! (`runtime/collection/{vector,list,map,set}.zig`). Phase 7 (D-069)
//! adds the `.protocol_extended` slow-path arm; the fast-path Tag
//! arms stay.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: vector, list, map, set
//! Clojure peer: none (Pattern B1 direct intern, public surface)
//!
//! ## File split rationale
//!
//! sequence.zig is already ~487 LOC; adding 9 collection-ops
//! primitives would push it past the 1000-line ROADMAP §2 A6 cap.
//! The file split also matches the cycle semantic split (a-1
//! fundamentals / a-2 collection-ops / a-3 higher-order). Per
//! sequence.zig L23-29 docstring "subdir promotion deferred until
//! primitive count grows past ~12" — Phase 6.16.a-3 will revisit
//! a `core/` subdir grouping for sequence + collection + higher-order
//! once the full set is in place.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

const vector = @import("../../runtime/collection/vector.zig");
const list = @import("../../runtime/collection/list.zig");
const map = @import("../../runtime/collection/map.zig");
const set = @import("../../runtime/collection/set.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const keyword_mod = @import("../../runtime/keyword.zig");

// --- conj ---

/// Implements clojure.core/conj.
/// Spec: `(conj coll x)` adds x at the "natural" position.
///   - nil:     returns (x)
///   - list:    prepend
///   - vector:  append
///   - set:     add
///   - map:     2-element vector [k v] → assoc
/// JVM reference: clojure.lang.RT.conj
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn conjFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("conj", args, 2, loc);
    const coll = args[0];
    const x = args[1];
    if (coll.isNil()) return try list.consHeap(rt, x, .nil_val);
    return switch (coll.tag()) {
        .vector => try vector.conj(rt, coll, x),
        .list, .cons => try list.consHeap(rt, x, coll),
        .hash_set => try set.conj(rt, coll, x),
        .array_map, .hash_map => mapConj(rt, coll, x, loc),
        else => blk: {
            // Row 7.7 cycle 3: outer-else routes through dispatch against
            // `IPersistentCollection -cons` (JVM `RT.conj` dispatches via
            // `IPersistentCollection.cons`). Reaches `(extend-type X
            // IPersistentCollection (-cons [c x] …))` on defrecord /
            // reified_instance / native-Tag receivers via the row 7.3
            // per-Tag descriptor registry.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, "IPersistentCollection", "-cons", args, loc);
        },
    };
}

fn mapConj(rt: *Runtime, m: Value, entry: Value, loc: SourceLocation) anyerror!Value {
    // (conj m [k v]) — vector pair gets destructured into assoc.
    if (entry.tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "conj",
            .expected = "[k v] vector when conj-ing into a map",
            .actual = @tagName(entry.tag()),
        });
    }
    if (vector.count(entry) != 2) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "conj",
            .expected = "2-element [k v] vector for map conj",
            .actual = "vector of different arity",
        });
    }
    return try map.assoc(rt, m, vector.nth(entry, 0), vector.nth(entry, 1));
}

// --- disj ---

/// Implements clojure.core/disj.
/// Spec: `(disj set k)` removes k from set. Set-only.
/// JVM reference: clojure.core/disj → IPersistentSet.disjoin
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn disjFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("disj", args, 2, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .hash_set => try set.disj(rt, coll, args[1]),
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "disj",
            .expected = "set",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- contains? ---

/// Implements clojure.core/contains?.
/// Spec: `(contains? coll key)` — set: membership; map: has-key.
///
/// **DIVERGENCE D1 from v5 §5.2 wording**: cw v1 rejects
/// `(contains? [1 2 3] 1)` with type_arg_invalid. JVM Clojure
/// `RT.contains` returns true (treats vectors as has-index?), which
/// is the documented gotcha all Clojure newcomers hit. cw v1 picks
/// the cleaner "set/map only" semantic; v5 wording originally read
/// "vector の has-index? は不採用 = JVM 同様" which incorrectly
/// labels the cw choice as JVM-compatible. Follow-up v5 amendment
/// to relabel as DIVERGENCE (not "same as JVM").
/// JVM reference: clojure.lang.RT.contains
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn containsQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("contains?", args, 2, loc);
    const coll = args[0];
    if (coll.isNil()) return .false_val;
    const k = args[1];
    return switch (coll.tag()) {
        .hash_set => if (try set.contains(coll, k)) .true_val else .false_val,
        .array_map, .hash_map => if (try map.contains(coll, k)) .true_val else .false_val,
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "contains?",
            .expected = "set or map",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- get ---

/// Implements clojure.core/get.
/// Spec: `(get coll k)` returns value at k, or nil. `(get coll k
/// default)` returns default if absent.
/// JVM reference: clojure.lang.RT.get
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn getFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 2 or args.len > 3) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "get",
            .expected = 2,
            .got = args.len,
        });
    }
    const coll = args[0];
    const default: Value = if (args.len == 3) args[2] else .nil_val;
    if (coll.isNil()) return default;
    const k = args[1];
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            if (try map.contains(coll, k)) {
                break :blk try map.get(coll, k);
            }
            break :blk default;
        },
        .hash_set => if (try set.contains(coll, k)) k else default,
        .vector => blk: {
            if (k.tag() != .integer) break :blk default;
            const idx = k.asInteger();
            if (idx < 0) break :blk default;
            const n = vector.count(coll);
            if (idx >= n) break :blk default;
            break :blk vector.nth(coll, @intCast(idx));
        },
        .typed_instance => recordGet(coll, k, default),
        else => default,
    };
}

/// Implicit IPersistentMap read for a `defrecord` TypedInstance.
/// `(get rec :k)` walks `descriptor.field_layout` and returns the
/// matching field value; non-keyword keys and non-matching keys fall
/// through to `default`. `deftype` instances (`.kind = .deftype`)
/// do not route through the map surface — they return `default`.
/// Row 7.4 cycle 3 — minimum declared-key shape; non-declared key
/// `__extmap` overflow lands at the cycle-4 PROVISIONAL discharge.
fn recordGet(rec: Value, k: Value, default: Value) Value {
    const inst = rec.decodePtr(*const td_mod.TypedInstance);
    if (inst.descriptor.kind != .defrecord) return default;
    if (k.tag() != .keyword) return default;
    const layout = inst.descriptor.field_layout orelse return default;
    const key_name = keyword_mod.asKeyword(k).name;
    for (layout) |fe| {
        if (std.mem.eql(u8, fe.name, key_name)) {
            return inst.fields()[fe.index];
        }
    }
    return default;
}

// --- nth ---

/// Implements clojure.core/nth.
/// Spec: `(nth coll i)` returns the i-th item. Index error if i is
/// out of range. `(nth coll i default)` returns default on out-of-range.
/// JVM reference: clojure.lang.RT.nth
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn nthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len < 2 or args.len > 3) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "nth",
            .expected = 2,
            .got = args.len,
        });
    }
    const coll = args[0];
    const i_val = args[1];
    if (i_val.tag() != .integer) {
        return error_catalog.raise(.type_arg_not_integer, loc, .{
            .fn_name = "nth",
            .actual = @tagName(i_val.tag()),
        });
    }
    const idx = i_val.asInteger();
    const has_default = args.len == 3;
    const default: Value = if (has_default) args[2] else .nil_val;

    if (coll.isNil()) {
        if (has_default) return default;
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "nth",
            .expected = "indexed collection",
            .actual = "nil",
        });
    }

    return switch (coll.tag()) {
        .vector => blk: {
            if (idx < 0) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "nth",
                    .expected = "non-negative integer index",
                    .actual = "negative",
                });
            }
            const n = vector.count(coll);
            if (idx >= n) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "nth",
                    .expected = "index in bounds",
                    .actual = "out of range",
                });
            }
            break :blk vector.nth(coll, @intCast(idx));
        },
        .list, .cons => blk: {
            if (idx < 0) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "nth",
                    .expected = "non-negative integer index",
                    .actual = "negative",
                });
            }
            var cur: Value = coll;
            var remaining: i64 = idx;
            while (remaining > 0) : (remaining -= 1) {
                cur = list.rest(cur);
                if (cur.isNil()) {
                    if (has_default) break :blk default;
                    break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                        .fn_name = "nth",
                        .expected = "index in bounds",
                        .actual = "out of range",
                    });
                }
            }
            break :blk list.first(cur);
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "nth",
            .expected = "indexed collection (vector, list)",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- assoc ---

/// Implements clojure.core/assoc.
/// Spec: `(assoc map k v)` returns new map with k→v.
/// `(assoc vec i v)` returns new vector with index i replaced.
/// `(assoc nil k v)` returns `{k v}` (per JVM).
/// JVM reference: clojure.lang.RT.assoc
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn assocFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 3 or (args.len - 1) % 2 != 0) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "assoc",
            .expected = 3,
            .got = args.len,
        });
    }
    const coll = args[0];
    if (coll.isNil()) {
        // (assoc nil k v) → {k v} — start with empty map and assoc.
        var acc: Value = map.empty();
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            acc = try map.assoc(rt, acc, args[i], args[i + 1]);
        }
        return acc;
    }
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i + 1 < args.len) : (i += 2) {
                acc = try map.assoc(rt, acc, args[i], args[i + 1]);
            }
            break :blk acc;
        },
        .vector => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i + 1 < args.len) : (i += 2) {
                const k = args[i];
                if (k.tag() != .integer) {
                    break :blk error_catalog.raise(.type_arg_not_integer, loc, .{
                        .fn_name = "assoc",
                        .actual = @tagName(k.tag()),
                    });
                }
                const idx = k.asInteger();
                if (idx < 0) {
                    break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                        .fn_name = "assoc",
                        .expected = "non-negative integer index for vector",
                        .actual = "negative",
                    });
                }
                const n = vector.count(acc);
                if (idx > n) {
                    break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                        .fn_name = "assoc",
                        .expected = "index in bounds or at tail",
                        .actual = "out of range",
                    });
                }
                acc = try vector.assoc(rt, acc, @intCast(idx), args[i + 1]);
            }
            break :blk acc;
        },
        .typed_instance => blk: {
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind != .defrecord) {
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "assoc",
                    .expected = "map, vector, defrecord, or nil",
                    .actual = @tagName(coll.tag()),
                });
            }
            // Cycle 4 ships single-pair assoc only. Multi-pair on a
            // record would allocate multiple TypedInstance values; the
            // opportunistic 4.5+ cycle that lands `__extmap` overflow
            // would cover this in the same surgery (D-086).
            if (args.len > 3) {
                break :blk error_catalog.raise(.feature_not_supported, loc, .{
                    .name = "multi-pair assoc on defrecord",
                });
            }
            const k = args[1];
            const v = args[2];
            if (k.tag() != .keyword) {
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "assoc",
                    .expected = "keyword key on defrecord",
                    .actual = @tagName(k.tag()),
                });
            }
            const key_name = keyword_mod.asKeyword(k).name;
            const layout = inst.descriptor.field_layout orelse {
                // PROVISIONAL: __extmap overflow deferred [refs: D-086, feature_deps.yaml#runtime/record_extmap]
                break :blk error_catalog.raise(.defrecord_assoc_undeclared_key, loc, .{ .name = key_name });
            };
            var slot_idx: ?u16 = null;
            for (layout) |fe| {
                if (std.mem.eql(u8, fe.name, key_name)) {
                    slot_idx = fe.index;
                    break;
                }
            }
            if (slot_idx == null) {
                // PROVISIONAL: __extmap overflow deferred [refs: D-086, feature_deps.yaml#runtime/record_extmap]
                break :blk error_catalog.raise(.defrecord_assoc_undeclared_key, loc, .{ .name = key_name });
            }
            const old_fields = inst.fields();
            const new_fields = try rt.gpa.alloc(Value, old_fields.len);
            defer rt.gpa.free(new_fields);
            @memcpy(new_fields, old_fields);
            new_fields[slot_idx.?] = v;
            break :blk try td_mod.allocInstance(rt, inst.descriptor, new_fields);
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "assoc",
            .expected = "map, vector, or nil",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- dissoc ---

/// Implements clojure.core/dissoc.
/// Spec: `(dissoc map k)` removes key from map. Map-only.
/// JVM reference: clojure.core/dissoc
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn dissocFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len < 2) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "dissoc",
            .expected = 2,
            .got = args.len,
        });
    }
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                acc = try map.dissoc(rt, acc, args[i]);
            }
            break :blk acc;
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "dissoc",
            .expected = "map",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- keys ---

/// Implements clojure.core/keys.
/// Spec: `(keys m)` returns a seq of map keys, or nil if empty.
/// JVM reference: clojure.core/keys
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn keysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("keys", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            if (map.count(coll) == 0) break :blk .nil_val;
            break :blk try map.keys(rt, coll);
        },
        .typed_instance => blk: {
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind != .defrecord) {
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "keys",
                    .expected = "map or defrecord",
                    .actual = @tagName(coll.tag()),
                });
            }
            const layout = inst.descriptor.field_layout orelse break :blk .nil_val;
            if (layout.len == 0) break :blk .nil_val;
            // Build list backwards so declared-order iteration falls out.
            var result: Value = .nil_val;
            var i: usize = layout.len;
            while (i > 0) {
                i -= 1;
                const kw = try keyword_mod.intern(rt, null, layout[i].name);
                result = try list.consHeap(rt, kw, result);
            }
            break :blk result;
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "keys",
            .expected = "map",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- vals ---

/// Implements clojure.core/vals.
/// Spec: `(vals m)` returns a seq of map values, or nil if empty.
/// JVM reference: clojure.core/vals
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn valsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("vals", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            if (map.count(coll) == 0) break :blk .nil_val;
            break :blk try map.vals(rt, coll);
        },
        .typed_instance => blk: {
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind != .defrecord) {
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "vals",
                    .expected = "map or defrecord",
                    .actual = @tagName(coll.tag()),
                });
            }
            const fields_slice = inst.fields();
            if (fields_slice.len == 0) break :blk .nil_val;
            var result: Value = .nil_val;
            var i: usize = fields_slice.len;
            while (i > 0) {
                i -= 1;
                result = try list.consHeap(rt, fields_slice[i], result);
            }
            break :blk result;
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "vals",
            .expected = "map",
            .actual = @tagName(coll.tag()),
        }),
    };
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "conj", .f = &conjFn },
    .{ .name = "disj", .f = &disjFn },
    .{ .name = "contains?", .f = &containsQFn },
    .{ .name = "get", .f = &getFn },
    .{ .name = "nth", .f = &nthFn },
    .{ .name = "assoc", .f = &assocFn },
    .{ .name = "dissoc", .f = &dissocFn },
    .{ .name = "keys", .f = &keysFn },
    .{ .name = "vals", .f = &valsFn },
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

test "conj nil x → (x)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try conjFn(&fix.rt, &fix.env, &.{ .nil_val, Value.initInteger(42) }, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .list or r.tag() == .cons);
    try testing.expectEqual(@as(i64, 42), list.first(r).asInteger());
}

test "conj vector appends" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    v = try vector.conj(&fix.rt, v, Value.initInteger(2));
    const r = try conjFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(3) }, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .vector);
    try testing.expectEqual(@as(u32, 3), vector.count(r));
    try testing.expectEqual(@as(i64, 3), vector.nth(r, 2).asInteger());
}

test "contains? nil → false" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try containsQFn(&fix.rt, &fix.env, &.{ .nil_val, Value.initInteger(1) }, .{ .line = 0, .column = 0 });
    try testing.expectEqual(Value.false_val, r);
}

test "contains? vector raises type_error (DIVERGENCE D1)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    try testing.expectError(error.TypeError, containsQFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(0) }, .{ .line = 0, .column = 0 }));
}

test "get nil → nil; get nil :a default → default" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r1 = try getFn(&fix.rt, &fix.env, &.{ .nil_val, Value.initInteger(1) }, .{ .line = 0, .column = 0 });
    try testing.expect(r1.isNil());
    const r2 = try getFn(&fix.rt, &fix.env, &.{ .nil_val, Value.initInteger(1), Value.initInteger(99) }, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 99), r2.asInteger());
}

test "nth vector returns indexed element" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(10));
    v = try vector.conj(&fix.rt, v, Value.initInteger(20));
    const r = try nthFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(1) }, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 20), r.asInteger());
}

test "assoc nil :a 1 → {:a 1}" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const k = Value.initInteger(42);
    const v = Value.initInteger(99);
    const r = try assocFn(&fix.rt, &fix.env, &.{ .nil_val, k, v }, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .array_map or r.tag() == .hash_map);
    try testing.expectEqual(@as(u32, 1), map.count(r));
    try testing.expectEqual(@as(i64, 99), (try map.get(r, k)).asInteger());
}
