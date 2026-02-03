# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.4 — Reduced: reduced, reduced?, unreduced, ensure-reduced
- Task file: (none)
- Last completed: T12.3 — Hash & identity: hash, identical?, ==
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.3 completed — hash & identity

Added 3 builtins: hash, identical?, ==

- hash: polynomial rolling hash (x31) for strings/keywords/symbols, int=itself, nil=0
- identical?: value-type bit equality, pointer equality for collections, name equality for keywords/symbols
- ==: numeric-only equality (TypeError on non-numbers, unlike = which is structural)

Registry: 133 builtins, 248/702 vars implemented

### T12.4 scope

4 builtins: reduced, reduced?, unreduced, ensure-reduced

- Needs new Value variant (.reduced) — triggers F23 (comptime variant verification)
- reduced wraps a value for early termination in reduce
- This is a significant change: adding a new Value variant

### Deferred items to watch

- **F23**: T12.4 (Reduced) adds a new Value variant → implement comptime
  verification that all critical switch statements handle every variant
  (no dangerous `else => {}` catch-alls). See SS3, checklist.
- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

130 builtins registered
245/702 vars implemented
