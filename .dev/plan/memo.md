# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: Phase 14 planning
- Task file: (none)
- Last completed: T13.10 — Upstream alignment (memoize, trampoline)
- Blockers: none
- Next: T13.7

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 13 Progress

- T13.1: list?, int?, reduce/2, set-as-fn, deref-delay, conj-map-vector-pairs
- T13.2: Named fn self-ref (identity preserved), fn param shadow (D49)
- T13.3: clojure.string — join, split, upper-case, lower-case, trim
- T13.4: clojure.string — includes?, starts-with?, ends-with?, replace
- T13.5: clojure.string — blank?, reverse, trim-newline, triml, trimr (14 builtins)
- T13.6: key, val builtins added to sequences.zig (156 builtins + 14 clojure.string)
- T13.7: Skipped — all 4 functions already implemented
- T13.8: {:keys [:a]} keyword destructuring — analyzer accepts keywords in :keys vector
- T13.9: SCI validation — 72/72 tests, 267 assertions
- T13.10: Upstream alignment — memoize (if-let/find/val), trampoline (let+recur)
  - Both UPSTREAM-DIFF notes removed from vars.yaml
- SCI: 72/72 tests, 267 assertions
- Vars: 284/702 done
- Phase 13 complete

### Next: Phase 14 — Clojure本家テスト基盤

Phase 14 が roadmap.md に追加済み。最初のタスクは:

- T14.1: clojure.test/deftest, is, testing 移植

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
