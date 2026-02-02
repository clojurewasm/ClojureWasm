# ClojureWasm Development Memo

## Current State

- Phase: 9.5 (Infrastructure Fixes)
- Roadmap: .dev/plan/roadmap.md
- Current task: T9.5.2 swap! with fn_val (closure dispatch)
- Task file: (none — create on start)
- Last completed: T9.5.1 VM evalStringVM fn_val lifetime fix
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T9.5.2: swap! with fn_val (closure dispatch)

- F5 in checklist: swap! only accepts builtin_fn, not user closures (fn_val)
- swap! is in src/common/builtin/ — need to find where it dispatches
- Should call fn_val via TreeWalk.callValue or similar dispatch
- Related: T9.5.1 fixed fn_val lifetime in evalStringVM (Compiler.detachFnAllocations)
