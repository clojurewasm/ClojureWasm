# ClojureWasm Development Memo

## Current State

- Phase: 15.0 (vars.yaml監査) — complete
- Roadmap: .dev/plan/roadmap.md
- Current task: (none)
- Task file: N/A
- Last completed: T15.0 — vars.yaml Audit
- Blockers: none
- Next: Phase 15 planning (high-priority test files)

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T15.0 vars.yaml Audit Complete

- vars.yaml: 269 done, 428 todo, 7 skip (total 704)
- Actual implemented (clojure.core): 267 unique (builtins + core.clj + special forms)
- catch/finally correctly done (part of try)
- Fixed during audit: fn, let, loop changed to done (were todo)
- No discrepancies remain — vars.yaml accurately reflects implementation

### Phase 14 Complete

- T14.11: compat_test.yaml extended with Clojure JVM tests (178 tests, 998 assertions)
- T14.12: Test file priority list created (.dev/notes/test_file_priority.md)
  - High Priority (low Java dep): 12 files (macros, special, walk, set, string, etc.)
  - Medium Priority (moderate Java): 13 files
  - Low Priority (high Java): 27 files
  - Skip (JVM infrastructure): 9 files

### Phase 15 Direction

Next phase should focus on:

1. Porting high-priority test files (Batch 1: macros, special, walk, etc.)
2. Implementing missing features as tests reveal gaps
3. TDD approach: write test, fail, implement, pass

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
- T14.5.4: Empty list () self-evaluation (F55, F56, F57, F60 resolved)
  - analyzer.zig: empty list returns empty list, not nil
  - () now evaluates to () (self-evaluating in Clojure)
- T14.5.5: pop nil + set coercion (F59, F63, F64 resolved)
  - (pop nil) returns nil (matches JVM Clojure 1.12.4)
  - (set {}) and (set {:a 1}) work (map entries become vectors)
  - (set "") and (set "abc") work (string becomes set of chars)
- F61: Not a bug — JVM Clojure also throws on (keys [1 2])
- Remaining: F58 (nested map destructuring) — deferred as feature

### Completed: T14.10 — data_structures.clj

- 17 tests, 203 assertions (TreeWalk)
- Covers: equality, count, conj, peek, pop, list, find
- contains?, keys, vals, key, val, get/get-in
- hash-set, set, disj, assoc
- All bugs resolved in Phase 14.5 except F58 (nested map destructuring)

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
