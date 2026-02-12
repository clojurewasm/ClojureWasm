# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 55 COMPLETE**
- Coverage: 837+ vars (637/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.11.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 49 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (zwasm-v0.11.0 entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 55: Upstream Test Recovery
- ~~55.1: Restore Java static field references in upstream tests~~ DONE
- ~~55.2: Restore Double/POSITIVE_INFINITY in reader.clj~~ DONE
- ~~55.3: N/A — upstream tests don't use parseInt/toBinaryString directly~~

## Current Task

Phase 57 complete. Next: read roadmap.md for next phase.

## Task Queue

(empty — Phase 57 done)

## Previous Task

Phase 57: Concurrency Test Suite — all 15 sub-tasks complete.
- 57.1-57.4: Zig-level GC concurrency tests (`src/runtime/concurrency_test.zig`)
- 57.5-57.15: Clojure concurrency stress tests (`test/cw/concurrency_stress.clj`)
- Bug found & fixed: swap!/swap-vals! had no CAS retry loop — lost updates under contention.
  Fixed with `@cmpxchgStrong` CAS loop. reset!/reset-vals! also made atomic (`@atomicRmw .Xchg`).
  deref on atom uses `@atomicLoad` for safe cross-thread reads.
- All 10 Clj tests (33 assertions) pass on both VM and TreeWalk.

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- binding *ns* doesn't affect read-string for auto-resolved keywords

## Resolved Issues (this session)

- **swap! race condition**: swap!/swap-vals! had no CAS retry loop. Fixed with lock-free
  `@cmpxchgStrong` CAS. Also made reset!/reset-vals!/deref atomic.
- **Checklist cleanup**: F136/F137 resolved (zwasm v0.11.0 implements table.copy
  cross-table + table.init). F6 resolved (multi-thread dynamic bindings done).
- **Regex fix**: Capture groups + backreferences actually work — removed from Known Issues.

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions

## Reference Chain

Session resume: read this file → roadmap.md → pick next task.

| Topic              | Location                             | When to read                |
|--------------------|--------------------------------------|-----------------------------|
| Roadmap            | `.dev/roadmap.md`                    | Always — next phases        |
| Deferred items     | `.dev/checklist.md`                  | When planning next work     |
| Decisions          | `.dev/decisions.md` (D3-D93)         | On architectural questions  |
| Optimizations      | `.dev/optimizations.md`              | Performance work            |
| Benchmarks         | `bench/history.yaml`                 | After perf changes          |
| Wasm benchmarks    | `bench/wasm_history.yaml`            | After wasm changes          |
| Cross-language     | `bench/cross-lang-results.yaml`      | Comparison context          |
| Skip recovery      | `.dev/skip-recovery.md`              | When implementing skips     |
| Test porting       | `.dev/test-porting-plan.md`          | When porting tests          |
| Design document    | `.dev/future.md`                     | Major feature design        |
| Zig tips           | `.claude/references/zig-tips.md`     | Before writing Zig          |
| Concurrency tests  | `.dev/concurrency-test-plan.md`      | Phase 57 task details       |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
