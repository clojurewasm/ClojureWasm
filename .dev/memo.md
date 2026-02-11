# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 51 COMPLETE** + zwasm integration (D92) done
- Coverage: 830+ vars (633/706 core, 16 namespaces total)
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

Phase 51 complete. Plan next phase.

## Previous Task

Phase 51: Agent Subsystem — complete.
- AgentObj value type + NaN-boxed DeferredKind.agent
- send/send-off with per-agent serial queue via thread pool
- Error handling: :fail/:continue modes, error-handler, restart-agent
- await/await-for synchronization via condition variable
- *agent* dynamic var binding during action processing
- 13 vars recovered from skip → done (633/706 core)

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
