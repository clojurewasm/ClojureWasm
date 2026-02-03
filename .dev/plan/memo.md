# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.2 — subvec, array-map, hash-set, sorted-map
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.1 completed — collection gaps

Added 6 builtins: dissoc, disj, find, peek, pop, empty
Registry: 126 builtins, 237/702 vars implemented

### T12.2 scope

4 collection constructors/utilities:

- `subvec` — vector slice: (subvec v start) or (subvec v start end)
- `array-map` — create map from key-value pairs (like hash-map but preserves order)
- `hash-set` — create set from values
- `sorted-map` — create sorted map (need to decide on implementation approach)

### Deferred items to watch

- **F23**: T12.4 (Reduced) adds a new Value variant → implement comptime
  verification that all critical switch statements handle every variant
  (no dangerous `else => {}` catch-alls). See SS3, checklist.
- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

126 builtins registered
237/702 vars implemented
