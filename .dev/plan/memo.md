# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.3 — clojure.string: join, split, upper-case, lower-case, trim
- Task file: (none — create on start)
- Last completed: T13.2 — Named fn self-reference + fn param shadow fixes
- Blockers: none
- Next: T13.3

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 13 Progress

- T13.1: list?, int?, reduce/2, set-as-fn, deref-delay, conj-map-vector-pairs
- T13.2: Named fn self-ref (identity preserved), fn param shadow (D49)
- SCI: 72/74 tests pass, 259 assertions
- Registry: 154 builtins, 268/702 vars done

### T13.3 — clojure.string namespace

Need to implement a new namespace `clojure.string` with Zig builtins.
This is the first non-clojure.core namespace.

Key decisions:

- How to register builtins in a non-core namespace
- Whether to create a separate .zig file for string namespace builtins
- Current namespace mechanism: env.zig findOrCreateNamespace

Functions to implement:

- join, split, upper-case, lower-case, trim
- These are Zig-level string operations

Reference: Beta may have clojure.string implementation.

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
