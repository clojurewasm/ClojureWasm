# ClojureWasm Development Memo

## Current State

- Phase: 10 complete
- Roadmap: .dev/plan/roadmap.md
- Current task: (phase planning needed)
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 10 Summary

All 4 tasks complete:

- T10.1: Fixed VM loop/recur (pop_under bug)
- T10.2: Added TreeWalk-to-VM reverse dispatch (bytecodeCallBridge)
- T10.3: Fixed nested fn use-after-free in compiler (D35/F18), recorded VM baseline
- T10.4: Unified 5 fn_val dispatch mechanisms into single callFnVal (D36)

### VM Performance Profile

VM is 4-9x faster for pure computation but slower for HOF-heavy workloads
due to cross-backend dispatch (VM -> TW -> VM). Key opportunity: compile
core.clj HOFs (map, filter, reduce) with VM to eliminate cross-backend overhead.

### Next Phase Considerations

Check checklist.md for priorities:

- AOT pipeline (F7) would enable VM-compiled core.clj -> eliminates HOF overhead
- Missing core features: memoize, trampoline, apply improvements
- Possible: VM optimization, ReleaseFast benchmarks
