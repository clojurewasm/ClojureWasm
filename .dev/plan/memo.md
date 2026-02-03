# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.4 — clojure.string: includes?, starts-with?, ends-with?, replace
- Task file: (none — create on start)
- Last completed: T13.3 — clojure.string: join, split, upper-case, lower-case, trim
- Blockers: none
- Next: T13.4

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 13 Progress

- T13.1: list?, int?, reduce/2, set-as-fn, deref-delay, conj-map-vector-pairs
- T13.2: Named fn self-ref (identity preserved), fn param shadow (D49)
- T13.3: clojure.string namespace — join, split, upper-case, lower-case, trim
  - New file: src/common/builtin/clj_string.zig
  - Registered in registry.zig registerBuiltins
  - Fixed resolveVar for full namespace name lookup
- SCI: 72/74 tests pass, 259 assertions
- Registry: 154 builtins + 5 clojure.string, 273/702 vars done

### T13.4 — clojure.string search/replace ops

Add to clj_string.zig:

- includes? (s substr) → boolean
- starts-with? (s substr) → boolean
- ends-with? (s substr) → boolean
- replace (s match replacement) → string

These unlock the SCI gensym-test workaround fix (uses subs instead of starts-with?).

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
