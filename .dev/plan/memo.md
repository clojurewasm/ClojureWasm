# ClojureWasm Development Memo

## Current State

- Phase: 9.5 (Infrastructure Fixes)
- Roadmap: .dev/plan/roadmap.md
- Current task: T9.5.3 seq on map (MapEntry)
- Task file: (none — create on start)
- Last completed: T9.5.2 swap! with fn_val (closure dispatch)
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T9.5.3: seq on map (MapEntry)

- (seq {:a 1}) should return ([:a 1]) — list of map entry vectors
- Needed for map HOFs (map over maps, merge-with, etc.)
- MapEntry = 2-element vector [k v]
- Affects: value.zig (seq conversion), collections.zig or seq utilities
- Related: atom.call_fn pattern from T9.5.2 may be useful for other HOF builtins
