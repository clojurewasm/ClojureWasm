// SPDX-License-Identifier: EPL-2.0
//! Heap object discriminant tag (`HeapTag`) for cw v1 NaN-boxed Values.
//!
//! Stored in `HeapHeader.tag` on every heap-allocated object and also
//! encoded as a 4-bit sub-type within heap-tagged Values (combined with
//! the 2-bit group band per ADR-0027 §1). Per ADR-0012 + ADR-0027 the
//! enum is the single source of truth for the heap-tag namespace.
//!
//! The layout is the g2 64-entry namespace (4 group × 16 sub-type) per
//! F-004 + ADR-0027 §2 (post-amendment 1). The enum below is the slot
//! map's single source of truth; the per-Tag GC trace / finaliser /
//! descriptor dispatch tables in `runtime/gc/tag_ops.zig` carry `null`
//! for tags whose owning Phase has not yet wired behaviour (the `null`
//! entry is the safe leaf-node default — see `tag_ops.zig`).
//!
//! Group layout (mirrors the enum below):
//!
//!   Group A — Hot data + persistent collections (slots 0..15):
//!     A0 string         A4 vector         A8 lazy_seq        A12 range
//!     A1 symbol         A5 array_map      A9 cons            A13 string_seq
//!     A2 keyword        A6 hash_map       A10 chunked_cons   A14 array_seq
//!     A3 list           A7 hash_set       A11 chunk_buffer   A15 map_entry
//!
//!   Group B — Callables + reader extra (slots 16..31):
//!     B0 fn_val         B4 var_ref        B8 tagged_literal  B12 type_descriptor
//!     B1 multi_fn       B5 ns             B9 reader_cond     B13 host_instance
//!     B2 protocol       B6 delay          B10 class          B14 typed_instance
//!     B3 protocol_fn    B7 regex          B11 reified_inst   B15 uuid
//!
//!   Group C — Mutable + concurrency + transient + sorted/queue (slots 32..47):
//!     C0 atom           C4 future         C8 trans_vector    C12 array_chunk
//!     C1 agent          C5 promise        C9 trans_map       C13 persist_queue
//!     C2 ref            C6 reduced        C10 trans_set      C14 sorted_map
//!     C3 volatile       C7 ex_info        C11 rb_node        C15 sorted_set
//!
//!   Group D — Numeric + Clojure collection internals + wasm tail (slots 48..63):
//!     D0 big_int        D4 hamt_node                  D8 tval     D12 wasm_module
//!     D1 ratio          D5 tail_node                  D9 matcher  D13 wasm_fn
//!     D2 big_decimal    D6 hamt_map_node              D10 tuple   D14 wasm_funcref
//!     D3 array          D7 hash_collision_map_node    D11 sub_vector D15 wasm_externref

/// Heap object discriminant — 64 entries (4 group × 16 sub-type) per
/// F-004 + ADR-0027 §2. Each entry's integer value is the contiguous
const std = @import("std");

/// slot index used by both the NaN-box encoding and the per-Tag dispatch
/// tables in `runtime/gc/tag_ops.zig`.
pub const HeapTag = enum(u8) {
    // Group A — Hot data + persistent collections (slots 0..15)
    string = 0,
    symbol = 1,
    keyword = 2,
    list = 3,
    vector = 4,
    array_map = 5,
    hash_map = 6,
    hash_set = 7,
    lazy_seq = 8,
    cons = 9,
    chunked_cons = 10,
    chunk_buffer = 11,
    range = 12,
    string_seq = 13,
    array_seq = 14,
    map_entry = 15,

    // Group B — Callables + reader extra (slots 16..31)
    fn_val = 16,
    multi_fn = 17,
    protocol = 18,
    protocol_fn = 19,
    var_ref = 20,
    ns = 21,
    delay = 22,
    regex = 23,
    tagged_literal = 24,
    reader_conditional = 25,
    class = 26,
    reified_instance = 27,
    type_descriptor = 28,
    host_instance = 29,
    typed_instance = 30,
    uuid = 31, // B15 — java.util.UUID value type (ADR-0074)

    // Group C — Mutable + concurrency + transient + sorted/queue (slots 32..47)
    atom = 32,
    agent = 33,
    ref = 34,
    @"volatile" = 35,
    future = 36,
    promise = 37,
    reduced = 38,
    ex_info = 39,
    transient_vector = 40,
    transient_map = 41,
    transient_set = 42,
    rb_node = 43, // persistent LLRB red-black tree node (sorted-map/set, ADR-0057)
    array_chunk = 44,
    persistent_queue = 45,
    sorted_map = 46,
    sorted_set = 47,

    // Group D — Numeric + Clojure collection internals + wasm tail (slots 48..63)
    // (D-248 reorg: Clojure persistent-collection internals moved UP to
    // D4..D8, the wasm surfaces moved to the D12..D15 TAIL — finished-form
    // cleanliness, ADR-0027 §2 slot-map. Slot ORDER is a discriminant only; runtime
    // dispatch is enum-NAME-based and serialized bytecode uses a decoupled ValueTag,
    // so this renumber is non-breaking. HeapTag + Value.Tag stay in sync — a test asserts it.)
    big_int = 48,
    ratio = 49,
    big_decimal = 50,
    array = 51,
    hamt_node = 52, // D4 — PersistentVector interior/leaf node (5.4.a)
    tail_node = 53, // D5 — PersistentVector 32-element tail array (5.4.a)
    hamt_map_node = 54, // D6 — PersistentHashMap CHAMP-style HAMT node (5.5.a)
    hash_collision_map_node = 55, // D7 — PersistentHashMap collision bucket (5.5.c)
    tval = 56, // D8 — STM Ref history-ring node (ADR-0010 amendment 4)
    matcher = 57,
    tuple = 58,
    sub_vector = 59,
    wasm_module = 60, // D12 — wasm surfaces at the tail (Phase 16+)
    wasm_fn = 61,
    wasm_funcref = 62,
    wasm_externref = 63,
};

/// GC-managed membrane SSOT (D-251 / ADR-0095 Alt D). `true` iff a Value with
/// this tag points at an object the GC mark phase may safely read + dispatch on
/// — i.e. its pointer targets a valid `HeapHeader` at offset 0 (a `gc.alloc`'d
/// swept object — since ADR-0184 that includes `Function` cells — or a
/// `trackHeap`'d process-lifetime object like a `ProtocolDescriptor`
/// whose children we trace). `false` for the heap-TAGGED but NON-GC
/// types whose pointer does NOT target a markable `HeapHeader`:
///
///   - `var_ref` / `ns` — Env-lifetime `*Var` / `*Namespace` with NO header at
///     offset 0; decoding one hands `mark()` a non-header first byte (the
///     `tag_trace_table` OOB the dormant-chunk-constant trace hit). Filtering
///     them here is both safe and the fix.
///   - `keyword` — `gpa`-interned (process-lifetime, never swept). It HAS a
///     valid header but never carries metadata, so it never needs marking (the
///     interner keeps it + its `gpa` name strings alive) — filtered for that
///     liveness-not-needed reason, not for any header hazard.
///
/// `symbol` is GcManaged = TRUE (ADR-0110), unlike `keyword`: a symbol can
/// carry `with-meta` metadata (a GC-managed map), so its trace must mark that
/// map. A `Symbol` HAS a valid header at offset 0 (mark-safe). An *interned*
/// symbol always has nil meta, so it rides the trace as a no-op; its mark bit
/// is never cleared (not on `gc.allocations`, not a `persistent_marks`
/// waypoint), but that is provably inert — an interned symbol has NO GC child
/// (`with-meta` always mints a *non-interned* gc.alloc'd symbol, which sweep
/// bit-clears normally), so a stale bit cannot strand anything.
///
/// `Value.heapHeader()` consults this so EVERY root walk (operand stack, locals,
/// chunk constants, closure bindings) filters the same set in ONE place — an
/// allow-list-of-known-offenders `switch` is exactly the scatter this replaces.
/// A `Runtime.init` assert guards the invariant "every tag with a registered
/// trace or finaliser is GcManaged" so the membrane and trace table cannot drift.
///
// GC-ROOT: G2 — the membrane SSOT classifier (non-GC heap tags) [ref: .dev/gc_rooting.md §G]
pub fn isGcManaged(tag: HeapTag) bool {
    return switch (tag) {
        // `symbol` is GcManaged (ADR-0110: it can carry with-meta'd metadata
        // that its trace marks). `keyword`/`var_ref`/`ns` stay filtered — see
        // the doc comment for the per-tag rationale.
        .keyword, .var_ref, .ns => false,
        else => true,
    };
}

// ---------------------------------------------------------------------------
// Slot census (ADR-0179)
//
// The 2026-08-04 audit counted the 64 names below and concluded the tag space
// was "100% full — a new type has nowhere to go, and only a user F-004
// amendment can unblock it". Names are not uses. Measured by use, 11 of the 64
// addresses are not doing NaN-box work, and no F-004 amendment is required to
// see that.
//
// Getting this census right took three attempts, all of them the same class of
// error as the audit's, so the classification is enforced here rather than
// described:
//
//   - a COMPUTED-tag encode site was missed by a syntactic grep
//     (`map.zig` encodes trie nodes via `@enumFromInt(n.header.tag)`), which
//     wrongly moved `hamt_map_node` out of the boxed set;
//   - a TEST-ONLY encode was counted as production, which wrongly kept
//     `wasm_funcref` / `wasm_externref` in it;
//   - the three counts summed to 63, not 64 — `@"volatile"` uses Zig's `@"…"`
//     escape and the pattern did not match it.
//
// `assertCensusCloses` below fails the build on the third class directly, and
// `boxable` makes the first class a compile error at the call site.

/// Tags that exist ONLY as a `HeapHeader.tag` — GC-traced heap objects that are
/// never encoded into a `Value`, so they consume no NaN-box sub-type address in
/// practice. `PersistentVector.tail` is a raw `?*TailNode` field; `TVal` is
/// reached only through `Ref.tvals` (`stm/tval.zig` states the invariant in its
/// own header: "No `Value.Tag.tval` exists").
pub const heap_only = [_]HeapTag{ .tail_node, .tval };

/// Named day-1 reservations with ZERO production reference — no encode, no
/// `HeapHeader.init`, no `tag_ops` registration. Two are subsumed by a
/// different representation that shipped instead: a `Class` value is a
/// `.type_descriptor`, and `Matcher` is an ADR-0106 `host_instance`.
///
/// These are NOT deleted and NOT renamed. F-004's body names
/// `reader_conditional` and the Wasm family in its day-1 type set, and D-043's
/// discharge records this project's reading — "F-004 fixes 64 slots + the
/// day-1 type set, not intra-group ORDER" — so repurposing one is a user
/// decision. `wasm_fn` / `wasm_funcref` / `wasm_externref` additionally carry
/// D-259's open deferred decision about how they become first-class Values.
///
/// Publishing the list is the point: when a new type needs an address, the
/// question is "may `tuple` become `chan`", not "may we amend the 64-slot
/// layout". No layout amendment is needed. (Precedent: slot 59 `box` became
/// `sub_vector` on the user's 2026-08-20 F-004 amendment — D-583 / O-059.)
pub const unallocated = [_]HeapTag{
    .reader_conditional, .class,        .array_chunk,    .matcher, .tuple,
    .wasm_fn,            .wasm_funcref, .wasm_externref,
};

fn inList(comptime list: []const HeapTag, tag: HeapTag) bool {
    inline for (list) |t| if (t == tag) return true;
    return false;
}

/// True when `tag` may be encoded into a `Value` via `Value.encodeHeapPtr`.
/// An unallocated slot is boxable — it simply has no producer yet.
pub fn boxable(tag: HeapTag) bool {
    return !inList(&heap_only, tag);
}

/// The check that would have caught both the audit's error and all three of the
/// classification's: {boxed} ∪ {heap-only} ∪ {unallocated} must PARTITION the
/// enum — disjoint, exhaustive, and summing to the field count. A census that
/// does not close fails the build with its own arithmetic in the message.
pub fn assertCensusCloses() void {
    comptime {
        const fields = @typeInfo(HeapTag).@"enum".fields;
        for (heap_only) |h| {
            if (inList(&unallocated, h))
                @compileError("heap_tag census: a tag is both heap-only and unallocated");
        }
        var boxed_in_production: usize = 0;
        for (fields) |f| {
            const tag: HeapTag = @enumFromInt(f.value);
            if (inList(&heap_only, tag)) continue;
            if (inList(&unallocated, tag)) continue;
            boxed_in_production += 1;
            if (f.value >= 64)
                @compileError("heap_tag census: a boxed tag sits outside the 64 NaN-box addresses (F-004)");
        }
        const total = boxed_in_production + heap_only.len + unallocated.len;
        if (total != fields.len) @compileError(std.fmt.comptimePrint(
            "heap_tag census does not close: {d} boxed + {d} heap-only + {d} unallocated = {d}, but HeapTag has {d} fields",
            .{ boxed_in_production, heap_only.len, unallocated.len, total, fields.len },
        ));
        if (fields.len > 64)
            @compileError("HeapTag exceeds the 64 NaN-box addresses F-004 fixes");
    }
}

comptime {
    assertCensusCloses();
}

test "slot census closes and reports the measured headroom" {
    const fields = @typeInfo(HeapTag).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 64), fields.len);
    try std.testing.expectEqual(@as(usize, 2), heap_only.len);
    // 8, not 9: F-004's 2026-08-20 amendment gave `box` (slot 59) to
    // `sub_vector`, so it has a producer and left the unallocated list.
    try std.testing.expectEqual(@as(usize, 8), unallocated.len);
    // 10 addresses are not doing NaN-box work — the correction to the
    // 2026-08-04 audit's "100% full".
    try std.testing.expectEqual(@as(usize, 10), heap_only.len + unallocated.len);
    try std.testing.expect(boxable(.string));
    try std.testing.expect(!boxable(.tval));
    try std.testing.expect(!boxable(.tail_node));
    // An unallocated slot is boxable — it has no producer, not a prohibition.
    try std.testing.expect(boxable(.tuple));
    // Slot 59 was `box` (named, never referenced) until F-004's 2026-08-20
    // amendment gave it to subvec's view; it is a producer-backed slot now.
    try std.testing.expect(boxable(.sub_vector));
}
