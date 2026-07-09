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
//!     D3 array          D7 hash_collision_map_node    D11 box     D15 wasm_externref

/// Heap object discriminant — 64 entries (4 group × 16 sub-type) per
/// F-004 + ADR-0027 §2. Each entry's integer value is the contiguous
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
    box = 59,
    wasm_module = 60, // D12 — wasm surfaces at the tail (Phase 16+)
    wasm_fn = 61,
    wasm_funcref = 62,
    wasm_externref = 63,
};

/// GC-managed membrane SSOT (D-251 / ADR-0095 Alt D). `true` iff a Value with
/// this tag points at an object the GC mark phase may safely read + dispatch on
/// — i.e. its pointer targets a valid `HeapHeader` at offset 0 (a `gc.alloc`'d
/// swept object, or a `trackHeap`'d process-lifetime object like a `Function`
/// whose closure children we trace). `false` for the heap-TAGGED but NON-GC
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
