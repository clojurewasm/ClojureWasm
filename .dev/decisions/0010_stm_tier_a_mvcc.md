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
  `ensure` / `ref-set` raise `Code.unsupported_feature` (per
  ADR-0018) with the form name as `.{ .name = "<form>" }`; the
  user-facing message is `"<form> is not supported in ClojureWasm"`.
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

## References

- ROADMAP §9.6 task 4.7 (try/throw/loop/recur — STM error message
  path), Phase 13-15 task tables (to be written when those phases
  open)
- Related ADRs: 0009, 0017
- JVM source: `clojure.lang.LockingTransaction`

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment): Phase 4 unsupported-attempt phrasing now
  references catalog `Code.unsupported_feature` (ADR-0018). User
  messages name only the form (`dosync`, `ref`, ...), not this ADR.
