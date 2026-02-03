# ClojureWasm Development Memo

## Current State

- Phase: 14 (Clojure本家テスト基盤)
- Roadmap: .dev/plan/roadmap.md
- Current task: T14.10 — data_structures.clj 等価テスト作成
- Task file: (to be created)
- Last completed: T14.9 — sequences.clj 等価テスト作成 (33 tests, 188 assertions)
- Blockers: none
- Next: T13.7 or Phase 14 completion

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
