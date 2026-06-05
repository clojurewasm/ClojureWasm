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

const list = @import("../../runtime/collection/list.zig");
const vector = @import("../../runtime/collection/vector.zig");
const map = @import("../../runtime/collection/map.zig");
const map_entry = @import("../../runtime/collection/map_entry.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const persistent_queue = @import("../../runtime/collection/persistent_queue.zig");
const sorted = @import("../../runtime/collection/sorted.zig");
const set = @import("../../runtime/collection/set.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const range = @import("../../runtime/collection/range.zig");
const transient_vector = @import("../../runtime/collection/transient/transient_vector.zig");
const transient_array_map = @import("../../runtime/collection/transient/transient_array_map.zig");
const transient_hash_set = @import("../../runtime/collection/transient/transient_hash_set.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const charset = @import("../../runtime/charset.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");

/// Protocol fqcns the hybrid slow-paths match against `MethodEntry.protocol_name`.
/// Bootstrap declares each protocol in `lang/clj/clojure/core.clj` so the fqcn
/// `allocFqcn` stores at extend-type time is the bare symbol name (see
/// `lang/primitive/protocol.zig:41-51`). Per ADR-0008 amendment 4 (row 7.7).
const IPC_FQCN: []const u8 = "IPersistentCollection";
const SEQABLE_FQCN: []const u8 = "Seqable";
const ISEQ_FQCN: []const u8 = "ISeq";

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
        .map_entry => Value.initInteger(2), // a MapEntry is a 2-vector (D-209)
        .array_map, .hash_map => Value.initInteger(@intCast(map.count(coll))),
        .sorted_map, .sorted_set => Value.initInteger(@intCast(sorted.count(coll))),
        .persistent_queue => Value.initInteger(@intCast(persistent_queue.count(coll))),
        .hash_set => Value.initInteger(@intCast(set.count(coll))),
        // A live transient is a first-class read target (clj parity): count
        // reads its element/entry count without realising it (D-199).
        .transient_vector => Value.initInteger(@intCast(transient_vector.count(coll))),
        .transient_map => Value.initInteger(@intCast(transient_array_map.count(coll))),
        .transient_set => Value.initInteger(@intCast(transient_hash_set.count(coll))),
        .chunked_cons => Value.initInteger(@intCast(chunked_cons.count(coll))),
        // PERF: O(1) precomputed range length, no element walk [refs: O-001]
        .range => Value.initInteger(range.countOf(coll)),
        .typed_instance => blk: {
            // Row 7.7 R3a (ADR-0008 amendment 4): consult the protocol
            // method_table first; user `(extend-type X IPersistentCollection
            // (-count [_] …))` overrides the defrecord field_count default.
            // Falls back to field_count for defrecord without an override
            // (preserves row 7.4 cycle 3 semantics) and to
            // protocol_no_satisfies for deftype.
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc)) |v| break :blk v;
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) break :blk Value.initInteger(@intCast(inst.field_count));
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = IPC_FQCN,
                .method = "-count",
                .type_name = inst.descriptor.fqcn orelse "<anonymous>",
            });
        },
        .list, .cons, .lazy_seq => {
            // O(n) generic walk. A `.list` cons may hold a non-list seq as
            // its rest (a "Cons over a seq", e.g. `(cons x (map …))` /
            // `(conj (range 3) 99)`), so the O(1) `.count` field is a lie
            // for mixed chains — walk instead, forcing lazy layers and
            // advancing through whatever tag the rest takes. Pure-list O(1)
            // count is the F-004 finished form once the `.list` / `.cons`
            // tags split (PersistentList vs Cons); see debt D-178.
            var n: i64 = 0;
            var cur = try lazy_seq.seq(rt, env, coll);
            while (!cur.isNil()) {
                // PERF: when the walk lands on a chunk, add the whole chunk's
                // remaining count and skip to its tail — O(chunks) not
                // O(elements) for a chunked source (range seq, chunk-aware
                // map/filter). [refs: O-004, D-163]
                if (cur.tag() == .chunked_cons) {
                    n += @intCast(chunked_cons.currentChunkCount(cur));
                    cur = try lazy_seq.seq(rt, env, chunked_cons.chunkRest(cur));
                } else {
                    n += 1;
                    cur = try seqNext(rt, env, cur);
                }
            }
            return Value.initInteger(n);
        },
        else => blk: {
            // Row 7.7 outer slow-path: route through dispatch against
            // `clojure.core/IPersistentCollection -count`. Reaches
            // `(extend-type LongTag IPersistentCollection -count …)` style
            // native-Tag overrides via the row 7.3 per-Tag descriptor
            // registry; raises protocol_no_satisfies when no MethodEntry
            // is registered (cleaner JVM-parity diagnostic than the
            // pre-7.7 type_arg_invalid).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc);
        },
    };
}

// --- seq ---

/// Build an array_map of a defrecord's declared fields (in declaration order),
/// so `seq`/`into {}`/`vec` over a record yield its `[k v]` map entries like a
/// map — JVM records are Seqable as their entry seq. (cljw has no `__extmap`
/// yet — D-086 — so only declared fields participate.)
fn recordToMap(rt: *Runtime, inst: *const td_mod.TypedInstance) !Value {
    const layout = inst.descriptor.field_layout orelse return map.empty();
    const vals = inst.fields();
    var m = map.empty();
    for (layout, 0..) |f, i| {
        const kw = try keyword_mod.intern(rt, null, f.name);
        m = try map.assoc(rt, m, kw, vals[i]);
    }
    return m;
}

/// Implements clojure.core/seq.
/// Spec: `(seq coll)` returns a seq view of `coll`, or `nil` if empty.
///   - nil:         nil
///   - empty coll:  nil (NOT empty seq)
///   - non-empty:   list-shape ISeq view
/// JVM reference: clojure.lang.RT.seq
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn seqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("seq", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .string => {
            // Empty string → nil; non-empty → codepoint seq (eager list build).
            const s = string_collection.asString(coll);
            if (s.len == 0) return .nil_val;
            return try stringToList(rt, s);
        },
        .list, .cons => list.seq(coll),
        .vector => if (vector.count(coll) > 0) try vectorToList(rt, coll) else .nil_val,
        // A MapEntry seqs as `(key val)` (D-209 / ADR-0078).
        .map_entry => try list.consHeap(rt, map_entry.keyOf(coll), try list.consHeap(rt, map_entry.valOf(coll), .nil_val)),
        .array_map, .hash_map => if (map.count(coll) > 0) try map.seq(rt, coll) else .nil_val,
        .sorted_map, .sorted_set => if (sorted.count(coll) > 0) try sorted.seq(rt, coll) else .nil_val,
        .persistent_queue => try persistent_queue.seqOf(rt, coll),
        .hash_set => if (set.count(coll) > 0) try set.seq(rt, coll) else .nil_val,
        .chunked_cons => coll,
        // A range's seq view is a chunked_cons (≤32 materialised + a smaller
        // `.range` tail) — generic walkers then pay 1 alloc / 32 elements.
        .range => try range.seqChunk(rt, coll),
        .lazy_seq => try lazy_seq.seq(rt, env, coll),
        .typed_instance => blk: {
            // A user `(extend-type X Seqable (-seq …))` override wins; otherwise
            // a defrecord is Seqable by default as its `[k v]` entry seq (JVM
            // parity), and a deftype with no override raises.
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, SEQABLE_FQCN, "-seq", args, loc)) |v| break :blk v;
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) {
                const m = try recordToMap(rt, inst);
                break :blk if (map.count(m) > 0) try map.seq(rt, m) else .nil_val;
            }
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = SEQABLE_FQCN,
                .method = "-seq",
                .type_name = inst.descriptor.fqcn orelse "<anonymous>",
            });
        },
        else => blk: {
            // Row 7.7 cycle 2: outer-else routes through dispatch against
            // `Seqable -seq`, reaching `(extend-type X Seqable -seq …)`
            // overrides on native Tags via the row 7.3 per-Tag descriptor
            // registry. Raises protocol_no_satisfies when no MethodEntry is
            // registered (supersedes the pre-7.7 type_arg_invalid raise).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, SEQABLE_FQCN, "-seq", args, loc);
        },
    };
}

/// Implements clojure.core/rseq.
/// Spec: `(rseq coll)` — reverse seq of a *reversible* collection in O(n)
///   here: vector (reverse order) / sorted-map (descending [k v]) /
///   sorted-set (descending elements). Empty → nil. Non-reversible →
///   type error (JVM throws for non-Reversible too).
/// JVM reference: clojure.lang.RT.rseq / Reversible.rseq
/// cw v1 tier: A
pub fn rseqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("rseq", args, 1, loc);
    const coll = args[0];
    return switch (coll.tag()) {
        .vector => if (vector.count(coll) > 0) try vectorToRevList(rt, coll) else .nil_val,
        .sorted_map, .sorted_set => if (sorted.count(coll) > 0) try sorted.rseq(rt, coll) else .nil_val,
        else => error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "rseq",
            .expected = "vector or sorted collection",
            .actual = @tagName(coll.tag()),
        }),
    };
}

fn vectorToRevList(rt: *Runtime, vec: Value) !Value {
    const n = vector.count(vec);
    var acc: Value = .nil_val;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const elt = try vector_nth_safe(vec, i, .{ .line = 0, .column = 0 });
        acc = try list.consHeap(rt, elt, acc);
    }
    return acc;
}

// --- first ---

/// Implements clojure.core/first.
/// Spec: `(first coll)` returns the first item, or `nil` if empty.
/// JVM reference: clojure.lang.RT.first → seq().first()
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn firstFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("first", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .list, .cons => list.first(coll),
        .vector => if (vector.count(coll) > 0)
            try vector_nth_safe(coll, 0, loc)
        else
            .nil_val,
        .map_entry => map_entry.keyOf(coll), // first of `[k v]` is k (D-209)
        .persistent_queue => persistent_queue.peek(coll), // first = oldest = peek
        .chunked_cons => chunked_cons.first(coll),
        // PERF: O(1) head (start), no chunk materialised for just first [refs: O-001]
        .range => range.first(coll),
        .lazy_seq => try lazy_seq.first(rt, env, coll),
        .string => firstStringCodepoint(coll),
        .array_map, .hash_map, .hash_set => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try firstOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089: route unknown receivers through ISeq `-first`. D-189:
            // when the receiver implements Seqable but NOT ISeq (e.g. an
            // Eduction), coerce via `seq` first — JVM `RT.first` →
            // `seq().first()`. `dispatchOrNull` returns null when no ISeq
            // `-first` MethodEntry is registered.
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ISEQ_FQCN, "-first", args, loc)) |v| break :blk v;
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try firstOfSeq(rt, env, sv, loc);
        },
    };
}

// --- rest ---

/// Implements clojure.core/rest.
/// Spec: `(rest coll)` returns a possibly-empty seq of items after the
/// first. Always returns a seq — `()` (the interned empty list), never
/// nil, for any non-list / empty / nil input where JVM `RT.more` also
/// yields `()`. `(rest nil)` → `()`, `(rest '(1))` → `()`.
/// JVM reference: clojure.lang.RT.more
/// cw v1 tier: A (Phase 6.16.a-1)
///
/// D-164 / clj-parity C1: a raw nil result (chain tail, empty coll, nil
/// arg) is lifted to `rt.empty_list` at one exit (F-011 commonisation).
/// `next` keeps returning nil for the same cases — the JVM `more`/`next`
/// asymmetry (see `nextFn`).
pub fn restFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("rest", args, 1, loc);
    const coll = args[0];
    const raw: Value = if (coll.isNil()) .nil_val else switch (coll.tag()) {
        .list, .cons => list.rest(coll),
        .vector => if (vector.count(coll) > 1) try vectorTailAsList(rt, coll, 1) else .nil_val,
        .map_entry => try list.consHeap(rt, map_entry.valOf(coll), .nil_val), // (rest [k v]) → (v)
        .persistent_queue => blk: {
            const s = try persistent_queue.seqOf(rt, coll);
            break :blk if (s.isNil()) .nil_val else list.rest(s);
        },
        .chunked_cons => try chunked_cons.rest(rt, coll),
        .lazy_seq => try lazy_seq.rest(rt, env, coll),
        // A string seqs to a char list (codepoints, not a substring): D-174
        // `(rest "abc")` is a char-seq, not a String. Route through seqFn so
        // `(string? (rest s))` is false and `(seq? …)` is true (one mechanism
        // with the map/set/range arm; the lazy `.string_seq` substrate is the
        // F-004 finished form, D-179).
        .string, .array_map, .hash_map, .hash_set, .range => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089: ISeq -rest slow-path. D-189: Seqable→seq coercion
            // fallback for a Seqable-only deftype (e.g. Eduction).
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ISEQ_FQCN, "-rest", args, loc)) |v| break :blk v;
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
    };
    return if (raw.isNil()) try list.emptyList(rt) else raw;
}

// --- next ---

/// Implements clojure.core/next.
/// Spec: `(next coll)` returns the seq of items after the first, or
///   nil if there are no more items. Distinct from `rest` only in
///   that JVM returns nil instead of an empty seq.
/// JVM reference: clojure.lang.RT.next → seq().next()
/// cw v1 tier: A (Phase 8 row 8.6 cycle 1)
pub fn nextFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("next", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .list, .cons => blk: {
            const r = list.rest(coll);
            // The tail may be a `.lazy_seq` (a lazy producer like `map`
            // cons'd a lazy tail onto a head); `next` must seq it so an
            // empty lazy tail collapses to nil (else a seq-walk that
            // advances via `next` appends a spurious trailing nil).
            // For an explicit-nil tail, seqFn(nil) is nil — unchanged.
            break :blk try seqFn(rt, env, &.{r}, loc);
        },
        .vector => if (vector.count(coll) > 1) try vectorTailAsList(rt, coll, 1) else .nil_val,
        .map_entry => try list.consHeap(rt, map_entry.valOf(coll), .nil_val), // (next [k v]) → (v)
        .persistent_queue => blk: {
            const s = try persistent_queue.seqOf(rt, coll);
            if (s.isNil()) break :blk .nil_val;
            const r = list.rest(s);
            break :blk if (list.isEmpty(r)) .nil_val else r;
        },
        .chunked_cons => blk: {
            const r = try chunked_cons.rest(rt, coll);
            // Match JVM next: nil for empty rest. seq the tail so a
            // chunk-boundary `next` set to an unrealized empty lazy_seq
            // (chunk-aware map/filter) forces to nil rather than trailing
            // a spurious nil. Within-chunk rest is a chunked_cons (no-op).
            break :blk try seqFn(rt, env, &.{r}, loc);
        },
        .lazy_seq => blk: {
            const r = try lazy_seq.rest(rt, env, coll);
            // seq the tail so an EMPTY lazy rest collapses to nil — matching
            // the .list / .chunked_cons arms above. Without this, `(next
            // (map identity [1]))` returns a non-nil empty lazy_seq (prints
            // as nil yet `nil?`→false), and any seq-walk advancing via `next`
            // (incl. `apply`'s eager spread) appends a spurious trailing nil.
            break :blk try seqFn(rt, env, &.{r}, loc);
        },
        // A string seqs to a char list (D-174): `(next "abc")` is a char-seq,
        // not a substring. Same seqFn route + nil-empty as the map/set/range arm.
        .string, .array_map, .hash_map, .hash_set, .range => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089: ISeq -next slow-path. D-189: Seqable→seq coercion
            // fallback (cljw rest≡next: nil for empty) for a Seqable-only
            // deftype (e.g. Eduction).
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, ISEQ_FQCN, "-next", args, loc)) |v| break :blk v;
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
    };
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
        .list, .cons, .lazy_seq => try list.consHeap(rt, head, tail),
        else => blk: {
            // Cons over a seq view of the tail (JVM's RT.cons fallback).
            const sv = try seqFn(rt, env, args[1..2], loc);
            break :blk try list.consHeap(rt, head, sv);
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
    return switch (coll.tag()) {
        .vector => vector.empty(),
        .array_map, .hash_map => map.empty(),
        .hash_set => set.empty(),
        .persistent_queue => try persistent_queue.emptyQueue(rt), // (empty q) → EMPTY
        .list, .cons => try list.emptyList(rt), // (empty '(1 2)) → () (D-164)
        // JVM Clojure: (empty "hi") → nil (String is not a Clojure
        // collection per IPersistentCollection contract). cw v1
        // follows the same semantic; a 0-length string is not what
        // empty returns for a string arg.
        .string => .nil_val,
        else => blk: {
            // D-089 row 8.6 cycle 1: IPC -empty slow-path.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-empty", args, loc);
        },
    };
}

// --- helpers ---

/// vector → eager list build (head-to-tail copy).
fn vectorToList(rt: *Runtime, vec: Value) !Value {
    return try vectorTailAsList(rt, vec, 0);
}

/// vector[start..] → list view, built eager (head-to-tail).
fn vectorTailAsList(rt: *Runtime, vec: Value, start: u32) !Value {
    const n = vector.count(vec);
    if (n <= start) return .nil_val;
    var acc: Value = .nil_val;
    var i = n;
    while (i > start) {
        i -= 1;
        const elt = try vector_nth_safe(vec, i, .{ .line = 0, .column = 0 });
        acc = try list.consHeap(rt, elt, acc);
    }
    return acc;
}

/// string → eager char list build. Elements are `.char` Values (JVM
/// parity: `(seq "abc")` → `(\a \b \c)`, chars not 1-char strings).
fn stringToList(rt: *Runtime, s: []const u8) !Value {
    const cp_count = try charset.codepointCount(s);
    if (cp_count == 0) return .nil_val;
    var i: usize = cp_count;
    var acc: Value = .nil_val;
    while (i > 0) {
        i -= 1;
        const cp = charset.codepointAt(s, i) catch return error.InvalidUtf8;
        acc = try list.consHeap(rt, Value.initChar(@intCast(cp)), acc);
    }
    return acc;
}

/// Helper: first codepoint of a string as a `.char` Value (JVM parity:
/// `(first "abc")` → `\a`, a Character, not a 1-char String).
fn firstStringCodepoint(s: Value) Value {
    const bytes = string_collection.asString(s);
    if (bytes.len == 0) return .nil_val;
    const cp = charset.codepointAt(bytes, 0) catch return .nil_val;
    return Value.initChar(@intCast(cp));
}

/// nth over a seq by walking (clojure.lang.RT.nth's seq path): force the
/// head, advance `idx` steps via `seqNext`, return the element — or null
/// when `idx` is negative or past the end (the caller maps null to the
/// `nth` default / index-out-of-range). Forces lazy layers as it walks, so
/// `(nth (range n) i)` / `(nth (map f xs) i)` / `(rand-nth (range n))`
/// index like JVM seqs. Shared by `collection.zig::nthFn` (F-011) so the
/// seq-walk lives next to `seqNext` / `firstOfSeq`.
pub fn nthSeq(rt: *Runtime, env: *Env, coll: Value, idx: i64, loc: SourceLocation) anyerror!?Value {
    if (idx < 0) return null;
    var cur = try lazy_seq.seq(rt, env, coll);
    var remaining = idx;
    while (remaining > 0) : (remaining -= 1) {
        cur = try seqNext(rt, env, cur);
        if (cur.isNil()) return null;
    }
    if (cur.isNil()) return null;
    return try firstOfSeq(rt, env, cur, loc);
}

/// First-of-seq: assumes input is already a seq (list / cons / etc).
fn firstOfSeq(rt: *Runtime, env: *Env, sv: Value, loc: SourceLocation) anyerror!Value {
    return switch (sv.tag()) {
        .list, .cons => list.first(sv),
        .chunked_cons => chunked_cons.first(sv),
        .range => range.first(sv),
        .lazy_seq => try lazy_seq.first(rt, env, sv),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "first",
            .expected = "seq",
            .actual = @tagName(sv.tag()),
        }),
    };
}

/// Rest-of-seq: assumes input is already a seq.
fn restOfSeq(rt: *Runtime, env: *Env, sv: Value, loc: SourceLocation) anyerror!Value {
    return switch (sv.tag()) {
        .list, .cons => list.rest(sv),
        .chunked_cons => try chunked_cons.rest(rt, sv),
        .range => try chunked_cons.rest(rt, try range.seqChunk(rt, sv)),
        .lazy_seq => try lazy_seq.rest(rt, env, sv),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "rest",
            .expected = "seq",
            .actual = @tagName(sv.tag()),
        }),
    };
}

/// Helper: walk seq one step (used in count for lazy_seq).
fn seqNext(rt: *Runtime, env: *Env, cur: Value) anyerror!Value {
    return switch (cur.tag()) {
        // seq the rest so a lazy tail (e.g. `(cons x (lazy-seq …))` from
        // a lazy producer) is forced to nil when empty — else a count /
        // walk over a lazy seq over-counts by one (the unforced lazy
        // tail reads as non-nil). Mirrors the `next` fix in `nextFn`.
        .list, .cons => try lazy_seq.seq(rt, env, list.rest(cur)),
        // seq the chunk-boundary tail too: chunk-aware map/filter sets a
        // chunk's `next` to an unrealized `(map f (chunk-rest s))` lazy_seq
        // that may force to nil, so the raw rest must be seq'd or a
        // count/walk over-counts by one (an unforced empty lazy tail reads
        // as non-nil). Within-chunk rest is a chunked_cons → seq is a no-op.
        .chunked_cons => try lazy_seq.seq(rt, env, try chunked_cons.rest(rt, cur)),
        .range => try lazy_seq.seq(rt, env, try chunked_cons.rest(rt, try range.seqChunk(rt, cur))),
        .lazy_seq => try lazy_seq.next(rt, env, cur),
        else => .nil_val,
    };
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
    return if (chunked_cons.isChunked(args[0])) Value.true_val else Value.false_val;
}

fn chunkCountFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("-chunk-count", args, 1, loc);
    return Value.initInteger(@intCast(chunked_cons.currentChunkCount(args[0])));
}

fn chunkNthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("-chunk-nth", args, 2, loc);
    return chunked_cons.currentChunkNth(args[0], @intCast(args[1].asInteger()));
}

fn chunkRestFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("chunk-rest", args, 1, loc);
    return chunked_cons.chunkRest(args[0]);
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
    .{ .name = "-chunk-count", .f = &chunkCountFn },
    .{ .name = "-chunk-nth", .f = &chunkNthFn },
    .{ .name = "chunk-rest", .f = &chunkRestFn },
    .{ .name = "chunk-buffer", .f = &chunkBufferFn },
    .{ .name = "chunk-append", .f = &chunkAppendFn },
    .{ .name = "chunk-cons", .f = &chunkConsFn },
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
    try testing.expect(r.tag() == .list or r.tag() == .cons);
    try testing.expectEqual(@as(i64, 42), list.first(r).asInteger());
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
