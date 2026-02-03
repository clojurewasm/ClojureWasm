# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.5 — clojure.string: blank?, reverse, trim-newline, triml, trimr
- Task file: (none — create on start)
- Last completed: T13.4 — clojure.string: includes?, starts-with?, ends-with?, replace
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
- T13.4: clojure.string — includes?, starts-with?, ends-with?, replace
  - Added 4 functions to clj_string.zig
  - Value boolean type: `Value{ .boolean = ... }` (not .true/.false)
- SCI: 72/74 tests pass, 259 assertions
- Registry: 154 builtins + 9 clojure.string, 277/702 vars done

### T13.5 — clojure.string: blank?, reverse, trim-newline, triml, trimr

Add to clj_string.zig:

- blank? (s) → boolean — true if nil, empty, or only whitespace
- reverse (s) → string
- trim-newline (s) → string — remove trailing \\n \\r
- triml (s) → string — trim left
- trimr (s) → string — trim right

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
