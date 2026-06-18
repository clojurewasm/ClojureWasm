// SPDX-License-Identifier: EPL-2.0
//! Collection ops — `conj` / `disj` / `contains?` / `get` / `nth` /
//! `assoc` / `dissoc` / `keys` / `vals` per ADR-0033 D6 + v5 §5.2.
//!
//! ## Pattern (sibling of sequence.zig)
//!
//! Same shape as `lang/primitive/sequence.zig`: a Layer 2 Tag switch
//! dispatching to existing Layer 0 collection helpers
//! (`runtime/collection/{vector,list,map,set}.zig`), with a
//! `.protocol_extended` slow-path arm (D-069) for user-extended types
//! alongside the fast-path Tag arms.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: vector, list, map, set
//! Clojure peer: none (Pattern B1 direct intern, public surface)
//!
//! ## File split rationale
//!
//! Collection ops live in their own file (rather than in sequence.zig)
//! to keep each Layer 2 file well under the 1000-line ROADMAP §2 A6
//! cap. The split also tracks the semantic grouping: sequence
//! fundamentals / collection ops / higher-order. The layout is flat
//! (no `core/` subdir).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const lookup = @import("../../runtime/collection/lookup.zig");
const tagged_literal_mod = @import("../../runtime/tagged_literal.zig");

/// Bare protocol-name constants for the D-089 hybrid slow-path family
/// (mirrors `sequence.zig` row 7.7's IPC_FQCN / SEQABLE_FQCN style).
const ILOOKUP_FQCN: []const u8 = "ILookup";
const INDEXED_FQCN: []const u8 = "Indexed";
const ASSOCIATIVE_FQCN: []const u8 = "Associative";
const IPM_FQCN: []const u8 = "IPersistentMap";
const IPS_FQCN: []const u8 = "IPersistentSet";

const sequence = @import("sequence.zig");
const range_mod = @import("../../runtime/collection/range.zig");
const vector = @import("../../runtime/collection/vector.zig");
const java_array = @import("../../runtime/collection/java_array.zig");
const list = @import("../../runtime/collection/list.zig");
const map = @import("../../runtime/collection/map.zig");
const map_entry = @import("../../runtime/collection/map_entry.zig");
const persistent_queue = @import("../../runtime/collection/persistent_queue.zig");
const string = @import("../../runtime/collection/string.zig");
const set = @import("../../runtime/collection/set.zig");
const sorted = @import("../../runtime/collection/sorted.zig");
const transient_vector = @import("../../runtime/collection/transient/transient_vector.zig");
const transient_array_map = @import("../../runtime/collection/transient/transient_array_map.zig");
const transient_hash_set = @import("../../runtime/collection/transient/transient_hash_set.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
// O-033: the reentrant-call helper `update-in`'s leaf `f` rides (no cycle —
// `higher_order` imports `runtime/collection/*`, not this Layer-2 file).
const invokeCallable = @import("higher_order.zig").invokeCallable;

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
    // Clojure conj is variadic: `(conj)` → [], `(conj coll)` → coll,
    // `(conj coll x y …)` → conj each. The 0/1-arg arities are what a
    // bare-`conj` reducing fn (transducer completion / init) relies on.
    if (args.len == 0) return vector.empty();
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = try conjOne(rt, env, acc, args[i], loc);
    }
    return acc;
}

fn conjOne(rt: *Runtime, env: *Env, coll: Value, x: Value, loc: SourceLocation) anyerror!Value {
    if (coll.isNil()) return try list.consHeap(rt, x, .nil_val);
    return switch (coll.tag()) {
        .vector => try vector.conj(rt, coll, x),
        // conj on a MapEntry DROPS the map-entry nature → a plain vector
        // `[k v x]` (clj `AMapEntry.cons` routes through `asVector()`, D-209).
        .map_entry => blk: {
            var vec = try vector.conj(rt, vector.empty(), map_entry.keyOf(coll));
            vec = try vector.conj(rt, vec, map_entry.valOf(coll));
            break :blk try vector.conj(rt, vec, x);
        },
        // conj onto any ISeq is a prepend ≡ `(cons x coll)`. Delegate to
        // the cons primitive so per-seq-tag handling (unforced lazy_seq
        // tail / seq-view over range / string_seq / array_seq) stays
        // single-sourced (F-011) instead of being re-encoded here.
        .list, .cons, .lazy_seq, .chunked_cons, .range, .string_seq, .array_seq => try sequence.consFn(rt, env, &.{ x, coll }, loc),
        .hash_set => try set.conj(rt, coll, x),
        // conj on a queue appends to the rear (FIFO, ADR-0087).
        .persistent_queue => try persistent_queue.conj(rt, coll, x),
        .sorted_set => try sorted.conjSet(rt, env, coll, x, loc),
        .sorted_map => sortedMapConj(rt, env, coll, x, loc),
        .array_map, .hash_map => mapConj(rt, coll, x, loc),
        // A defrecord conjs like a map (D-086 / ADR-0154): a `[k v]` / map-entry
        // assocs the pair, a map merges its entries — all extmap-aware, record-
        // ness preserved (clj's defrecord `cons`). A user `-cons` impl wins first;
        // a deftype/reify falls through to the protocol dispatch below.
        .typed_instance => blk: {
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, "IPersistentCollection", "-cons", &.{ coll, x }, loc)) |v| break :blk v;
                break :blk try recordConj(rt, coll, x, loc);
            }
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, "IPersistentCollection", "-cons", &.{ coll, x }, loc);
        },
        else => blk: {
            // Row 7.7 cycle 3: outer-else routes through dispatch against
            // `IPersistentCollection -cons` (JVM `RT.conj` dispatches via
            // `IPersistentCollection.cons`). Reaches `(extend-type X
            // IPersistentCollection (-cons [c x] …))` on reified_instance /
            // native-Tag receivers via the row 7.3 per-Tag descriptor registry.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, "IPersistentCollection", "-cons", &.{ coll, x }, loc);
        },
    };
}

/// `map.forEachEntry` accumulator: conj each entry of a map onto a record by
/// re-minting through `recordAssoc1` (D-086 — `(conj rec a-map)` / `(into rec
/// a-map)` folds every entry into the record, extmap-aware).
const RecordConjCtx = struct {
    rt: *Runtime,
    acc: *Value,
    fn cb(ctx: *RecordConjCtx, k: Value, v: Value) anyerror!void {
        ctx.acc.* = try recordAssoc1(ctx.rt, ctx.acc.*, k, v);
    }
};

/// `(conj record x)` for a defrecord (clj's defrecord `cons`): a `[k v]` vector
/// or map-entry assocs the pair; a map merges every entry; nil is a no-op. A
/// non-pair vector or a non-collection raises (clj parity). `rec` is a defrecord.
fn recordConj(rt: *Runtime, rec: Value, x: Value, loc: SourceLocation) anyerror!Value {
    switch (x.tag()) {
        .nil => return rec,
        .map_entry => return recordAssoc1(rt, rec, map_entry.keyOf(x), map_entry.valOf(x)),
        .vector => {
            if (vector.count(x) != 2)
                return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "conj", .expected = "[k v] pair when conj-ing onto a record", .actual = "vector of different arity" });
            return recordAssoc1(rt, rec, vector.nth(x, 0), vector.nth(x, 1));
        },
        .array_map, .hash_map => {
            var acc = rec;
            var ctx = RecordConjCtx{ .rt = rt, .acc = &acc };
            try map.forEachEntry(x, &ctx, RecordConjCtx.cb);
            return acc;
        },
        else => return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "conj", .expected = "[k v] pair, map-entry, or map when conj-ing onto a record", .actual = @tagName(x.tag()) }),
    }
}

fn mapConj(rt: *Runtime, m: Value, entry: Value, loc: SourceLocation) anyerror!Value {
    // (conj m (first other-map)) — a MapEntry is a [k v] pair too (D-209).
    if (entry.tag() == .map_entry) {
        return try map.assoc(rt, m, map_entry.keyOf(entry), map_entry.valOf(entry));
    }
    // (conj m [k v]) — vector pair gets destructured into assoc. A non-pair
    // entry → IllegalArgumentException in clj (PersistentArrayMap.cons), NOT
    // ClassCastException. D-459.
    if (entry.tag() != .vector) {
        return error_catalog.raise(.arg_value_invalid, loc, .{
            .fn_name = "conj",
            .expected = "[k v] vector when conj-ing into a map",
            .actual = @tagName(entry.tag()),
        });
    }
    if (vector.count(entry) != 2) {
        return error_catalog.raise(.arg_value_invalid, loc, .{
            .fn_name = "conj",
            .expected = "2-element [k v] vector for map conj",
            .actual = "vector of different arity",
        });
    }
    return try map.assoc(rt, m, vector.nth(entry, 0), vector.nth(entry, 1));
}

fn sortedMapConj(rt: *Runtime, env: *Env, m: Value, entry: Value, loc: SourceLocation) anyerror!Value {
    // (conj sorted-map (first other-map)) — a MapEntry is a [k v] pair (D-209).
    if (entry.tag() == .map_entry) {
        return try sorted.assoc(rt, env, m, map_entry.keyOf(entry), map_entry.valOf(entry), loc);
    }
    // (conj sorted-map [k v]) — same [k v]-pair contract as hash/array map.
    if (entry.tag() != .vector or vector.count(entry) != 2) {
        return error_catalog.raise(.arg_value_invalid, loc, .{
            .fn_name = "conj",
            .expected = "2-element [k v] vector when conj-ing into a map",
            .actual = @tagName(entry.tag()),
        });
    }
    return try sorted.assoc(rt, env, m, vector.nth(entry, 0), vector.nth(entry, 1), loc);
}

// --- disj ---

/// Implements clojure.core/disj.
/// Spec: `(disj set k)` removes k from set. Set-only.
/// JVM reference: clojure.core/disj → IPersistentSet.disjoin
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn disjFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("disj", args, 2, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .hash_set => try set.disj(rt, coll, args[1]),
        .sorted_set => try sorted.disjSet(rt, env, coll, args[1], loc),
        else => blk: {
            // D-089 row 8.6 cycle 4: IPersistentSet -disjoin slow-path
            // (close cycle for the retro-audit cluster).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPS_FQCN, "-disjoin", args, loc);
        },
    };
}

// --- contains? ---

/// Implements clojure.core/contains?.
/// Spec: `(contains? coll key)` — set: membership; map: has-key;
/// vector: INDEX validity (`integer? k ∧ 0 ≤ k < count`), the documented
/// JVM gotcha. Per ADR-0069 cljw matches JVM here (F-011 behavioural
/// equivalence; the prior DIVERGENCE D1 reject-as-type_error was a
/// pre-F-011 judgment-divergence, reversed because real code —
/// `clojure.data/diff` — depends on vector contains? returning false on
/// an out-of-range index rather than throwing).
/// JVM reference: clojure.lang.RT.contains
/// cw v1 tier: A (Phase 6.16.a-2; vector arm ADR-0069)
pub fn containsQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("contains?", args, 2, loc);
    const coll = args[0];
    if (coll.isNil()) return .false_val;
    const k = args[1];
    return switch (coll.tag()) {
        .hash_set => if (try set.contains(coll, k)) .true_val else .false_val,
        .sorted_set => if (try sorted.setContains(rt, env, coll, k, loc)) .true_val else .false_val,
        .sorted_map => if (try sorted.contains(rt, env, coll, k, loc)) .true_val else .false_val,
        .array_map, .hash_map => if (try map.contains(coll, k)) .true_val else .false_val,
        // A vector is Indexed: `contains?` tests index validity, NOT element
        // membership. A non-integer key is simply absent (false), not an error
        // (matches clj `(contains? [1 2 3] :x)` → false).
        .vector => blk: {
            if (k.tag() != .integer) break :blk .false_val;
            const idx: i64 = k.asInteger();
            break :blk if (idx >= 0 and idx < @as(i64, vector.count(coll))) .true_val else .false_val;
        },
        // A MapEntry is a 2-vector: indices 0 and 1 are valid (D-209).
        .map_entry => blk: {
            if (k.tag() != .integer) break :blk .false_val;
            const idx: i64 = k.asInteger();
            break :blk if (idx == 0 or idx == 1) .true_val else .false_val;
        },
        // A String is Indexed: `contains?` tests index validity (D-217;
        // clj `(contains? "abc" 1)` → true, `(contains? "abc" 10)` → false).
        .string => blk: {
            if (k.tag() != .integer) break :blk .false_val;
            const idx: i64 = k.asInteger();
            break :blk if (idx >= 0 and idx < @as(i64, @intCast(string.codepointCount(string.asString(coll))))) .true_val else .false_val;
        },
        // A live transient mirrors its persistent peer (clj parity, D-199):
        // map/set by key/element membership; vector by index validity.
        .transient_map => if (try transient_array_map.contains(coll, k)) .true_val else .false_val,
        .transient_set => if (try transient_hash_set.contains(coll, k)) .true_val else .false_val,
        .transient_vector => blk: {
            if (k.tag() != .integer) break :blk .false_val;
            const idx: i64 = k.asInteger();
            break :blk if (idx >= 0 and idx < @as(i64, transient_vector.count(coll))) .true_val else .false_val;
        },
        // A defrecord answers `contains?` for its declared field keys (D-262).
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ASSOCIATIVE_FQCN, "-contains-key?", args, loc)) |v| break :blk v;
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) {
                const layout = inst.descriptor.field_layout orelse break :blk .false_val;
                for (layout) |f| {
                    if ((try keyword_mod.intern(rt, null, f.name)) == k) break :blk .true_val;
                }
                // D-086 / ADR-0154: a non-declared key may live in the extmap.
                if (!inst.extmap.isNil() and try map.contains(inst.extmap, k)) break :blk .true_val;
                break :blk .false_val;
            }
            // A deftype SET answers `contains?` via membership: clj's `contains?`
            // calls IPersistentSet.contains, but a real-world set (flatland.ordered)
            // writes that method under the java.util.Set header (host_inert, not
            // dispatchable here). cljw wires IPersistentSet/get → ILookup/-lookup,
            // and a set's `get` returns the element-or-nil — so `(some? (-lookup s k))`
            // is the portable membership test, independent of which header `contains`
            // sits under. (Divergence: a set literally holding nil/false mis-reports —
            // exotic for a custom deftype-set; the common case is exact.)
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ILOOKUP_FQCN, "-lookup", args, loc)) |v|
                break :blk if (v.isNil()) .false_val else .true_val;
            break :blk try dispatch.dispatch(rt, env, &cs, coll, ASSOCIATIVE_FQCN, "-contains-key?", args, loc);
        },
        else => blk: {
            // D-089 row 8.6 cycle 3: Associative -contains-key? slow-path.
            // DIVERGENCE D2 (survey §6): unifies JVM's
            // `Associative.containsKey` + `IPersistentSet.contains` under
            // one protocol surface; user-extended sets respond on the
            // same protocol as user-extended maps.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, ASSOCIATIVE_FQCN, "-contains-key?", args, loc);
        },
    };
}

// --- get ---

/// Implements clojure.core/get.
/// Spec: `(get coll k)` returns value at k, or nil. `(get coll k
/// default)` returns default if absent.
/// JVM reference: clojure.lang.RT.get
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn getFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
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
        .sorted_map => blk: {
            if (try sorted.contains(rt, env, coll, k, loc)) {
                break :blk try sorted.get(rt, env, coll, k, loc);
            }
            break :blk default;
        },
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
        // A MapEntry is a 2-vector: `(get entry 0/1)` → key/val (D-209).
        .map_entry => blk: {
            if (k.tag() != .integer) break :blk default;
            const idx = k.asInteger();
            break :blk if (idx == 0 or idx == 1) map_entry.nth(coll, @intCast(idx)) else default;
        },
        // A String is index-gettable (clj `(get "abc" 1)` → \b): return the
        // codepoint char, else default (OOR / non-integer key). D-217.
        .string => blk: {
            if (k.tag() != .integer) break :blk default;
            const idx = k.asInteger();
            if (idx >= 0) {
                if (string.codepointAt(string.asString(coll), @intCast(idx))) |cp|
                    break :blk Value.initChar(cp);
            }
            break :blk default;
        },
        // A live transient is a first-class read target (clj parity, D-199):
        // a transient map reads by key; a transient vector by index.
        .transient_map => blk: {
            if (try transient_array_map.contains(coll, k)) {
                break :blk try transient_array_map.get(coll, k);
            }
            break :blk default;
        },
        .transient_vector => blk: {
            if (k.tag() != .integer) break :blk default;
            break :blk transient_vector.nth(coll, k.asInteger(), default);
        },
        // Declared field → ILookup -lookup slow-path → default. Shared
        // with the keyword-as-fn `(:k rec)` path so the two agree (D-089).
        .typed_instance => try lookup.recordGet(rt, env, coll, k, args.len == 3, default, loc),
        // TaggedLiteral is ILookup-only (`:tag`/`:form`); ADR-0075.
        .tagged_literal => tagged_literal_mod.valAt(coll, k, default),
        // Any other value carrying an ILookup `-lookup` extension — a reify
        // instance (.reified_instance) or an extend-type'd native. Route through
        // the shared lookupDispatch so a 3-arity `(get x k default)` consults the
        // 3-arity -lookup and applies `default` on a nil 2-arity result, exactly
        // as the typed_instance (recordGet) path does. The prior 2-arity-only
        // consult here returned the raw -lookup nil for an absent key, ignoring
        // the explicit default (surfaced making reify ILookup remap-aware, D-419
        // follow-on). lookupDispatch (NOT recordGet — these tags have no field
        // layout to decode) returns `default` when no -lookup extension exists
        // (D-089 row 8.6 historic semantic preserved).
        else => try lookup.lookupDispatch(rt, env, coll, k, args.len == 3, default, loc),
    };
}

// --- nth ---

/// Implements clojure.core/nth.
/// Spec: `(nth coll i)` returns the i-th item. Index error if i is
/// out of range. `(nth coll i default)` returns default on out-of-range.
/// JVM reference: clojure.lang.RT.nth
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn nthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
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
                break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
            }
            break :blk vector.nth(coll, @intCast(idx));
        },
        // A MapEntry is a 2-vector: index 0→key, 1→val (D-209 / ADR-0078).
        .map_entry => blk: {
            if (idx == 0 or idx == 1) break :blk map_entry.nth(coll, @intCast(idx));
            if (has_default) break :blk default;
            break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
        },
        // ADR-0105: a Java array is Indexed; `nth` keys to `aget` (with the
        // default-arg discipline the other Indexed arms use).
        .array => blk: {
            if (idx < 0 or idx >= @as(i64, java_array.alength(coll))) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
            }
            break :blk try java_array.aget(coll, idx, "nth", loc);
        },
        // A live transient vector is Indexed (clj parity, D-199) — same
        // index discipline as a persistent vector.
        .transient_vector => blk: {
            if (idx < 0) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "nth",
                    .expected = "non-negative integer index",
                    .actual = "negative",
                });
            }
            if (idx >= transient_vector.count(coll)) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
            }
            break :blk transient_vector.nth(coll, idx, default);
        },
        .list, .cons => blk: {
            if (idx < 0) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
            }
            var cur: Value = coll;
            var remaining: i64 = idx;
            while (remaining > 0) : (remaining -= 1) {
                cur = list.rest(cur);
                if (cur.isNil()) {
                    if (has_default) break :blk default;
                    break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
                }
            }
            break :blk list.first(cur);
        },
        // PERF: O(1) nth on a compact range — `start + i*step`, no walk [refs: O-001]
        .range => blk: {
            if (idx < 0 or idx >= range_mod.countOf(coll)) {
                if (has_default) break :blk default;
                break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
            }
            break :blk range_mod.elementAt(coll, idx);
        },
        // A String is Indexed (clj `(nth "abc" 1)` → \b): return the
        // codepoint char at `idx`. OOR → default, or throw (clj
        // StringIndexOutOfBounds) when no default. D-217.
        .string => blk: {
            if (idx >= 0) {
                if (string.codepointAt(string.asString(coll), @intCast(idx))) |cp|
                    break :blk Value.initChar(cp);
            }
            if (has_default) break :blk default;
            break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
        },
        // Seq family (lazy producers): `(nth (map f xs) i)`. JVM `RT.nth`
        // walks any seq; route through the shared seq-walk (forces lazy
        // layers). D-168 made `map`/`filter` results lazy seqs.
        .lazy_seq, .chunked_cons => blk: {
            if (try sequence.nthSeq(rt, env, coll, idx, loc)) |v| break :blk v;
            if (has_default) break :blk default;
            break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
        },
        else => blk: {
            // D-089 row 8.6 cycle 2: Indexed -nth slow-path. With an explicit
            // default, the deftype's 3-arity `(nth [_ i nf])` impl is consulted
            // FIRST (clj RT.nth(coll,i,nf) calls Indexed.nth(i,nf)); a type
            // declaring only the 2-arity falls back to it (D-400/D-397).
            if (has_default) {
                var cs3: dispatch.CallSite = .{};
                const slow3 = [_]Value{ coll, i_val, default };
                if (dispatch.dispatchOrNull(rt, env, &cs3, coll, INDEXED_FQCN, "-nth", &slow3, loc)) |maybe| {
                    if (maybe) |r| break :blk r;
                } else |_| {
                    // 3-arity call failed (2-arity-only impl) — fall through.
                }
            }
            var cs: dispatch.CallSite = .{};
            const slow_args = [_]Value{ coll, i_val };
            break :blk try dispatch.dispatch(rt, env, &cs, coll, INDEXED_FQCN, "-nth", &slow_args, loc);
        },
    };
}

// --- assoc ---

/// `map.forEachEntry` accumulator: assoc each visited extmap entry into the
/// pointed-to map (D-086 — fold a record's extmap into a demoted plain map).
const ExtmapMergeCtx = struct {
    rt: *Runtime,
    m: *Value,
    fn cb(ctx: *ExtmapMergeCtx, k: Value, v: Value) anyerror!void {
        ctx.m.* = try map.assoc(ctx.rt, ctx.m.*, k, v);
    }
};

/// Re-mint a defrecord with one key set (D-086 / ADR-0154). A declared field
/// (per the descriptor's `fieldSlotByName` partition chokepoint) writes its
/// slot; any other key (a non-declared keyword, or a non-keyword) lands in the
/// extmap. `meta` and the rest of the field/extmap state are preserved, so
/// folding pairs through this composes (clj records preserve meta + accumulate
/// extras across assoc/update). `rec` must be a `.typed_instance` defrecord.
fn recordAssoc1(rt: *Runtime, rec: Value, k: Value, v: Value) !Value {
    const inst = rec.decodePtr(*const td_mod.TypedInstance);
    if (k.tag() == .keyword) {
        if (inst.descriptor.fieldSlotByName(keyword_mod.asKeyword(k).name)) |slot| {
            const old_fields = inst.fields();
            const new_fields = try rt.gpa.alloc(Value, old_fields.len);
            defer rt.gpa.free(new_fields);
            @memcpy(new_fields, old_fields);
            new_fields[slot] = v;
            return td_mod.allocInstanceFull(rt, inst.descriptor, new_fields, inst.meta, inst.extmap);
        }
    }
    // Non-declared key → extmap. Seed an empty map when the record had none.
    var ext = inst.extmap;
    if (ext.isNil()) ext = map.empty();
    ext = try map.assoc(rt, ext, k, v);
    return td_mod.allocInstanceFull(rt, inst.descriptor, inst.fields(), inst.meta, ext);
}

/// Implements clojure.core/assoc.
/// Spec: `(assoc map k v)` returns new map with k→v.
/// `(assoc vec i v)` returns new vector with index i replaced.
/// `(assoc nil k v)` returns `{k v}` (per JVM).
/// JVM reference: clojure.lang.RT.assoc
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn assocFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
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
        .sorted_map => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i + 1 < args.len) : (i += 2) {
                acc = try sorted.assoc(rt, env, acc, args[i], args[i + 1], loc);
            }
            break :blk acc;
        },
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
                // clj: a non-integer key on a vector assoc → IllegalArgumentException;
                // an out-of-range (incl. negative) index → IndexOutOfBoundsException
                // (NOT the ClassCastException of a plain type slot). D-459.
                if (k.tag() != .integer) {
                    break :blk error_catalog.raise(.arg_value_invalid, loc, .{
                        .fn_name = "assoc",
                        .expected = "an integer key for a vector",
                        .actual = @tagName(k.tag()),
                    });
                }
                const idx = k.asInteger();
                if (idx < 0) {
                    break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "assoc" });
                }
                const n = vector.count(acc);
                if (idx > n) {
                    break :blk error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "assoc" });
                }
                acc = try vector.assoc(rt, acc, @intCast(idx), args[i + 1]);
            }
            break :blk acc;
        },
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            // A deftype/reify (non-record) implementing Associative `-assoc` takes
            // the protocol path. D-378: multi-pair assoc folds over pairs into
            // repeated single-pair `-assoc` (clj reduces over pairs), so
            // `(assoc m k1 v1 k2 v2 …)` works — e.g. flatland.ordered's ordered-map
            // ctor `(apply assoc empty-ordered-map …)`. args.len is validated odd≥3
            // at the top; a deftype with no `-assoc` impl raises a proper no-impl
            // error via `dispatch`. D-280c: a deftype is not a defrecord, so the
            // record-only branch below must not capture it.
            if (inst.descriptor.kind != .defrecord) {
                var acc: Value = coll;
                var i: usize = 1;
                while (i + 1 < args.len) : (i += 2) {
                    var cs2: dispatch.CallSite = .{};
                    acc = try dispatch.dispatch(rt, env, &cs2, acc, ASSOCIATIVE_FQCN, "-assoc", &.{ acc, args[i], args[i + 1] }, loc);
                }
                break :blk acc;
            }
            // A defrecord with a custom single-pair `-assoc` impl takes it first.
            if (args.len == 3) {
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ASSOCIATIVE_FQCN, "-assoc", args, loc)) |v| break :blk v;
            }
            // D-086 / ADR-0154: fold over pairs (clj reduces over kv pairs). Each
            // pair routes through `recordAssoc1`: a declared field writes its
            // slot; a non-declared key lands in the extmap. Multi-pair re-mints
            // per pair (correctness-first; extras are rare).
            var acc: Value = coll;
            var i: usize = 1;
            while (i + 1 < args.len) : (i += 2) {
                acc = try recordAssoc1(rt, acc, args[i], args[i + 1]);
            }
            break :blk acc;
        },
        else => blk: {
            // D-089 row 8.6 cycle 3: Associative -assoc slow-path for a non-native
            // receiver `(extend-type X Associative (-assoc [c k v] …))`. D-378:
            // multi-pair folds over pairs into repeated single-pair `-assoc` (clj
            // reduces over pairs), so `(assoc x k1 v1 k2 v2 …)` works. args.len is
            // validated odd≥3 at the top.
            var acc: Value = coll;
            var i: usize = 1;
            while (i + 1 < args.len) : (i += 2) {
                var cs: dispatch.CallSite = .{};
                acc = try dispatch.dispatch(rt, env, &cs, acc, ASSOCIATIVE_FQCN, "-assoc", &.{ acc, args[i], args[i + 1] }, loc);
            }
            break :blk acc;
        },
    };
}

// --- dissoc ---

/// Implements clojure.core/dissoc.
/// Spec: `(dissoc map k)` removes key from map. Map-only.
/// JVM reference: clojure.core/dissoc
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn dissocFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 1) {
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "dissoc",
            .expected = 1,
            .got = args.len,
        });
    }
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    // clj 1-arity: `(dissoc map)` returns the map untouched (core.cache's
    // defcache seed path reduces dissoc over possibly-zero keys).
    if (args.len == 1) return coll;
    return switch (coll.tag()) {
        .array_map, .hash_map => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                acc = try map.dissoc(rt, acc, args[i]);
            }
            break :blk acc;
        },
        .sorted_map => blk: {
            var acc: Value = coll;
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                acc = try sorted.dissoc(rt, env, acc, args[i], loc);
            }
            break :blk acc;
        },
        // A defrecord: dissoc of a DECLARED key degrades to a map (a record can't
        // drop a declared field, clj parity), folding in any extmap entries;
        // dissoc of an extmap key removes it (normalizing the emptied extmap back
        // to nil); dissoc of an absent key returns the record unchanged (D-262 /
        // D-086 / ADR-0154).
        .typed_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPM_FQCN, "-without", args, loc)) |v| break :blk v;
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind != .defrecord)
                break :blk try dispatch.dispatch(rt, env, &cs, coll, IPM_FQCN, "-without", args, loc);
            const layout = inst.descriptor.field_layout orelse break :blk coll;
            const fields = inst.fields();
            // Does any removed key name a DECLARED field? (clj demotes to a map.)
            var any_declared = false;
            var ai: usize = 1;
            while (ai < args.len) : (ai += 1) {
                if (args[ai].tag() == .keyword and
                    inst.descriptor.fieldSlotByName(keyword_mod.asKeyword(args[ai]).name) != null)
                    any_declared = true;
            }
            if (any_declared) {
                // Demote to a plain map: ALL declared fields + ALL extmap entries,
                // then dissoc every removed key (declared order then extmap order).
                var m = map.empty();
                for (layout, 0..) |f, i| {
                    m = try map.assoc(rt, m, try keyword_mod.intern(rt, null, f.name), fields[i]);
                }
                if (!inst.extmap.isNil()) {
                    var ctx = ExtmapMergeCtx{ .rt = rt, .m = &m };
                    try map.forEachEntry(inst.extmap, &ctx, ExtmapMergeCtx.cb);
                }
                ai = 1;
                while (ai < args.len) : (ai += 1) m = try map.dissoc(rt, m, args[ai]);
                break :blk m;
            }
            // No declared field removed. Drop any extmap keys; record-ness kept.
            if (inst.extmap.isNil()) break :blk coll;
            var ext = inst.extmap;
            var changed = false;
            ai = 1;
            while (ai < args.len) : (ai += 1) {
                const before = map.count(ext);
                ext = try map.dissoc(rt, ext, args[ai]);
                if (map.count(ext) != before) changed = true;
            }
            if (!changed) break :blk coll;
            // Emptied extmap normalizes to nil so the result `=` a fresh record.
            if (map.count(ext) == 0) ext = .nil_val;
            break :blk try td_mod.allocInstanceFull(rt, inst.descriptor, fields, inst.meta, ext);
        },
        else => blk: {
            // D-089 row 8.6 cycle 3: IPersistentMap -without slow-path.
            // Single-key only; multi-key extension folds via reduce in
            // user code (same shape as the assoc outer-else).
            if (args.len != 2) {
                break :blk error_catalog.raise(.feature_not_supported, loc, .{
                    .name = "multi-key dissoc on extend-type IPersistentMap receiver",
                });
            }
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPM_FQCN, "-without", args, loc);
        },
    };
}

// --- keys ---

/// Implements clojure.core/keys.
/// Spec: `(keys m)` returns a seq of map keys, or nil if empty.
/// JVM reference: clojure.core/keys
/// cw v1 tier: A (Phase 6.16.a-2)
/// D-285: derive `keys`/`vals` for a seqable map deftype that doesn't impl
/// `-keys`/`-vals` — `(map key/val (seq coll))`, clj-faithful. `col` is 0 (key) or
/// 1 (val) of each entry (cljw's entries are 2-vectors). Walks `(seq coll)` via the
/// seq protocol (firstFn/nextFn), mirroring apply's accumulator walk in
/// higher_order.zig (same GC-safety). Returns a list in seq order, or nil if empty.
fn seqDeriveEntryColumn(rt: *Runtime, env: *Env, coll: Value, col: u32, loc: SourceLocation) anyerror!Value {
    var cells: std.ArrayList(Value) = .empty;
    defer cells.deinit(rt.gpa);
    var cur = try sequence.seqFn(rt, env, &.{coll}, loc);
    while (!cur.isNil()) {
        const entry = try sequence.firstFn(rt, env, &.{cur}, loc);
        // An entry is a 2-vector (a deftype's `(MapEntry. k v)`, D-284) OR a native
        // `.map_entry` (when the deftype's seq delegates to a native map's seq).
        const cell = switch (entry.tag()) {
            .map_entry => map_entry.nth(entry, col),
            else => vector.nth(entry, col),
        };
        try cells.append(rt.gpa, cell);
        cur = try sequence.nextFn(rt, env, &.{cur}, loc);
    }
    if (cells.items.len == 0) return .nil_val;
    var result: Value = .nil_val;
    var i: usize = cells.items.len;
    while (i > 0) {
        i -= 1;
        result = try list.consHeap(rt, cells.items[i], result);
    }
    return result;
}

pub fn keysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("keys", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .sorted_map => blk: {
            if (sorted.count(coll) == 0) break :blk .nil_val;
            break :blk try sorted.keys(rt, coll);
        },
        .array_map, .hash_map => blk: {
            if (map.count(coll) == 0) break :blk .nil_val;
            break :blk try map.keys(rt, coll);
        },
        // deftype + reify share one arm (D-426): a reify map (declares IPersistentMap)
        // must derive keys the same way a deftype does, not fall into the else arm's
        // bare -keys dispatch that errors (the D-422/D-423 reify-bypass class).
        .typed_instance, .reified_instance => blk: {
            const desc = td_mod.descriptorOfInstance(coll);
            if (desc.kind == .defrecord) {
                const layout = desc.field_layout orelse break :blk .nil_val;
                // D-086 / ADR-0154: seed the tail with the extmap keys (in extmap
                // order), then prepend declared keys in declaration order, so the
                // result is `(declared… extmap…)`. Empty record + empty extmap → nil.
                const ext = coll.decodePtr(*const td_mod.TypedInstance).extmap;
                var result: Value = if (ext.isNil()) .nil_val else try map.keys(rt, ext);
                var i: usize = layout.len;
                while (i > 0) {
                    i -= 1;
                    const kw = try keyword_mod.intern(rt, null, layout[i].name);
                    result = try list.consHeap(rt, kw, result);
                }
                break :blk result;
            }
            // D-285: a non-record map deftype/reify (priority-map etc.). clj keys/vals
            // require an IPersistentMap (else ClassCastException) — gate on it, then try
            // the optional -keys impl, else derive from seq: keys = (map key (seq m)).
            if (desc.isPersistentMap()) {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPM_FQCN, "-keys", args, loc)) |v| break :blk v;
                break :blk try seqDeriveEntryColumn(rt, env, coll, 0, loc);
            }
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = IPM_FQCN,
                .method = "-keys",
                .type_name = desc.fqcn orelse "<anonymous>",
            });
        },
        else => blk: {
            // D-089 row 8.6 cycle 3: IPersistentMap -keys slow-path.
            // DIVERGENCE D1 (survey §6): JVM has no -keys protocol
            // method (keys = seq over keyset); cw v1 surfaces it
            // direct to keep user-extension parsimonious.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPM_FQCN, "-keys", args, loc);
        },
    };
}

// --- vals ---

/// Implements clojure.core/vals.
/// Spec: `(vals m)` returns a seq of map values, or nil if empty.
/// JVM reference: clojure.core/vals
/// cw v1 tier: A (Phase 6.16.a-2)
pub fn valsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("vals", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .sorted_map => blk: {
            if (sorted.count(coll) == 0) break :blk .nil_val;
            break :blk try sorted.vals(rt, coll);
        },
        .array_map, .hash_map => blk: {
            if (map.count(coll) == 0) break :blk .nil_val;
            break :blk try map.vals(rt, coll);
        },
        // deftype + reify share one arm (see keysFn / D-426).
        .typed_instance, .reified_instance => blk: {
            const desc = td_mod.descriptorOfInstance(coll);
            if (desc.kind == .defrecord) {
                const inst = coll.decodePtr(*const td_mod.TypedInstance);
                const fields_slice = inst.fields();
                // D-086 / ADR-0154: extmap vals tail (extmap order), then declared
                // vals prepended in declaration order → `(declared… extmap…)`,
                // pairing with `keys`. Empty record + empty extmap → nil.
                var result: Value = if (inst.extmap.isNil()) .nil_val else try map.vals(rt, inst.extmap);
                var i: usize = fields_slice.len;
                while (i > 0) {
                    i -= 1;
                    result = try list.consHeap(rt, fields_slice[i], result);
                }
                break :blk result;
            }
            // D-285: non-record map deftype/reify — gate on IPersistentMap (clj vals
            // requires it), then -vals impl, else derive from seq (vals = (map val
            // (seq m))). col 1 = val of each 2-vector entry.
            if (desc.isPersistentMap()) {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPM_FQCN, "-vals", args, loc)) |v| break :blk v;
                break :blk try seqDeriveEntryColumn(rt, env, coll, 1, loc);
            }
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = IPM_FQCN,
                .method = "-vals",
                .type_name = desc.fqcn orelse "<anonymous>",
            });
        },
        else => blk: {
            // D-089 row 8.6 cycle 3: IPersistentMap -vals slow-path
            // (DIVERGENCE D1 mirror of -keys above).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPM_FQCN, "-vals", args, loc);
        },
    };
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

/// `(queue? x)` — true iff `x` is a PersistentQueue (ADR-0087). Used by
/// core.clj's `peek`/`pop` to route to the queue stack ops.
pub fn queueQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("queue?", args, 1, loc);
    return if (args[0].tag() == .persistent_queue) .true_val else .false_val;
}

/// `(-queue-pop q)` — drop the oldest element (ADR-0087). The Clojure-level
/// `pop` routes a queue here; pop of empty returns the empty queue (no throw).
pub fn queuePopFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("-queue-pop", args, 1, loc);
    if (args[0].tag() != .persistent_queue)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "-queue-pop", .expected = "a queue", .actual = @tagName(args[0].tag()) });
    return persistent_queue.pop(rt, args[0]);
}

/// `#queue (e1 e2 …)` data-reader (ADR-0087): build a queue by conj-ing the
/// form's elements in order. cljw extension (clj has no `#queue` reader); makes
/// the cljw print form reader-round-trippable.
pub fn queueReader(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("#queue", args, 1, loc);
    var q = try persistent_queue.emptyQueue(rt);
    var cur = try sequence.seqFn(rt, env, args[0..1], loc);
    while (cur.tag() == .list and list.countOf(cur) > 0) {
        q = try persistent_queue.conj(rt, q, list.first(cur));
        cur = list.rest(cur);
    }
    return q;
}

/// `(rt/__kv-reduce-or m f init sentinel)` — dispatch IKVReduce/-kv-reduce
/// on `m` (a deftype declaring `kvreduce`, D-400); return `sentinel` when no
/// impl exists so `reduce-kv` (core.clj) takes its keys fallback (records /
/// plain associatives).
pub fn kvReduceOrFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("__kv-reduce-or", args, 4, loc);
    var cs: dispatch.CallSite = .{};
    if (try dispatch.dispatchOrNull(rt, env, &cs, args[0], "IKVReduce", "-kv-reduce", args[0..3], loc)) |r| return r;
    return args[3];
}

/// PERF: O-033 in-Zig `update-in` descent/ascent. Walks the (vector) path in Zig
/// — `get` each level down, call `f` at the leaf via `invokeCallable`, `assoc` back
/// up — replacing the `.clj` `-update-in-idx` recursion (N frames + per-level
/// `nth`/`get`/`assoc` prim calls). The `.clj` `update-in` keeps the variadic
/// `& args` arity and routes only a NON-EMPTY VECTOR path here. [refs: O-033, O-004]
///
/// GC-ROOT: O-033 — reentrant-primitive frame [f, m, ks, child] (mirrors reduceFn /
/// chunk_transform O-032) [ref: .dev/gc_rooting.md]. `m` (slot 1) transitively roots
/// the whole descent chain — every parent map is a sub-value of the original `m`, so
/// no per-level descent root is needed. The ONLY eval reentry is the leaf `f`. The
/// ascent `assoc`s allocate NEW maps (not reachable from `m`), so slot 3 (`child`) is
/// re-rooted before each `assoc` so an alloc-driven collect cannot sweep the
/// in-progress result.
pub fn updateInFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("-update-in", args, 3, loc);
    const m = args[0];
    const ks = args[1]; // guaranteed a non-empty vector by the `.clj` `update-in` guard
    const f = args[2];
    const n = vector.count(ks);
    var gc_roots: [4]Value = .{ f, m, ks, .nil_val };
    var gc_sp: u16 = 4;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    return updateInRec(rt, env, m, ks, 0, n, f, loc, &gc_roots);
}

fn updateInRec(rt: *Runtime, env: *Env, m: Value, ks: Value, i: u32, n: u32, f: Value, loc: SourceLocation, gc_roots: *[4]Value) anyerror!Value {
    const k = vector.nth(ks, i);
    if (i + 1 == n) {
        // leaf: (assoc m k (f (get m k)))
        const old = try getFn(rt, env, &.{ m, k }, loc);
        const nv = try invokeCallable(rt, env, f, &.{old}, loc);
        gc_roots[3] = nv; // root the new leaf value across the assoc alloc
        return try assocFn(rt, env, &.{ m, k, nv }, loc);
    }
    // descend: (assoc m k (update-in (get m k) (rest path) f))
    const child = try updateInRec(rt, env, try getFn(rt, env, &.{ m, k }, loc), ks, i + 1, n, f, loc, gc_roots);
    gc_roots[3] = child; // root the new sub-map across this level's assoc alloc
    return try assocFn(rt, env, &.{ m, k, child }, loc);
}

const ENTRIES = [_]Entry{
    .{ .name = "conj", .f = &conjFn },
    .{ .name = "-update-in", .f = &updateInFn },
    .{ .name = "__kv-reduce-or", .f = &kvReduceOrFn },
    .{ .name = "queue?", .f = &queueQFn },
    .{ .name = "-queue-pop", .f = &queuePopFn },
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

test "contains? vector tests index validity (ADR-0069, JVM-match)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    v = try vector.conj(&fix.rt, v, Value.initInteger(2));
    const loc: SourceLocation = .{ .line = 0, .column = 0 };
    // valid index → true; out-of-range → false; non-integer → false (no throw).
    try testing.expectEqual(Value.true_val, try containsQFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(1) }, loc));
    try testing.expectEqual(Value.false_val, try containsQFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(5) }, loc));
    try testing.expectEqual(Value.false_val, try containsQFn(&fix.rt, &fix.env, &.{ v, Value.initInteger(-1) }, loc));
    const kw = try keyword_mod.intern(&fix.rt, null, "x");
    try testing.expectEqual(Value.false_val, try containsQFn(&fix.rt, &fix.env, &.{ v, kw }, loc));
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
