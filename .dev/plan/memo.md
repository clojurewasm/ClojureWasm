# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.3 — Hash & identity: hash, identical?, ==
- Task file: (none)
- Last completed: T12.2 — subvec, array-map, hash-set, sorted-map
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.2 completed — collection constructors

Added 4 builtins: subvec, array-map, hash-set, sorted-map

- subvec: copy-based vector slice (not view-based)
- array-map: identical to hash-map (PersistentArrayMap already preserves order)
- hash-set: deduplicating set constructor
- sorted-map: entries sorted by key at construction (D45: not tree-based)

Registry: 130 builtins, 245/702 vars implemented (was 126/237 before Phase 12)

### T12.3 scope

3 builtins: hash, identical?, ==

- `hash` — return hash code for any Value
- `identical?` — pointer/value identity check (not structural equality)
- `==` — numeric cross-type equality (different from `=` which is structural)

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
