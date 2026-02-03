# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.10 — Upstream alignment (UPSTREAM-DIFF cleanup)
- Task file: (none — create on start)
- Last completed: T13.9 — SCI test validation: 72/72, 267 assertions
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
  - Total was 72 all along (not 74 — miscount)
  - Added clojure.string tests to string-operations-test (+6 assertions)
  - Enabled gensym starts-with? assertion (+1)
  - Only remaining skip: var :name metadata in meta-test
- Vars: 284/702 done

### T13.10 — Upstream alignment (UPSTREAM-DIFF cleanup)

Replace simplified defs with upstream verbatim where possible.

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
