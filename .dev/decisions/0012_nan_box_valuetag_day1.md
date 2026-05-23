# 0012 — NaN-box ValueTag day-1 full enum reservation

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, value-tag, nan-box, day-1, dispatch

## Context

The NaN-box layout is the single most load-bearing data structure in
cw v1. Every value dispatch — including special forms, primitives,
host instances, and lazy seqs — keys off `ValueTag`. Adding a tag
later forces every existing dispatch site to be revisited (the same
pressure described in ADR-0004 for `SpecialFormTag` and `Opcode`).

Two sub-options exist for how class-system values are encoded:

- **Option A (3 tags)**: separate `typed_instance`, `reified_instance`,
  and `type_descriptor` tags. Dispatch is one tag-check per case.
- **Option B (1 tag + flag)**: a single `class` tag with the heap
  header's `is_type_descriptor` bit selecting between "describes a
  type" and "instance of a type". Dispatch is one tag-check plus one
  bit read.

JVM_TO_ZIG.md §19 recommends Option A on the basis that the dispatch
fast path is shorter (no second read).

## Decision

cw v1 adopts Option A. The day-1 `ValueTag` enum reserves a slot per
distinct payload shape:

- Existing (Phase 1-3): `nil_`, `boolean_true`, `boolean_false`,
  `int_53`, `float_64`, `keyword`, `symbol`, `string`, `list`,
  `ex_info`, `closure`, `var_`.
- Phase 5 additions: `vector`, `hashmap`, `hashset`, `big_int`, `ratio`,
  `lazy_seq`.
- Phase 5-7 (class system, ADR-0007): `typed_instance`,
  `reified_instance`, `type_descriptor`.
- Phase 7 (transient, multi-fn, protocol): `multi_fn`,
  `protocol_inst`, `transient_vector`, `transient_hashmap`.
- Phase 14-15 (concurrency primitives): `atom_`, `ref_`, `agent_`,
  `future_`, `promise_`.
- Host stdlib (ADR-0011): `host_instance` (single tag covering all
  host-imported types; the specific type is on the
  `TypeDescriptor`).
- Sentinel: `_` (open enum for ADR-driven extension).

Total: 26 explicit tags plus the sentinel. Layout is finalized at
Phase 4 entry; subsequent additions are amendments to this ADR.

## Alternatives considered

### Alternative B — 1 tag + flag

- **Sketch**: combine `typed_instance` and `type_descriptor` into
  one tag, distinguished by a header flag.
- **Why rejected**: marginal byte savings (one tag slot out of 256)
  against a measurable dispatch slowdown (one extra read per
  class-system call). Slot budget is not the bottleneck.

## Consequences

- **Positive**: dispatch is one tag check throughout. Empty slots
  through Phase 4-6 are flagged by the exhaustiveness checker so
  unimplemented cases surface as compile errors, not silent passes.
- **Negative**: 26 named tags is more surface than strictly required.
  Acceptable for the explicitness gain.
- **Neutral / follow-ups**: tag count is reconfirmed when ADR-0007
  finalizes the `TypeDescriptor` layout, since the host-stdlib design
  may collapse `host_instance` into `typed_instance` after Phase 14
  if no semantic difference remains.

## References

- ROADMAP §A11 (Day-one enum reservation)
- Related ADRs: 0004, 0007, 0011, 0017

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing). Option A
  (3-slot) selected; Option B (1-slot + flag) recorded as alternative.
- 2026-05-23 (amendment 1): **`big_int` lands at HeapTag slot 29 and
  `ratio` is reserved at slot 30**, replacing the released
  `wasm_module` / `wasm_fn` slots (ADR-0006 amendment 1). The
  existing NaN-box layout (4 groups × 8 sub-types = 32 slots, group
  bands `0xFFF8`-`0xFFFB`) is preserved — extending to a fifth group
  is blocked by `0xFFFC` already serving as `NB_INT_TAG`, and
  shrinking sub-type bits would halve the pointer space. Re-purposing
  the released Wasm slots is the smallest-diff path. Phase 5 numeric
  tower work (long → BigInt promotion, ratio arithmetic) consumes
  these slots; the BigInt heap struct landed at task 4.23 swaps
  away from `PHASE4_PLACEHOLDER_TAG = 0xFF` to `HeapTag.big_int` in
  the same commit as this amendment.
