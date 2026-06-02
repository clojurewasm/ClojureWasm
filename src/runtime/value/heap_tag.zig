// SPDX-License-Identifier: EPL-2.0
//! Heap object discriminant tag (`HeapTag`) for cw v1 NaN-boxed Values.
//!
//! Stored in `HeapHeader.tag` on every heap-allocated object and also
//! encoded as a 4-bit sub-type within heap-tagged Values (combined with
//! the 2-bit group band per ADR-0027 §1). Per ADR-0012 + ADR-0027 the
//! enum is the single source of truth for the heap-tag namespace.
//!
//! Phase 5 row 5.2.b widens the layout to **64 entries (4 group × 16
//! sub-type)** per F-004 + ADR-0027 §2 (post-amendment 1) decree. Day-1
//! entries land for every type F-004 enumerated; new entries that the
//! owning §9.7 row activates later are type-declared-only — the GC trace
//! / finaliser / descriptor dispatch tables in `runtime/gc/tag_ops.zig`
//! carry `null` for entries with no behaviour wired yet (per
//! `no_op_stub_forbidden.md`'s "explicit-error stub" pattern, the
//! behaviour-bearing call sites raise `Code.feature_not_supported`
//! through the dispatch layer).
//!
//! Group layout (per F-004 indicative slot map, verbatim):
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
//!   Group D — Numeric + wasm + extension (slots 48..63):
//!     D0 big_int        D4 wasm_module    D8 matcher         D12 reserved
//!     D1 ratio          D5 wasm_fn        D9 tuple           D13 reserved
//!     D2 big_decimal    D6 wasm_funcref   D10 box            D14 reserved
//!     D3 array          D7 wasm_externref D11 reserved       D15 reserved
//!
//! Anonymous reserves (B15 / C11 / D11–D15) carry debt D-043 for Phase 7
//! entry review — name them or shrink the group boundary per measured
//! dispatch frequency.

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

    // Group D — Numeric + wasm + extension (slots 48..63)
    big_int = 48,
    ratio = 49,
    big_decimal = 50,
    array = 51,
    wasm_module = 52,
    wasm_fn = 53,
    wasm_funcref = 54,
    wasm_externref = 55,
    matcher = 56,
    tuple = 57,
    box = 58,
    hamt_node = 59, // D11 — PersistentVector interior/leaf node (5.4.a)
    tail_node = 60, // D12 — PersistentVector 32-element tail array (5.4.a)
    hamt_map_node = 61, // D13 — PersistentHashMap CHAMP-style HAMT node (5.5.a)
    hash_collision_map_node = 62, // D14 — PersistentHashMap collision bucket (5.5.c, declared here)
    tval = 63, // D15 — STM Ref history-ring node (Phase 14 row 14.11.5, ADR-0010 amendment 4)
};
