# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.2 — Named fn self-reference + fn param shadow fixes
- Task file: (none — create on start)
- Last completed: T13.1 — list?, int?, reduce/2, set-as-fn, deref-delay
- Blockers: none
- Next: T13.2

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T13.1 Results

- Added list?, int? predicates (predicates.zig)
- Multi-arity reduce (2-arity uses first as init)
- Set-as-function in tree_walk.zig callValue + runCall
- Deref on delay maps in atom.zig
- Conj on map with vector pairs in collections.zig
- SCI: 71/74 tests pass, 257 assertions (was 70/74, 248)
- Registry: 154 builtins, 268/702 vars done

### T13.2 — Named fn self-ref + fn param shadow

Two behavioral fixes:

1. **Named fn self-reference**: `(fn foo [] foo)` should return the function itself
   - Currently returns a different identity when called
   - In tree_walk.zig, the fn name binding may not point to the correct closure
   - Look at tree_walk.zig:274-282 for name binding logic

2. **fn as param name shadows**: `(fn [if] if)` should work
   - Using a special form name as a param shadows it
   - Currently crashes
   - Look at analyzer.zig for special form resolution priority

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
