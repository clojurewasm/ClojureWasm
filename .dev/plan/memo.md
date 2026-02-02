# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.1 — Collection gaps: dissoc, disj, find, peek, pop, empty
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 12 planned

Phase 12a: Tier 1 Zig builtins (T12.1-T12.8)
Phase 12b: SCI test port (T12.9)
Phase 12c: Tier 2 core.clj expansion (T12.10-T12.12)

### T12.1 scope

6 builtins to add (all Zig, in collections module):

- `dissoc` — remove key from map
- `disj` — remove value from set
- `find` — lookup key in map, return MapEntry or nil
- `peek` — stack top (vector last, list first)
- `pop` — stack pop (vector butlast, list rest)
- `empty` — return empty collection of same type

These are fundamental collection operations that many Tier 2 core.clj
functions depend on. `find` is especially important as a dependency for
upstream-compatible memoize.

### Builtin Count

120 builtins registered
231/702 vars implemented
