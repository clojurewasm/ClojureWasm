# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 65 COMPLETE**
- Coverage: 869+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 18 namespaces total)
- Wasm engine: zwasm v0.1.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 50 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (60.4 entry = latest baseline)
- Binary: 3.7MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (3.7MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Current Task

Phase 66: deps.edn Foundation. Next task: 66.5 (-Spath/-Sdeps/-Srepro/-Sforce).
See `.dev/deps-edn-plan.md` for full design and task breakdown.

## Task Queue

Phase 66 — deps.edn Foundation:
- [x] 66.1: deps.edn parser (EDN reader + schema validation)
- [x] 66.2: Alias resolution engine
- [x] 66.3: -A/-M/-X/-P CLI flag parsing (includes -X exec mode)
- [x] 66.4: -X exec mode (fn invoke + arg parsing) — merged into 66.3
- [ ] 66.5: -Spath/-Sdeps/-Srepro/-Sforce

## Previous Task

Phase 65: Edge case cleanup (pre-deps.edn) — apropos/dir tests, reader duplicate
key detection, fn docstring analyzer fix, regex serialization in bootstrap cache,
*print-dup* basic support.

## Known Issues

(none)

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
| Baselines          | `.dev/baselines.md`                  | Non-functional thresholds   |
| deps.edn plan      | `.dev/deps-edn-plan.md`              | When implementing deps.edn  |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
