// SPDX-License-Identifier: EPL-2.0
//! Core glue fundamentals — `count` / `seq` / `first` / `rest` /
//! `cons` / `empty` per ADR-0033 D6 + v5 §5.2.
//!
//! ## Pattern (v5 §6.1 hybrid polymorphism)
//!
//! A **Zig Tag switch hardcode** (NaN-box Tag comptime/runtime switch
//! + inline) is the fast path. The Protocol extension point (D-069)
//! is an **additional** path: the fast-path Tag arms stay, and a
//! slow-path `.protocol_extended` arm handles user-extended types.
//!
//! ## Layer 2 wrapper, not Layer 0 re-implementation
//!
//! All six primitives dispatch to existing Layer 0 helpers
//! (`runtime/collection/{list,vector,map,set,chunked_cons}.zig` +
//! `runtime/lazy_seq.zig` + `runtime/charset.zig`). No new heap layout
//! is introduced. `cons` uses the day-1-reserved `.cons` Tag
//! (ADR-0004 + ADR-0012); Cons cell heap layout already lives in
//! `runtime/collection/list.zig`.
//!
//! ## Placement note
//!
//! cw v1's Layer 2 lives flat under `src/lang/primitive/`; this file
//! is `sequence.zig`, the sibling of `collection.zig` /
//! `higher_order.zig`. The flat layout is the finished form — no
//! `core/` subdir grouping.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: list, vector, map, set, chunked_cons, lazy_seq, charset
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
const class_name = @import("../../runtime/class_name.zig");

const list = @import("../../runtime/collection/list.zig");
const vector = @import("../../runtime/collection/vector.zig");
const map = @import("../../runtime/collection/map.zig");
const persistent_queue = @import("../../runtime/collection/persistent_queue.zig");
const sorted = @import("../../runtime/collection/sorted.zig");
const set = @import("../../runtime/collection/set.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const chunked_seq = @import("../../runtime/collection/chunked_seq.zig");
const chunk_transform = @import("chunk_transform.zig");
const range = @import("../../runtime/collection/range.zig");
const array_seq = @import("../../runtime/collection/array_seq.zig");
const sub_vector = @import("../../runtime/collection/sub_vector.zig");
const string_seq = @import("../../runtime/collection/string_seq.zig");
const java_array = @import("../../runtime/collection/java_array.zig");
const transient_vector = @import("../../runtime/collection/transient/transient_vector.zig");
const transient_array_map = @import("../../runtime/collection/transient/transient_array_map.zig");
const transient_hash_set = @import("../../runtime/collection/transient/transient_hash_set.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const seqable = @import("../../runtime/seqable.zig");
const char_sequence = @import("../../runtime/char_sequence.zig");
const charset = @import("../../runtime/charset.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const equal_mod = @import("../../runtime/equal.zig");
const meta_mod = @import("../../runtime/meta.zig");

/// Protocol fqcns the hybrid slow-paths match against `MethodEntry.protocol_name`.
/// Bootstrap declares each protocol in `lang/clj/clojure/core.clj` so the fqcn
/// `allocFqcn` stores at extend-type time is the bare symbol name (see
/// `lang/primitive/protocol.zig:41-51`). Per ADR-0008 amendment 4 (row 7.7).
const IPC_FQCN: []const u8 = "IPersistentCollection";
const ISEQ_FQCN = seqable.ISEQ;

// --- count ---

/// Implements clojure.core/count.
/// Spec: `(count coll)` returns the number of items in `coll`.
///   - nil:         0
///   - string:      codepoint count (per ADR-0014, NOT UTF-16 unit
///                  count; DIVERGENCE D1 vs JVM)
///   - list/cons:   O(1) via cached count
///   - vector:      O(1)
///   - map/set:     O(1)
///   - lazy_seq:    force + walk O(n)
///   - chunked_cons: O(n)
/// JVM reference: clojure.lang.RT.count
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn countFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("count", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return Value.initInteger(0);
    return switch (coll.tag()) {
        .string => blk: {
            const n = charset.codepointCount(string_collection.asString(coll)) catch
                return error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "count",
                    .expected = "valid UTF-8 string",
                    .actual = "invalid UTF-8 bytes",
                });
            break :blk Value.initInteger(@intCast(n));
        },
        .vector => Value.initInteger(@intCast(vector.count(coll))),
        .sub_vector => Value.initInteger(@intCast(sub_vector.count(coll))),
        .array => Value.initInteger(@intCast(java_array.alength(coll))), // ADR-0105
        .map_entry => Value.initInteger(2), // a MapEntry is a 2-vector (D-209)
        .array_map, .hash_map => Value.initInteger(@intCast(map.count(coll))),
        .sorted_map, .sorted_set => Value.initInteger(@intCast(sorted.count(coll))),
        .persistent_queue => Value.initInteger(@intCast(persistent_queue.count(coll))),
        .hash_set => Value.initInteger(@intCast(set.count(coll))),
        // A live transient is a first-class read target (clj parity): count
        // reads its element/entry count without realising it (D-199).
        .transient_vector => blk: {
            try transient_vector.ensureLive(coll, "count", loc);
            break :blk Value.initInteger(@intCast(transient_vector.count(coll)));
        },
        .transient_map => blk: {
            try transient_array_map.ensureLive(coll, "count", loc);
            break :blk Value.initInteger(@intCast(transient_array_map.count(coll)));
        },
        .transient_set => blk: {
            try transient_hash_set.ensureLive(coll, "count", loc);
            break :blk Value.initInteger(@intCast(transient_hash_set.count(coll)));
        },
        // PERF: O(1) precomputed range length, no element walk [refs: O-001].
        // Boxed through range's `wrapI64` lever — a virtual count past i48 is a
        // heap Long, not a float (ADR-0063 amendment; the range aggregate owns
        // all its i64→Value projections).
        .range => try range.countValue(rt, coll),
        // PERF: a vector view counts by subtraction — backing count minus the
        // read cursor — where the eager list copy it replaced had to allocate
        // n cells before it could answer. [refs: O-058]
        .array_seq => Value.initInteger(@intCast(array_seq.countOf(coll))),
        // A string view counts by scanning its remaining bytes: UTF-8 gives no
        // length/element identity to subtract, so this is a walk where the
        // vector view is arithmetic. It still allocates nothing. [refs: D-179]
        .string_seq => Value.initInteger(@intCast(string_seq.countOf(coll))),
        // deftype/reify share one arm (rseq's pattern): clj RT.count routes BOTH
        // by the same rules, so a reify must not bypass the deftype logic (D-422
        // twin). A defrecord counts by field_count (with a -count override honoured
        // — Row 7.7 R3a, ADR-0008 am4); a Counted (or Counted-extending) type's
        // -count is authoritative; a non-Counted IPersistentCollection (incl. ISeq)
        // is WALKED (clj ignores IPersistentCollection.count() for non-Counted —
        // D-422: data.finger-tree's internal trees stub `(count [_])` → nil but
        // aren't Counted). A Seqable-ONLY type is NOT an IPersistentCollection, so
        // it falls through to protocol_no_satisfies — clj throws "count not
        // supported on this type" there too, NOT a silent seq walk.
        .typed_instance, .reified_instance => blk: {
            const desc = instanceDescriptor(coll);
            if (desc.kind == .defrecord) {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc)) |v| break :blk v;
                // D-086 / ADR-0154: count = declared fields + extmap entries.
                const inst = coll.decodePtr(*const td_mod.TypedInstance);
                const ext_n: i64 = if (inst.extmap.isNil()) 0 else @intCast(map.count(inst.extmap));
                break :blk Value.initInteger(@as(i64, inst.field_count) + ext_n);
            }
            if (class_name.implementsInterface(coll, "Counted")) {
                var cs: dispatch.CallSite = .{};
                if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc)) |v| break :blk v;
                // declared Counted but no -count body resolved → fall through to walk.
            }
            if (class_name.implementsInterface(coll, "IPersistentCollection")) break :blk try countBySeqWalk(rt, env, coll, loc);
            // clj RT.countFrom: a non-collection CharSequence counts by
            // .length() — instaparse's Segment deftype (D-430). A null here
            // means the type is not a CharSequence (or declared it
            // method-less).
            if (try char_sequence.lengthOrNull(rt, env, coll, loc)) |v| break :blk v;
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = IPC_FQCN,
                .method = "-count",
                .type_name = desc.fqcn orelse "<anonymous>",
            });
        },
        // `.chunked_cons` shares this arm: its tail is frequently an
        // unrealized lazy seq, so counting only the chunked prefix answers the
        // first chunk's size (32) for every longer seq. The walk below skips
        // whole chunks and realizes the tail, so it is chunk-fast AND total.
        .list, .cons, .lazy_seq, .chunked_cons => {
            // PERF: a PURE `.list` chain carries an exact O(1) count, so
            // return it without walking. The walk below stays for the mixed
            // chain a `.list` cell can head — a "Cons over a seq"
            // (`(cons x (map …))` / `(conj (range 3) 99)`) — where the stored
            // count would describe the `.list` prefix only. `exactCountOf`
            // reports which case this is instead of the caller guessing, so
            // no D-178 `.list`/`.cons` tag split is needed to get the fast
            // path. [refs: O-057]
            if (list.exactCountOf(coll)) |n| return Value.initInteger(@intCast(n));
            var n: i64 = 0;
            var cur = try seqable.seq(rt, env, coll, loc);
            while (!cur.isNil()) {
                switch (cur.tag()) {
                    // PERF: when the walk lands on a chunk, add the whole chunk's
                    // remaining count and skip to its tail — O(chunks) not
                    // O(elements) for a chunked source (range seq, chunk-aware
                    // map/filter). [refs: O-004, D-163]
                    .chunked_cons => {
                        n += @intCast(chunked_cons.currentChunkCount(cur));
                        cur = try seqable.seq(rt, env, chunked_cons.chunkRest(cur), loc);
                    },
                    // PERF: a lazy body that realized to a view (a string, a
                    // vector, a Java array) answers its remainder without a
                    // walk. [refs: O-058, D-179]
                    .array_seq => return Value.initInteger(n + @as(i64, array_seq.countOf(cur))),
                    .string_seq => return Value.initInteger(n + @as(i64, string_seq.countOf(cur))),
                    // A custom ISeq terminal counts through the rooted instance
                    // walk (its `-next` mints fresh instances).
                    .typed_instance, .reified_instance => {
                        const tail = try countFn(rt, env, &.{cur}, loc);
                        return Value.initInteger(n + @as(i64, tail.asInteger()));
                    },
                    else => {
                        n += 1;
                        cur = try seqable.next(rt, env, cur, loc);
                    },
                }
            }
            return Value.initInteger(n);
        },
        else => blk: {
            // Row 7.7 outer slow-path: route through dispatch against
            // `clojure.core/IPersistentCollection -count`. Reaches
            // `(extend-type LongTag IPersistentCollection -count …)` style
            // native-Tag overrides via the row 7.3 per-Tag descriptor
            // registry. A host CharSequence with no -count
            // (java.lang.StringBuilder) counts by .length(), clj
            // RT.countFrom; anything else raises protocol_no_satisfies
            // (cleaner JVM-parity diagnostic than the pre-7.7
            // type_arg_invalid).
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc)) |v| break :blk v;
            if (try char_sequence.lengthOrNull(rt, env, coll, loc)) |v| break :blk v;
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc);
        },
    };
}

const instanceDescriptor = td_mod.descriptorOfInstance;

/// clj `RT.countFrom`: count a non-Counted instance by WALKING its seq.
/// `(seq coll)` then advance via ISeq `-next`, counting one element per node,
/// with clj's mid-walk Counted shortcut (`s instanceof Counted → i + s.count()`).
/// A `-next` that hands off to a native seq tail (lazy_seq / list / …) delegates
/// to `countFn` for the O(chunks) remainder. Used for deftypes that declare
/// IPersistentCollection / ISeq / Seqable but NOT Counted (D-422). `cur` is
/// GC-rooted because an ISeq `-next` dispatch may trigger a collect.
fn countBySeqWalk(rt: *Runtime, env: *Env, coll: Value, loc: SourceLocation) anyerror!Value {
    var cur = try seqFn(rt, env, &.{coll}, loc);
    // GC-ROOT: single-slot manual frame for the walk cursor [ref: .dev/gc_rooting.md §A]
    var gc_roots: [1]Value = .{cur};
    var gc_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var n: i64 = 0;
    while (cur.tag() == .typed_instance or cur.tag() == .reified_instance) {
        // A defrecord is Counted too (it is an IPersistentMap).
        if (class_name.implementsInterface(cur, "Counted")) {
            const tail = try countFn(rt, env, &.{cur}, loc);
            return Value.initInteger(n + tail.asInteger());
        }
        n += 1;
        var cs: dispatch.CallSite = .{};
        cur = (try dispatch.dispatchOrNull(rt, env, &cs, cur, ISEQ_FQCN, "-next", &.{cur}, loc)) orelse .nil_val;
        gc_roots[0] = cur;
    }
    if (!cur.isNil()) {
        const tail = try countFn(rt, env, &.{cur}, loc);
        return Value.initInteger(n + tail.asInteger());
    }
    return Value.initInteger(n);
}

// --- seq ---

/// Implements clojure.core/seq.
/// Spec: `(seq coll)` returns a seq view of `coll`, or `nil` if empty.
/// The arity check over the Layer-0 boundary (`runtime/seqable.zig`,
/// ADR-0197), which owns the tag table and the `Seqable/-seq` dispatch.
/// JVM reference: clojure.lang.RT.seq
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn seqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("seq", args, 1, loc);
    return seqable.seq(rt, env, args[0], loc);
}

/// Implements clojure.core/rseq.
/// Spec: `(rseq coll)` — reverse seq of a *reversible* collection in O(n)
///   here: vector (reverse order) / sorted-map (descending [k v]) /
///   sorted-set (descending elements). Empty → nil. Non-reversible →
///   type error (JVM throws for non-Reversible too).
/// JVM reference: clojure.lang.RT.rseq / Reversible.rseq
/// cw v1 tier: A
pub fn rseqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("rseq", args, 1, loc);
    const coll = args[0];
    return switch (coll.tag()) {
        .vector => if (vector.count(coll) > 0) try vectorToRevList(rt, coll) else .nil_val,
        // A subvec is never empty (`make` returns [] for an empty range), so it
        // always has a reverse seq; `vectorToRevList` handles the `.sub_vector` tag.
        .sub_vector => try vectorToRevList(rt, coll),
        .sorted_map, .sorted_set => if (sorted.count(coll) > 0) try sorted.rseq(rt, coll) else .nil_val,
        // A deftype/reify implementing Reversible `-rseq` (D-280d3; clojure.lang.Reversible
        // host-interface remap) — consult its impl before erroring.
        .typed_instance, .reified_instance => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, "Reversible", "-rseq", &.{coll}, loc)) |v| break :blk v;
            break :blk error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "rseq",
                .expected = "vector, sorted collection, or Reversible instance",
                .actual = @tagName(coll.tag()),
            });
        },
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "rseq",
            .expected = "vector or sorted collection",
            .actual = @tagName(coll.tag()),
        }),
    };
}

fn vectorToRevList(rt: *Runtime, vec: Value) !Value {
    const is_sub = vec.tag() == .sub_vector;
    const n = if (is_sub) sub_vector.count(vec) else vector.count(vec);
    var acc: Value = .nil_val;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const elt = if (is_sub) sub_vector.nth(vec, i) else try vector_nth_safe(vec, i, .{ .line = 0, .column = 0 });
        acc = try list.consHeap(rt, elt, acc);
    }
    return acc;
}

// --- first ---

/// Implements clojure.core/first.
/// Spec: `(first coll)` returns the first item, or `nil` if empty.
/// The arity check over `seqable.first` (ADR-0197).
/// JVM reference: clojure.lang.RT.first → seq().first()
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn firstFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("first", args, 1, loc);
    return seqable.first(rt, env, args[0], loc);
}

// --- rest ---

/// Implements clojure.core/rest.
/// Spec: `(rest coll)` returns a possibly-empty seq of items after the
/// first. Always returns a seq — `()` (the interned empty list), never
/// nil (D-164 / clj-parity C1; the lift lives at the boundary's one exit).
/// JVM reference: clojure.lang.RT.more
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn restFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("rest", args, 1, loc);
    return seqable.rest(rt, env, args[0], loc);
}

// --- next ---

/// Implements clojure.core/next.
/// Spec: `(next coll)` returns the seq of items after the first, or
///   nil if there are no more items: `(seq (rest coll))` at the boundary.
/// JVM reference: clojure.lang.RT.next → seq().next()
/// cw v1 tier: A (Phase 8 row 8.6 cycle 1)
pub fn nextFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("next", args, 1, loc);
    return seqable.next(rt, env, args[0], loc);
}

// --- cons ---

/// Implements clojure.core/cons.
/// Spec: `(cons x seq)` returns a new seq with x prepended.
///   - nil tail:    one-element list `(x)`
///   - list tail:   prepend (cheap)
///   - other coll:  prepend onto `(seq tail)` view (allocates Cons over
///                  a seq view of tail)
/// JVM reference: clojure.lang.RT.cons
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn consFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("cons", args, 2, loc);
    const head = args[0];
    const tail = args[1];
    if (tail.isNil()) {
        // (cons x nil) → (x) — single-element list.
        return try list.consHeap(rt, head, .nil_val);
    }
    return switch (tail.tag()) {
        // `.lazy_seq` tail is kept UNFORCED — `(cons x (lazy-seq …))`
        // must not realize the tail, else lazy producers (e.g. iterate)
        // recurse infinitely at cons time (ADR-0054 cycle 1).
        .list, .cons, .lazy_seq => try list.consSeqHeap(rt, head, tail),
        else => blk: {
            // Cons over a seq view of the tail (JVM's RT.cons fallback).
            const sv = try seqFn(rt, env, args[1..2], loc);
            break :blk try list.consSeqHeap(rt, head, sv);
        },
    };
}

/// `__lazy-seq-create` — internal primitive called by the `lazy-seq`
/// Zig macro transform. Receives a zero-arity thunk fn and constructs
/// a LazySeq whose body is forced on first seq access. ADR-0054.
pub fn lazySeqCreateFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__lazy-seq-create", args, 1, loc);
    return try lazy_seq.alloc(rt, args[0]);
}

// --- empty ---

/// Implements clojure.core/empty.
/// Spec: `(empty coll)` returns an empty collection of the same
/// category as `coll`, or `nil` if `coll` is nil.
/// JVM reference: clojure.core/empty
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn emptyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("empty", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    // clj's persistent collections carry their metadata onto `empty`
    // (`EMPTY.withMeta(meta())` for vector/subvec/map/set/sorted/queue/
    // PersistentList); a generic ISeq (Cons, LazySeq, range, …) empties to a
    // meta-less `()`.
    switch (coll.tag()) {
        .vector, .sub_vector, .array_map, .hash_map, .hash_set, .sorted_map, .sorted_set, .persistent_queue, .list => {
            const m = try meta_mod.metaOf(rt, env, coll, loc);
            if (!m.isNil()) {
                // ADR-0150: the fresh empty is unrooted across the with-meta
                // copy; `m` stays reachable through the rooted `coll` arg.
                rt.gc.enterFabrication();
                defer rt.gc.exitFabrication();
                const e = try emptyBare(rt, env, coll, args, loc);
                return (try meta_mod.withMetaOrNull(rt, env, e, m, loc)) orelse e;
            }
        },
        else => {},
    }
    return emptyBare(rt, env, coll, args, loc);
}

fn emptyBare(rt: *Runtime, env: *Env, coll: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    return switch (coll.tag()) {
        .vector, .sub_vector => vector.empty(),
        .array_map, .hash_map => map.empty(),
        .hash_set => set.empty(),
        // Sorted variants keep their comparator (clj PersistentTreeMap.empty()
        // returns an empty tree with the same comp) — data.priority-map's
        // `(empty priority->set-of-items)` relies on it.
        .sorted_map => try sorted.emptyMapBy(rt, coll.decodePtr(*const sorted.SortedMap).comparator), // repr-decode-ok: comparator field read; sorted_map has a single backing
        .sorted_set => try sorted.emptySetBy(rt, coll.decodePtr(*const sorted.SortedSet).map.decodePtr(*const sorted.SortedMap).comparator), // repr-decode-ok: comparator field read; sorted_set has a single backing
        .persistent_queue => try persistent_queue.emptyQueue(rt), // (empty q) → EMPTY
        // Every ISeq empties to `()`, not just a cons chain: clj's `ASeq.empty()`
        // returns `PersistentList.EMPTY` for a range / lazy seq / chunked seq /
        // vector view alike. `.range`, `.lazy_seq` and `.chunked_cons` were
        // reaching the `else` dispatch and raising, which is a pre-existing gap
        // this arm closes alongside `.array_seq`. (D-164)
        .list, .cons, .range, .lazy_seq, .chunked_cons, .array_seq, .string_seq => try list.emptyList(rt),
        // JVM Clojure: (empty "hi") → nil (String is not a Clojure
        // collection per IPersistentCollection contract). cw v1
        // follows the same semantic; a 0-length string is not what
        // empty returns for a string arg.
        .string => .nil_val,
        else => blk: {
            // D-089 row 8.6 cycle 1: IPC -empty slow-path.
            var cs: dispatch.CallSite = .{};
            // clj's `(empty x)` returns nil for ANY value that is not an
            // IPersistentCollection — a Long, char, keyword, float, java array,
            // host instance, … all yield nil, never a raise. cljw matches via
            // the nil-fallback dispatch for every such type (D-431, B2 sweep).
            // A deftype/reify keeps the RAISING dispatch: a type that declares
            // itself a collection is expected to wire -empty, so a missing impl
            // there is a developer error, not a silent nil.
            if (coll.tag() == .typed_instance or coll.tag() == .reified_instance)
                break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-empty", args, loc);
            break :blk (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-empty", args, loc)) orelse .nil_val;
        },
    };
}

// --- helpers ---

/// nth over a seq by walking (clojure.lang.RT.nth's seq path): seq the
/// head, advance `idx` steps via the boundary's `next`, return the element —
/// or null when `idx` is negative or past the end (the caller maps null to
/// the `nth` default / index-out-of-range). Forces lazy layers as it walks,
/// so `(nth (range n) i)` / `(nth (map f xs) i)` / `(rand-nth (range n))`
/// index like JVM seqs. Shared by `collection.zig::nthFn` (F-011).
pub fn nthSeq(rt: *Runtime, env: *Env, coll: Value, idx: i64, loc: SourceLocation) anyerror!?Value {
    if (idx < 0) return null;
    var cur = try seqable.seq(rt, env, coll, loc);
    // GC-ROOT: single-slot manual frame for the walk cursor — `next` re-enters
    // eval (a lazy tail's thunk, an ISeq `-next`) [ref: .dev/gc_rooting.md §A]
    var gc_roots: [1]Value = .{cur};
    var gc_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    var remaining = idx;
    while (remaining > 0) : (remaining -= 1) {
        if (cur.isNil()) return null;
        cur = try seqable.next(rt, env, cur, loc);
        gc_roots[0] = cur;
    }
    if (cur.isNil()) return null;
    return try seqable.first(rt, env, cur, loc);
}

/// vector_nth — wraps vector.nth with a type-safe loc-less error path
/// when called from helpers that don't have a SourceLocation.
fn vector_nth_safe(vec: Value, i: u32, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return vector.nth(vec, i);
}

// --- chunk-builder primitives (ADR-0065 / D-163) ---
// Thin wrappers over chunked_cons.zig that let the `.clj` map/filter/keep/
// remove 2-arg bodies preserve chunking (JVM chunk-cons shape).

fn chunkedSeqQFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("chunked-seq?", args, 1, loc);
    return if (chunked_seq.isChunked(args[0])) Value.true_val else Value.false_val;
}

fn chunkCountFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__chunk-count", args, 1, loc);
    return Value.initInteger(@intCast(chunked_seq.chunkCount(args[0])));
}

fn chunkNthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__chunk-nth", args, 2, loc);
    return chunked_seq.chunkNth(args[0], @intCast(args[1].asInteger()));
}

fn chunkRestFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("chunk-rest", args, 1, loc);
    return try chunked_seq.chunkRest(rt, args[0]);
}

fn chunkBufferFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("chunk-buffer", args, 1, loc);
    // The size arg is a hint; the backing array is always CHUNK_SIZE.
    return try chunked_cons.newChunkBuffer(rt);
}

fn chunkAppendFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("chunk-append", args, 2, loc);
    return chunked_cons.chunkAppend(args[0], args[1]);
}

fn chunkConsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("chunk-cons", args, 2, loc);
    return try chunked_cons.chunkCons(rt, args[0], args[1]);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "count", .f = &countFn },
    .{ .name = "seq", .f = &seqFn },
    .{ .name = "rseq", .f = &rseqFn },
    .{ .name = "first", .f = &firstFn },
    .{ .name = "rest", .f = &restFn },
    .{ .name = "next", .f = &nextFn },
    .{ .name = "cons", .f = &consFn },
    .{ .name = "__lazy-seq-create", .f = &lazySeqCreateFn },
    .{ .name = "empty", .f = &emptyFn },
    .{ .name = "chunked-seq?", .f = &chunkedSeqQFn },
    .{ .name = "__chunk-count", .f = &chunkCountFn },
    .{ .name = "__chunk-nth", .f = &chunkNthFn },
    .{ .name = "chunk-rest", .f = &chunkRestFn },
    .{ .name = "chunk-buffer", .f = &chunkBufferFn },
    .{ .name = "chunk-append", .f = &chunkAppendFn },
    .{ .name = "chunk-cons", .f = &chunkConsFn },
    // O-032: in-Zig chunk-map/filter drain (chunk_transform.zig) — the
    // producer-side analogue of reduceFn's O-004 chunk drain.
    .{ .name = "__chunk-map-step", .f = &chunk_transform.chunkMapStepFn },
    .{ .name = "__dorun", .f = &chunk_transform.dorunFn },
    .{ .name = "__chunk-filter-step", .f = &chunk_transform.chunkFilterStepFn },
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

test "count: nil returns 0" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try countFn(&fix.rt, &fix.env, &.{Value.nil_val}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 0), r.asInteger());
}

test "count: vector returns element count" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    v = try vector.conj(&fix.rt, v, Value.initInteger(2));
    v = try vector.conj(&fix.rt, v, Value.initInteger(3));
    const r = try countFn(&fix.rt, &fix.env, &.{v}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 3), r.asInteger());
}

test "count: string returns codepoint count (not byte count) — DIVERGENCE D1" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const s = try string_collection.alloc(&fix.rt, "café");
    const r = try countFn(&fix.rt, &fix.env, &.{s}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 4), r.asInteger()); // 4 codepoints (NOT 5 bytes)
}

test "=: a chunked seq is equal to the vector holding the same elements" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const loc: SourceLocation = .{ .line = 0, .column = 0 };
    // `sequential?` answers true for a `.chunked_cons`; if `=` disagrees, the
    // value is Sequential that is equal to nothing — the two answers must come
    // from ONE definition (class_name.implementsInterface over Sequential).
    const r = try range.make(&fix.rt, 0, 1, 40);
    const s = try seqFn(&fix.rt, &fix.env, &.{r}, loc);
    try testing.expectEqual(Value.Tag.chunked_cons, s.tag());
    var v = vector.empty();
    var i: i64 = 0;
    while (i < 40) : (i += 1) v = try vector.conj(&fix.rt, v, Value.initInteger(i));
    try testing.expect(try equal_mod.valueEqual(&fix.rt, &fix.env, s, v));
    try testing.expect(try equal_mod.valueEqual(&fix.rt, &fix.env, v, s));
}

test "count: a chunked seq counts EVERY element, not just its realized chunk" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const loc: SourceLocation = .{ .line = 0, .column = 0 };
    // `(seq (range 40))` heads a 32-element chunk over an unrealized tail.
    // Counting the chunk alone answers 32 for every n >= 32 — a wrong number,
    // returned without an error.
    const r40 = try range.make(&fix.rt, 0, 1, 40);
    const s40 = try seqFn(&fix.rt, &fix.env, &.{r40}, loc);
    try testing.expectEqual(Value.Tag.chunked_cons, s40.tag());
    const c40 = try countFn(&fix.rt, &fix.env, &.{s40}, loc);
    try testing.expectEqual(@as(i64, 40), c40.asInteger());

    // Two chunk boundaries out, so a single-chunk-plus-one answer cannot pass.
    const r100 = try range.make(&fix.rt, 0, 1, 100);
    const s100 = try seqFn(&fix.rt, &fix.env, &.{r100}, loc);
    const c100 = try countFn(&fix.rt, &fix.env, &.{s100}, loc);
    try testing.expectEqual(@as(i64, 100), c100.asInteger());
}

test "seq: empty vector returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try seqFn(&fix.rt, &fix.env, &.{vector.empty()}, .{ .line = 0, .column = 0 });
    try testing.expect(r.isNil());
}

test "first: nil returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try firstFn(&fix.rt, &fix.env, &.{Value.nil_val}, .{ .line = 0, .column = 0 });
    try testing.expect(r.isNil());
}

test "first: list returns head" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const lst = try list.consHeap(&fix.rt, Value.initInteger(1), .nil_val);
    const lst2 = try list.consHeap(&fix.rt, Value.initInteger(0), lst);
    const r = try firstFn(&fix.rt, &fix.env, &.{lst2}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 0), r.asInteger());
}

test "cons: prepend onto nil yields one-element list" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try consFn(&fix.rt, &fix.env, &.{ Value.initInteger(42), Value.nil_val }, .{ .line = 0, .column = 0 });
    try testing.expectEqual(Value.Tag.list, r.tag());
    try testing.expectEqual(@as(i64, 42), list.first(r).asInteger());
}

test "cons: prepend onto a non-nil seq yields clojure.lang.Cons" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const tail = try list.consHeap(&fix.rt, Value.initInteger(2), .nil_val);
    const r = try consFn(&fix.rt, &fix.env, &.{ Value.initInteger(1), tail }, .{});
    try testing.expectEqual(Value.Tag.cons, r.tag());
    try testing.expectEqual(@as(i64, 1), list.first(r).asInteger());
    try testing.expectEqual(tail, list.rest(r));
    try testing.expectEqual(@as(u32, 2), list.countOf(r));
}

test "empty: vector returns empty vector" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    const r = try emptyFn(&fix.rt, &fix.env, &.{v}, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .vector);
    try testing.expectEqual(@as(u32, 0), vector.count(r));
}
// `(empty <non-collection>)` → nil is verified at the integration layer
// (test/diff/clj_corpus/empty_noncoll.txt, run by corpus_regression), NOT here:
// the non-collection path runs through protocol dispatch (resolveDescriptor +
// the fn vtable), which the minimal unit-test Runtime does not bootstrap — a
// unit test would exercise the fixture, not the behaviour.
