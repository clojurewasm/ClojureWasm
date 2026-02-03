# ClojureWasm Development Memo

## Current State

- Phase: 14 (Clojure本家テスト基盤)
- Roadmap: .dev/plan/roadmap.md
- Current task: T14.3 — test-ns-hook / fixtures (optional)
- Task file: (none — create on start)
- Last completed: T14.2 — clojure.test/are, run-tests 移植
- Blockers: none
- Next: T13.7

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

### Next: T14.3 — test-ns-hook / fixtures (optional)

- Can skip if not needed for Phase 14b (等価テスト作成)
- Consider proceeding to T14.4 (for.clj) instead

### Known Issues

- **VM SCI tests failure**: SCI tests pass on TreeWalk but fail early on VM
  - Simple deftest works on VM, issue is with large file or specific constructs
  - Low priority — TreeWalk is current primary backend

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
