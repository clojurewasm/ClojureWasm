# ClojureWasm Development Memo

## Current State

- Phase: 14 (Clojure本家テスト基盤)
- Roadmap: .dev/plan/roadmap.md
- Current task: T14.2 — clojure.test/are, run-tests 移植
- Task file: (none — create on start)
- Last completed: T14.1 — clojure.test/deftest, is, testing 移植
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
  - 72/72 tests, 267 assertions pass (TreeWalk)
  - VM backend issue: SCI tests fail on VM — needs investigation

### Next: T14.2 — clojure.test/are, run-tests 移植

- `are` macro needs clojure.template or custom template expansion
- May need to enhance run-tests with more reporting options

### Known Issues

- **VM SCI tests failure**: SCI tests pass on TreeWalk but fail early on VM
  - Simple deftest works on VM, issue is with large file or specific constructs
  - Low priority — TreeWalk is current primary backend

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
