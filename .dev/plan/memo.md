# ClojureWasm Development Memo

## Current State

- Phase: 9.5 (Infrastructure Fixes)
- Roadmap: .dev/plan/roadmap.md
- Current task: T9.5.4 VM benchmark baseline
- Task file: (none — create on start)
- Last completed: T9.5.5 bound? builtin + defonce
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T9.5.4: VM benchmark baseline

- Run all 11 benchmarks with --backend=vm
- Record baseline in bench.yaml
- Check bench/README.md for how to run with --backend=vm
- May need to check if CLI supports --backend flag
