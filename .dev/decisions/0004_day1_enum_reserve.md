# 0004 — Day-1 reservation of SpecialFormTag, Opcode, and ValueTag enums

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude, reviewed by Shota)
- **Tags**: phase-4-entry, enum, day-1, special-form, opcode, value-tag

## Context

When the VM lands in Phase 4, adding a new special form or value type
in subsequent phases would require touching reader, analyzer,
tree_walk, vm/compiler, and vm/dispatch in lockstep. The same pressure
collapsed `zwasm v1` and forced the v2 ground-up redesign (single
opcode addition touched 6 files because enums were not sized for the
full target).

cw v1 has the same risk if `SpecialFormTag`, `Opcode`, and `ValueTag`
are sized only for what Phase 3 needs. By the time deftype / dosync /
monitor-enter / atom enter the language in later phases, every
existing dispatch site needs to be revisited.

## Decision

Phase 4 entry reserves the full set of `SpecialFormTag`, `Opcode`, and
`ValueTag` slots for everything cw v1 expects to support through Phase
20. Implementation may be staged across phases, but enum shape is
locked. Adding a new slot after Phase 4 entry requires an amendment to
this ADR.

### SpecialFormTag (24 slots)

Phase 1-3 existing (14): `if`, `do`, `let_star`, `fn_star`, `def`,
`quote`, `var_form`, `the`, `loop_star`, `recur`, `try_star`, `catch`,
`finally`, `throw`.

V3 reserved (10): `deftype`, `defrecord`, `reify`, `definterface`,
`dot` (`.method`), `new`, `set_bang`, `monitor_enter`, `monitor_exit`,
`dosync`.

### ValueTag

Phase 1-3 existing tags plus reservations for `typed_instance`,
`reified_instance`, `type_descriptor`, `big_int`, `ratio`,
`big_decimal`, `lazy_seq`, `transient_vector`, `transient_hashmap`,
`atom_`, `ref_`, `agent_`, `future_`, `promise_`, `host_instance`.
The exact slot count is finalized when ADR-0012 lands the "3 slot vs
1 slot + flag" choice.

### Opcode

The VM Opcode enum reserves at least 80 slots covering control flow,
stack ops, locals, closure, arithmetic (i64 / i53 unchecked /
fallback), boolean / nil, collection ops (Phase 5+), exception (Phase
3+), namespace / var dispatch, and pseudo-ops for the JIT path
(Phase 17+ go / no-go).

## Alternatives considered

### Alternative A — Grow the enums incrementally

- **Sketch**: add each tag when the implementing phase begins.
- **Why rejected**: existing dispatch sites must be revisited every
  time. zwasm v1 lost weeks to this; cw v1 has the same VM shape and
  would lose at least as much.

### Alternative B — Hierarchical enum (`SpecialForm.Class.Tag`)

- **Sketch**: nested enums for category + variant.
- **Why rejected**: exhaustiveness checking becomes harder, and
  `comptime` dispatch tables grow more complex.

## Consequences

- **Positive**: dispatch tables are stable from Phase 4. Future phases
  add an implementation behind an existing tag rather than a tag and
  an implementation.
- **Negative**: the enum has empty slots through Phase 4-6, which is
  cosmetically odd but enforceable via exhaustiveness checks (each
  unimplemented tag returns a structured `error.NotImplemented`).
- **Neutral / follow-ups**: ADR-0012 finalizes ValueTag concretely;
  ADR-0007/0008/0009/0010 land the implementations behind specific
  tags.

## References

- ROADMAP §A11 (Day-one enum reservation)
- ROADMAP §9.6 task 4.4 (Opcode enum landing)
- Related ADRs: 0007, 0008, 0009, 0010, 0012

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
