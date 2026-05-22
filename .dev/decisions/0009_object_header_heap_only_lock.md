# 0009 — Object header lock for heap values only

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, object-header, lock, concurrency, monitor

## Context

JVM Clojure relies on `(monitor-enter obj)` / `(monitor-exit obj)` /
`(locking obj body)` for cache initialization, lazy init, and other
synchronization. Corpus measurement: `locking` 335 occurrences,
`monitor-enter` / `monitor-exit` 17 each.

The JVM achieves this by attaching a Mark Word to every Object and
encoding a 3-state lock (biased, lightweight, heavyweight). cw v1's
NaN-boxed `Value` is 8 bytes with no spare bits for a per-value lock
bit; building a Mark Word into every NaN-boxed value is impossible.

## Decision

cw v1 supports `locking` / `monitor-enter` / `monitor-exit` only on
**heap-allocated values** (vectors, maps, sets, deftype instances,
records, atoms, refs, agents, ex-info instances). NaN-boxed
primitives (int_53, float_64, keyword, symbol) cannot be locked;
attempting to lock one raises `Code.eval_type_cannot_call`-shape
catalog error (per ADR-0018) whose user-facing message names the
value type that the user tried to lock.

The lock state lives in a packed 32-bit field on every heap
object's header:

```zig
pub const ObjectHeader = packed struct(u64) {
    type_tag: u16,
    gc_and_lock: u32,   // [0..1] lock_state (2 bits), [2..31] gc_mark (30 bits)
    _reserved: u16,
};

pub const LockState = enum(u2) {
    unlocked = 0,
    light    = 1,   // CAS-acquired
    heavy    = 2,   // sparse heavy-lock table entry held
    _ = 3,           // reserved
};
```

The lock has two states, not three (biased was dropped by the JVM in
JEP 374). Contention escalates `light -> heavy` by lazily inserting a
`std.Thread.Mutex` into a sparse heavy-lock table keyed by header
pointer.

Phase 5 reserves the bit slot in the struct. Phase 15 activates the
implementation (CAS path + heavy fallback). Phase 4-14 attempts to
take a lock raise `Code.unsupported_feature` via the catalog
(per ADR-0018) with the form name (`locking` / `monitor-enter` /
`monitor-exit`) as `.{ .name = "<form>" }`. No-op stub is forbidden
per `no_op_stub_forbidden.md`.

## Alternatives considered

### Alternative A — Bit-packed Mark Word on every Value

- **Sketch**: spare bits in the NaN-box for primitives too.
- **Why rejected**: 8-byte NaN-box has no spare bits without breaking
  numeric range.

### Alternative B — External lock map keyed by Value identity

- **Sketch**: a global `HashMap<Value, Mutex>`.
- **Why rejected**: works but pays a hash + lookup per `locking`
  call. Object-header path is direct.

### Alternative C — Biased locking (JVM pre-JEP 374)

- **Sketch**: add a third state for single-thread bias.
- **Why rejected**: the JVM removed it because the optimization
  benefit no longer outweighed the complexity. cw v1 starts on the
  post-JEP-374 design.

## Consequences

- **Positive**: 335 corpus occurrences become reachable. The
  invariant "lockable iff heap" is simple, predictable, and
  documented as an error condition for primitives.
- **Negative**: `(locking some-int 42)` is a runtime error. This
  rejects code that locks on primitive values, which the JVM also
  permits via auto-boxing; user code must adapt or use atom.
- **Neutral / follow-ups**: Phase 15 STM (ADR-0010) sits beside this
  mechanism but does not share it. Phase 15.4 concurrent tests
  exercise both.

## References

- ROADMAP §9.6 task 4.19 (Object header layout extension)
- Related ADRs: 0007, 0010, 0017
- JVM JEP 374 (biased locking deprecation)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment): Error phrasing rewritten to go through the
  catalog (ADR-0018). User-facing messages no longer reference this
  ADR by name.
