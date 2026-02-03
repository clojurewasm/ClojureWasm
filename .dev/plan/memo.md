# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.9 — SCI test re-run: target 74/74 pass
- Task file: (none — create on start)
- Last completed: T13.8 — {:keys [:a]} keyword destructuring
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
- SCI: 72/74 tests pass, 260 assertions
- Vars: 284/702 done

### T13.9 — SCI test re-run: target 74/74 pass

Check remaining 2 skipped tests and attempt to enable them.

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
