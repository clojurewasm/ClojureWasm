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

### T10.4 Background — fn_val Dispatch Unification

T10.2 review で発覚: fn_val呼び出しが5箇所に散在し、各自が別々の
ディスパッチ手段を持つ。全て「fn_valを引数付きで呼ぶ」という同一操作。

現状の5つのディスパッチ機構:

1. `vm.zig` — `fn_val_dispatcher` callback (VM→TW)
2. `tree_walk.zig` — `bytecode_dispatcher` callback (TW→VM)
3. `atom.zig` — `call_fn` module var (kindチェックなし)
4. `value.zig` — `realize_fn` module var (kindチェックなし)
5. `analyzer.zig` — `macroEvalBridge` 直接渡し

→ 1つの `callFnVal(allocator, env, fn_val, args)` に統合。
詳細は roadmap.md Phase 10c、decisions.md D34 follow-up を参照。
