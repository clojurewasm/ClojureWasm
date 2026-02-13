# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 59 COMPLETE**
- Coverage: 869+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 18 namespaces total)
- Wasm engine: zwasm v0.11.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 50 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (zwasm-v0.11.0 entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Current Task

Phase 60: Startup & Memory Optimization.
Task 60.3: Binary size audit and optimization.

## Task Queue

- 60.3: Binary size audit and optimization
- 60.4: Record benchmarks, update docs

## Previous Task

Phase 60.1-60.2 complete: Protocol/ProtocolFn serialization (D95).
Root cause: reloadProtocolNamespaces re-evaluated ~440 lines at every startup.
Fix: Serialize Protocol/ProtocolFn in bootstrap cache + generation counter
for ProtocolFn inline cache + method replacement in extend_type_method.
Result: startup 23.3ms → 5.3ms, memory 226MB → 8.1MB.

## Known Issues

- binding *ns* doesn't affect read-string for auto-resolved keywords (F138)

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
