# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.5 — eval, macroexpand, macroexpand-1, read-string
- Task file: (none)
- Last completed: T12.4 — Reduced: reduced, reduced?, unreduced, ensure-reduced
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.4 completed — Reduced value variant

Added `.reduced` as 21st Value variant + 4 builtins.

- F23 resolved: Zig exhaustive switch IS the comptime verification (D46)
- 8 files needed `.reduced` handler added
- core.clj `reduce` updated to check `reduced?` for early termination
- Registry: 137 builtins, 252/702 vars implemented

### T12.5 scope

eval, macroexpand, macroexpand-1, read-string

- `eval` — runtime eval pipeline: read -> analyze -> evaluate
- `macroexpand` / `macroexpand-1` — expand macros
- `read-string` — parse string to form
- These require hooking into the existing reader/analyzer/evaluator pipeline

### Deferred items to watch

- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

137 builtins registered
252/702 vars implemented
