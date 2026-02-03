# ClojureWasm Development Memo

## Current State

- Phase: 14.5 (Bug Fix Round) — complete
- Roadmap: .dev/plan/roadmap.md
- Current task: (none - Phase 14.5 complete)
- Task file: N/A
- Last completed: T14.5.3 — postwalk-replace on set literal (F65)
- Blockers: none
- Next: Continue Phase 14 (T14.11+) or move to Phase 15

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 14 Progress

- T14.1: clojure.test/deftest, is, testing implemented
  - Created src/clj/clojure/test.clj (minimal framework)
  - Added loadTest to bootstrap.zig
  - SCI core_test.clj now uses clojure.test (inline framework removed)

- T14.2: clojure.test/are + clojure.walk functions
  - Implemented walk, postwalk, prewalk, postwalk-replace, prewalk-replace in core.clj
  - Implemented apply-template, do-template in core.clj
  - Added `are` macro to clojure/test.clj
  - 72/72 tests, 267 assertions pass (TreeWalk)

### Completed: Phase 14.5 — Bug Fix Round

- T14.5.1: assoc on vectors (F66 resolved)
  - Added vector support to assocFn
  - (assoc [1 2 3] 1 99) => [1 99 3]
- T14.5.2: seq/reduce on set (F62 resolved)
  - Added set support to seqFn
  - (seq #{1 2 3}) => (1 2 3)
  - reduce/map/filter now work on sets directly
- T14.5.3: postwalk-replace on set literal (F65 resolved)
  - Fixed automatically by T14.5.2 (walk uses seq internally)
  - Removed workarounds from data_structures.clj
- data_structures.clj: 17 tests, 203 assertions (was 201)

### Completed: T14.10 — data_structures.clj

- 17 tests, 203 assertions (TreeWalk)
- Covers: equality, count, conj, peek, pop, list, find
- contains?, keys, vals, key, val, get/get-in
- hash-set, set, disj, assoc
- Discovered bugs: F55-F64 (F65/F66 resolved in Phase 14.5)
- Remaining workarounds:
  - F57/F60: use empty? instead of = on empty lists

### Completed: T14.9 — sequences.clj

- 33 tests, 188 assertions (TreeWalk)
- Covers: first/rest/next/cons, fnext/nfirst, last, nth, distinct
- interpose, interleave, zipmap, concat, cycle, iterate
- reverse, take/drop, take-while/drop-while, butlast
- repeat, range, partition, partition-all
- every?/not-every?/not-any?/some, flatten, group-by
- partition-by, frequencies
- Excluded: set/string sequences (F40/F41), ffirst/nnext (F43/F44)
- Excluded: drop-last/split-at/split-with (F46/F47)
- Excluded: infinite range (F48), partition with step (F49)
- Excluded: reductions/shuffle (F50/F51)

### Completed: T14.8 — atoms.clj

- 14 tests, 39 assertions
- atom creation, deref, swap!, reset!, compare-and-set!
- vars.yaml: compare-and-set! done に更新

### for macro issues (F25, F26)

- F25: :while modifier not implemented — skips silently
- F26: :let + :when combination fails — needs investigation

### Known Issues

- **VM SCI tests failure**: SCI tests pass on TreeWalk but fail early on VM
  - Simple deftest works on VM, issue is with large file or specific constructs
  - Low priority — TreeWalk is current primary backend

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
