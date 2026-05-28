# 0010 — STM (ref / dosync) is Tier A with full MVCC

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, stm, mvcc, concurrency, ref, dosync

## Context

Clojure's STM is the project's signature concurrency primitive.
`ref` / `dosync` / `alter` / `commute` / `ensure` total ~444 corpus
occurrences once `alter-meta!` / `ensure-reduced` are excluded. Babashka
explicitly omits STM, but cw v1 is positioned as a fuller alternative
to JVM Clojure and the Software Transactional Memory model is part of
what "fuller" means here.

JVM Clojure's implementation lives in `LockingTransaction.java`
(~1,000 lines): MVCC TVal ring per `Ref`, thread-local transaction
context, retry loop with snapshot validation, ordered locking by ref
pointer to avoid deadlocks, and a "barge" mechanism that lets older
transactions preempt newer ones to prevent starvation.

## Decision

cw v1 implements STM as Tier A with a full MVCC design that
observably matches the JVM:

```zig
pub const Ref = struct {
    tvals: TValHistory,
    min_history: u32,
    max_history: u32,
    watches: WatchTable,
    lock: std.Thread.Mutex,
};

pub const TVal = struct {
    val: Value,
    point: u64,
    msecs: i64,
    prior: ?*TVal,
};

pub const Transaction = struct {
    sets: std.AutoHashMapUnmanaged(*Ref, Value),
    commutes: std.AutoHashMapUnmanaged(*Ref, std.ArrayListUnmanaged(*Closure)),
    ensures: std.ArrayListUnmanaged(*Ref),
    info: ?*Info,
    read_point: u64,
    start_point: u64,
    priority: u32,
};

pub threadlocal var current_tx: ?*Transaction = null;
```

Phases:

- Phase 4 entry: declarations live in cw runtime headers; no executable
  code paths are wired. `dosync` / `ref` / `alter` / `commute` /
  `ensure` / `ref-set` raise sub-feature staged catalog Codes
  (`stm_dosync_not_supported` / `stm_ref_not_supported` /
  `stm_alter_not_supported` / `stm_commute_not_supported` /
  `stm_ensure_not_supported` / `stm_ref_set_not_supported`)
  per ADR-0018 amendment 2. Each Code disappears when the
  corresponding sub-operation lands in Phase 13-15.
- Phase 13: `Ref` and `TVal` data structures.
- Phase 14: `doGet` / `doSet` / `doCommute` / `doEnsure`.
- Phase 15.1: commit + retry loop.
- Phase 15.2: commute fast path.
- Phase 15.3: barge mechanism (priority-based contention resolution
  matching JVM `LockingTransaction.barge`).
- Phase 15.4: concurrent integration test.

## Alternatives considered

### Alternative A — Drop STM (Babashka path)

- **Sketch**: implement only `atom`.
- **Why rejected**: STM is a defining Clojure feature, ~444 corpus
  occurrences depend on it, and the cw v1 charter explicitly aims
  higher than Babashka.

### Alternative B — Stub `dosync` as a no-op

- **Sketch**: execute body without snapshot isolation.
- **Why rejected**: violates the `no_op_stub_forbidden` rule. A
  silent-no-op `dosync` is worse than a clear "not implemented yet"
  error because it makes the user believe the code worked.

## Consequences

- **Positive**: `ref` / `dosync` / `alter` / `commute` / `ensure` work
  observably the same as on JVM, including the barge guarantee.
- **Negative**: ~3-5 weeks of focused implementation in Phase 13-15.
  Concurrent test surface grows.
- **Neutral / follow-ups**: `commute` fast path can be optimized later;
  watches share infrastructure with atom (ADR follow-up at Phase 15).

## Phase 13-15 migration note (amendment 2)

The Phase 4 entry lands `Ref` / `TVal` / `Transaction` declarations
(skeleton in `runtime/stm/`) and **six sub-feature staged Codes**
in `error_catalog.zig` (`stm_dosync_not_supported` /
`stm_ref_not_supported` / `stm_alter_not_supported` /
`stm_commute_not_supported` / `stm_ensure_not_supported` /
`stm_ref_set_not_supported`). Activation is staged across five
Phases; each step rewrites already-shipped code by removing one or
more of these Codes and rewriting the corresponding test
expectations:

| Phase | Sub-op activated                             | Codes removed                                                                            |
|-------|----------------------------------------------|------------------------------------------------------------------------------------------|
| 13    | `Ref` / `TVal` data structure                | none yet (read-only path lands)                                                          |
| 14    | `doGet` / `doSet` / `doCommute` / `doEnsure` | `stm_alter`, `stm_commute`, `stm_ensure`, `stm_ref_set` (partial — read/write activate) |
| 15.1  | commit + retry loop                          | `stm_dosync`                                                                             |
| 15.2  | commute fast path                            | `stm_commute` (full — retry-loop integration)                                           |
| 15.3  | barge mechanism                              | (no Code removed; correctness rewrite of retry control flow)                             |
| 15.4  | concurrent integration test                  | (no Code removed; test surface expansion)                                                |

Each Phase that removes a Code also **rewrites the catalog test**
(`error_catalog.zig`'s inline tests assert that Code is reachable;
removing the arm requires updating those tests). The catalog
growth is non-monotonic per ADR-0018 amendment 2.

The rewrite is expected per ROADMAP §A25; principle.md depth 2 for
each Phase that only deletes a Code arm; depth 3 when also
rewriting `Ref` storage / `Transaction` retry control flow.

## Phase 13 representation — single-cell, lock-free (amendment 3)

Phase 13 entry (2026-05-28) lands the `Ref` data structure as a
**single `current: Value` heap cell**, not the TVal history ring:

```zig
pub const Ref = extern struct {
    header: HeapHeader,   // offset 0 — GC contract
    _pad: [6]u8 = .{0,0,0,0,0,0},
    current: Value,       // newest committed value (= JVM tvals.val)
};
```

`(ref init)` seeds `current = init`; `deref` / `@r` **outside a
transaction** returns `current` (JVM `Ref.deref` collapses to
`currentVal()` reading the newest TVal when no transaction runs).
`dosync` / `alter` / `commute` / `ensure` / `ref-set` keep raising
their staged Codes (no Code removed at Phase 13, per amendment 2).
File: `src/runtime/stm/ref.zig`; wiring modelled on
`runtime/collection/reduced.zig` (single-Value cell + one-pointer
GC trace).

Three divergences from this ADR's §Decision sketch, each recorded
here so the drift is not silent:

1. **No lock in Phase 13.** The §Decision sketch writes
   `lock: std.Thread.Mutex`; that type was **removed in Zig 0.16**
   and is forbidden by ROADMAP §13. The Phase-13 read path is
   single-threaded (no commit can race a read before Phase 15),
   so it needs no lock — the D-046 lazy_seq "single-thread no-lock
   until Phase 15" precedent governs. Omitting the lock also keeps
   `Ref` a pure `extern struct` and avoids cw v0's forced
   `RefObj`/`RefInner` two-allocation split (v0 split *only*
   because a mutex cannot live in an `extern struct`). The lock
   returns at Phase 15.1 (commit + retry) as `std.Io.Mutex` /
   `std.atomic.Mutex`, decided by that owner.
2. **No `TVal` type in Phase 13.** The §Phases line reads "`Ref`
   and `TVal` data structures", but that pairing is prose in a
   memo, not a contract (F-002 §4); the read-only path provably
   needs only the newest value, which the scalar `current` holds.
   Materialising an inert `TVal` node now (with `point=0` /
   `prior=null` doing nothing until commits exist) is a larger
   skeleton than the bounded field-swap it would save — it fails
   F-002 §3's shrink-not-enlarge test. Phase 14 introduces `TVal`
   { val / point / msecs / prior } + the history ring; `current`
   becomes the ring head then (a bounded, documented field-swap,
   tracked by **D-102**).
3. **No `min_history` / `max_history` / `watches` fields.** Unused
   until Phase 14 (ring growth) / Phase 15 (watches share atom
   infra); declaring them now is Reservation-as-bias. Added by the
   owner that first reads them.

### Alternatives considered (Devil's-advocate fork, fresh context, 2026-05-28)

F-NNN envelope check (leading entry): none of the three shapes
violates F-002 / F-004 / F-006. The one textbook field that would —
the embedded `std.Thread.Mutex` — is forbidden by ROADMAP §13 /
zig_tips, a stale-memo problem, not an F-NNN conflict; no halt.

- **Alt 1 — smallest-diff: `Ref { header, _pad, current: Value }`.**
  Near-clone of `reduced.zig`; one inner Value, one-pointer trace.
  Better: smallest surface, mechanically proven, zero reservation
  bias, fastest to green. Breaks: Phase 14 *replaces* the scalar
  `current` with a `?*TVal` ring head (field-type swap on a shipped
  struct + `deref`-arm rewrite) — the "skeleton that gets rewritten,
  not extended" shape F-002 §3 warns about, though bounded.
- **Alt 2 — finished-form-clean: `Ref { header, tvals: ?*TVal }` +
  `TVal { val, point, msecs, prior }`.** Ref holds a `?*TVal` head
  seeded with a single self-terminating node; `deref` = `tvals.?.val`.
  Better: Phase 14 *extends* (splice a TVal onto `prior`) rather than
  replaces; mirrors JVM `Ref.deref → currentVal → tvals.val` 1:1; no
  struct-layout churn. Breaks: **two heap allocations + a second
  registered trace fn / GcHooks** for a path that only reads one
  value; `point` / `msecs` written but never read until Phase 14; the
  node is a Reservation-as-bias materialisation of ADR prose.
- **Alt 3 — wildcard: Alt 1's single `current` cell, but in
  `runtime/stm/ref.zig` with a module docstring stating the Phase-14
  ring-rewrite contract + a `D-NNN` row owning the rewrite.** Better:
  keeps Alt 1's minimal footprint *and* removes its only real risk (a
  silent scaffold that loses its homing path); the Phase-14 owner
  inherits an explicit tracked contract instead of a surprise
  field-swap; honours F-003 (imagine-record-**defer**). Breaks: still
  a field-type swap in Phase 14 (docstring makes it expected, not
  eliminated); adds a debt row + docstring upkeep.
- Findings: **(a)** lock does not belong in Phase 13 (Zig 0.16 removal
  + single-thread + avoids v0's split); **(b)** `min/max_history` /
  `watches` should NOT be declared now (Reservation-as-bias); **(c)**
  a `TVal` *ring* is premature, a single node defensible, but
  materialising it because the ADR pairs the two nouns is the trap
  F-002 §4 names.
- DA recommendation (non-binding): **Alt 3** — "the finished form is
  cleaner *reached from* a deferred-and-documented scalar than
  *anticipated by* a half-built ring." Main loop adopted Alt 3.

## Phase 14 ring activation — doubly-linked self-loop + atomic.Mutex (amendment 4)

Phase 14 row 14.11.5 (D-122 row-assignment + D-102 implementation,
2026-05-28) lands the TVal history ring per the JVM `Ref.java`
shape, refined by a Devil's-advocate fork. The chosen shape:

```zig
pub const TVal = extern struct {
    header: HeapHeader,   // GC contract; tag = .tval (Group D slot 63)
    _pad: [6]u8,
    val: Value,
    point: i64,
    msecs: i64,
    prior: *TVal,         // initial = self (ring of 1)
    next: *TVal,          // initial = self (ring of 1)
};

pub const Ref = extern struct {
    header: HeapHeader,   // GC contract; tag = .ref
    lock: std.atomic.Mutex,   // 1 byte; tryLock + unlock only
    _pad: [5]u8,
    tvals: *TVal,         // ring head (always non-null after alloc)
    min_history: u32 = 0,
    max_history: u32 = 10,
};
```

Decisions recorded:

1. **Doubly-linked self-loop ring (JVM-faithful)**. The initial
   TVal sets `prior = self, next = self`; subsequent commits splice
   between `head` and `head.next` exactly per `Ref.java:64-69`.
   `histCount` walks `tvals.next ... tvals`; `trimHistory` resets
   `next/prior` to self. The reader can hold `Ref.java` open
   side-by-side; field names + splice semantics line up 1:1.

2. **`std.atomic.Mutex` field at Ref level, not placeholder**.
   `std.atomic.Mutex` is `enum(u8)` (verified in stdlib at this
   ADR's land time), extern-compatible, lock-free `tryLock` +
   `unlock`. Lands at D-102 so Phase 15.1 transaction control
   flow extends Ref's API surface without re-laying the struct.
   **Spin-vs-block F-009 wrinkle** (recorded explicitly per the
   DA fork): `std.atomic.Mutex` has no blocking `lock()`. Phase
   15.1's `commit` path must spin (`while (!ref.lock.tryLock())
   { suspend / yield / contention-strategy }`) where JVM blocks.
   This is a real semantic divergence from JVM and is acceptable
   for a Wasm-target single-threaded-first runtime; if Phase 15.4
   bench shows pathological spin, a Phase 15.5 ADR can upgrade
   to `std.Io.Mutex` at the LockingTransaction layer above Ref
   (not at Ref itself, since `std.Io.Mutex` is not extern-
   compatible and would force a `RefObj`/`RefInner` split à la
   v0). F-009 neutrality preserved: Java + cljw + Clojure-peer
   surfaces all share the same Zig impl + the same spin semantics.

3. **TVal is internal-only, but consumes Group D slot 63
   (`reserved_d15` → `tval`)**. The DA fork's decision-point (ii)
   ranked "TVal-not-NaN-boxed-as-Value" as the consensus
   finished-form (= TVal does NOT show up in `tag()` checks,
   `decodePtr` paths, or any user-visible Value surface). It IS
   tagged in the `HeapTag` enum because GC heap allocation +
   per-tag `traceGc` dispatch requires it. The last open Group D
   slot is named, closing the F-002 / D-043 "name the reserve or
   shrink the layout" Phase 7+ predicate for slot 63.

4. **`min_history = 0 / max_history = 10` declared at D-102**.
   The ring-growth machinery (Phase 15.1's `commit` reading both)
   is the first reader; declaring them now matches "Added by the
   owner that first reads them" (amendment 3 § Negative finding
   #3) since D-102 IS the first cycle whose code paths reference
   them (the ring init logic). Not Reservation-as-bias.

5. **GC trace walks the ring via existing mark-bitmap cycle
   detection**. Each TVal traces its `val` + `prior` + `next`;
   the mark-and-recurse in `mark_sweep.zig` checks "already
   marked? return", terminating the self-loop in one pass. Ref's
   trace marks `tvals` + lets the recursion handle the rest. A
   D-102 unit test asserts that a freshly-allocated 1-node ring +
   a manually-constructed 3-node ring both terminate marking
   (count = N, not infinite).

The decision rejected three alternatives — Alt 1 (smallest-diff:
singly-linked + lock absent), Alt 2-as-modified (this amendment;
chosen), Alt 3 (wildcard: array-ring inline in Ref). The full DA
output landed at `private/notes/phase14-d102-da-fork.md` (verbatim);
the relevant rejection rationale per F-NNN:

- **Alt 1 (singly-linked + lock absent)** rejected per F-002 §3
  shrink-not-enlarge: Phase 15.1's `doGet` walks `prior` whether
  singly- or doubly-linked, but `histCount` / `trimHistory` /
  ring-splice all need `next`. Omitting `next` here means Phase
  15.1 re-touches TVal shape — the exact pattern F-002 forbids.
- **Alt 3 (array-ring)** rejected per F-009 + bench risk: the
  hard `max_history ≤ 16` cap and 384-byte fixed Ref cost regress
  the `(ref 42)` for-counter use case ~8×, and `clojure.core/ref-max-history`
  would silently cap or raise — a Java/cljw/Clojure-peer
  neutrality break. A follow-up `private/notes/d102-arena-ring-exploration.md`
  records the bench-validatable hypothesis for Phase 16 review.

Discharges D-122 (row scheduling) + D-102 (implementation). Opens
no new STM debt rows. Phase 15.1's D-114 (transaction control
flow) inherits the unchanged Ref/TVal shape; that cycle's
`LockingTransaction` lands as pure code-add per the DA fork's
"Phase 15.1 saves ~50 LOC" projection.

## References

- ROADMAP §9.6 task 4.7 (try/throw/loop/recur — STM error message
  path), §9.15 (Phase 13 entry), §9.16 (Phase 14 entry, esp. row
  14.11.5 — D-102 ring rewrite), §9.17 (Phase 15.1-15.4)
- ROADMAP §A25 (Existing code is mutable)
- Related ADRs: 0009, 0017, 0018
- JVM source: `clojure.lang.LockingTransaction`

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment 1): Phase 4 unsupported-attempt phrasing
  now references per-sub-operation staged catalog Codes (per
  ADR-0018 amendment 2 sub-feature staged pattern). User messages
  name only the form (`dosync`, `ref`, ...), not this ADR.
- 2026-05-23 (amendment 2): Added "Phase 13-15 migration note"
  section to narrate the staged catalog Code removal and test
  expectation rewrite across Phase 13 / 14 / 15.1-15.4 (per
  ROADMAP §A25 and ADR-0018 amendment 2 "Codes come and go").
- 2026-05-28 (amendment 3): Phase 13 lands `Ref` as a single
  lock-free `current: Value` heap cell (Devil's-advocate Alt 3);
  `std.Thread.Mutex` sketch retired (Zig 0.16 removal), lock
  deferred to Phase 15.1 as `std.Io.Mutex`; `TVal` ring +
  `min/max_history` / `watches` deferred to Phase 14 (tracked by
  D-102). File `src/runtime/stm/ref.zig`.
- 2026-05-28 (amendment 4): Phase 14 row 14.11.5 lands the TVal
  history ring (D-122 + D-102) per JVM `Ref.java` doubly-linked
  self-loop shape. `std.atomic.Mutex` (enum(u8), extern-compatible)
  lands as a real Ref field — Phase 15.1 commit/retry spins on
  `tryLock` since `std.atomic.Mutex` lacks blocking `lock()`. TVal
  consumes Group D slot 63 (`reserved_d15` → `tval`), naming the
  last anonymous reserve. Files `src/runtime/stm/tval.zig` (new),
  `src/runtime/stm/ref.zig` (rewritten), `src/runtime/value/heap_tag.zig`
  (slot 63 named).
