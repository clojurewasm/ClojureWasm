# Phase 57: Concurrency Test Suite

Concurrency regression tests for CW. Two layers: Zig (GC/thread internals)
and Clojure (behavioral correctness). Protects against regressions when
implementing generational GC, stop-the-world improvements, etc.

## Task Queue

### A. GC under concurrency — Zig tests (src/runtime/thread_pool.zig or new file)

| Sub  | Test                                          | What it guards                          |
|------|-----------------------------------------------|-----------------------------------------|
| 57.1 | Multiple futures allocating concurrently      | GC mutex contention, no crash           |
| 57.2 | GC collection during future execution         | Worker roots not swept                  |
| 57.3 | Agent actions with heavy allocation           | GC trigger under agent processing       |
| 57.4 | deref-blocked thread survives GC              | Waiting thread's value not collected    |

### B. Stress tests — Clojure tests (test/upstream/clojure/test_clojure/concurrency_stress.clj)

| Sub  | Test                                          | What it guards                          |
|------|-----------------------------------------------|-----------------------------------------|
| 57.5 | atom swap! N-thread contention                | CAS retry correctness                   |
| 57.6 | delay N-thread simultaneous deref             | call-once guarantee                     |
| 57.7 | Mass future spawn + collect all results       | Thread pool stability under load        |
| 57.8 | Agent high-frequency send                     | Queue saturation, ordering              |

### C. Binding conveyance — Clojure tests (test/upstream/clojure/test_clojure/concurrency_stress.clj)

| Sub  | Test                                          | What it guards                          |
|------|-----------------------------------------------|-----------------------------------------|
| 57.9 | future inherits *out*/*in* bindings           | Dynamic var propagation                 |
| 57.10| Nested binding + future (frame integrity)     | Binding stack not corrupted             |
| 57.11| Agent send inherits bindings                  | Agent binding conveyance                |

### D. Lifecycle / edge cases — Clojure tests (test/upstream/clojure/test_clojure/concurrency_stress.clj)

| Sub  | Test                                          | What it guards                          |
|------|-----------------------------------------------|-----------------------------------------|
| 57.12| shutdown-agents then send → error             | Graceful shutdown                       |
| 57.13| future-cancel                                 | Cancellation semantics                  |
| 57.14| promise deref with timeout                    | Timeout path correctness                |
| 57.15| agent restart-agent after error               | Error recovery lifecycle                |

## Design Notes

- Zig tests (A): Direct thread spawning + GC interaction. In thread_pool.zig
  or a new `src/runtime/concurrency_test.zig` (imported from root.zig for test).
- Clojure tests (B-D): `test/cw/concurrency_stress.clj` — CW-original,
  not upstream port. Uses `clojure.test`, run with standard test runner.
- Stress tests use configurable thread count (default 8, CI-friendly).
- All tests must be deterministic — use barriers/latches where needed,
  not sleep-based timing.
- CW barrier equivalent: use promise as latch (deliver = release).

## Completion Criteria

- All Zig tests pass under `zig build test`
- All Clojure tests pass on both VM and TreeWalk backends
- No hangs, no crashes, no GC-related segfaults under stress
