# ClojureWasm Development Memo

## Current State

- Phase: 9.5 complete — next phase TBD (check roadmap)
- Roadmap: .dev/plan/roadmap.md
- Current task: (Phase 9.5 complete — advance to next phase)
- Task file: (none)
- Last completed: T9.5.4 VM benchmark baseline
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 9.5 complete

All 5 tasks done:

- T9.5.1: VM fn_val lifetime fix (Compiler.detachFnAllocations)
- T9.5.2: swap! fn_val support (atom.call_fn dispatcher)
- T9.5.3: seq on map (MapEntry vectors)
- T9.5.5: bound? + defonce
- T9.5.4: VM bench baseline (3/11 pass, fib_recursive 7x faster than TW)

VM parity gaps: loop/recur correctness, core.clj HOF dispatch from VM.
Next phase should be planned based on project priorities.
