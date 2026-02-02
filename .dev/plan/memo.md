# ClojureWasm Development Memo

## Current State

- Phase: 10 (VM Correctness + VM-CoreClj Interop)
- Roadmap: .dev/plan/roadmap.md
- Current task: **T10.3 — VM benchmark re-run + recording**
- Task file: (none — create on start)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T10.2 Completed — Reverse Dispatch

TreeWalk→VM reverse dispatch is now working via `bytecodeCallBridge` in
bootstrap.zig. The bidirectional call bridge is:

- VM → TreeWalk: `fn_val_dispatcher` → `macroEvalBridge` (existing)
- TreeWalk → VM: `bytecode_dispatcher` → `bytecodeCallBridge` (new)

All 11 benchmarks should now work with `--backend=vm` since core.clj HOFs
(map, filter, reduce) can call back into VM-compiled callbacks without segfault.

### T10.3 Scope

Re-run all 11 benchmarks with both backends (TreeWalk default + VM).
Record VM baseline in bench.yaml. Compare with TreeWalk baseline from Phase 5.

Key files:

- `bash bench/run_bench.sh` — run benchmarks
- `bash bench/run_bench.sh --record --version="Phase 10 VM baseline"` — record
- `.dev/status/bench.yaml` — benchmark results
