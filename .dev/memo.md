# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 51 COMPLETE** + zwasm integration (D92) done
- Coverage: 835+ vars (635/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.1.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 44 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (post-zwasm entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 51: Agent Subsystem — COMPLETE

- [x] 51.1: AgentObj value type + agent constructor + deref
- [x] 51.2: send/send-off action dispatch (per-agent serial queue)
- [x] 51.3: Error handling (agent-error, set-error-handler!, set-error-mode!, restart-agent)
- [x] 51.4: await/await-for synchronization
- [x] 51.5: Remaining agent vars (clear-agent-errors, release-pending-sends, *agent*)
- [x] 51.6: vars.yaml update + *agent* dynamic var binding

## Current Task

Phase 52: Bug fixes + polish. Plan next task.

## Previous Task

Phase 51 + post-51 fixes:
- Agent subsystem: 15 vars (agent, send, send-off, await, error handling, *agent*)
- error-handler/error-mode getters + fix default error mode
- Upstream agent tests ported (5 tests, 13 assertions)
- **Fix collection hash bug**: computeHash returned 42 for all collections,
  causing SIGILL crash in case with collection constants (control.clj)
  → proper ordered/unordered hash for vector/list/map/set/cons/lazy-seq
- Coverage: 635/706 core vars done

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)

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
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
