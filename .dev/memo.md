# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 70 COMPLETE** (spec.alpha fully implemented)
- Coverage: 871+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 18 namespaces total)
- Wasm engine: zwasm v0.2.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 51 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v0.2.0 entry = latest baseline)
- Binary: 3.80MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (3.7MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

## Current Task

Phase 71: Library Compatibility Testing. Sub-task 71.3 (clojure.data.json) next.

71.1 done: medley 80.4% pass (222/276). All failures are Java interop.
71.2 done: hiccup skipped (heavy Java interop: URI, URLEncoder, extend-protocol on Java types).
  Replaced with camel-snake-kebab: 98.6% pass (145/147). 2 fails = clojure.string/split edge case.

## Task Queue

```
Phase 71: Library Compatibility Testing
  71.3: clojure.data.json
  71.4: honeysql

Phase 72: Optimization + GC Assessment
  72.1: Profiling infrastructure
  72.2: Targeted optimizations
  72.3: GC assessment report

Phase 73: Generational GC (conditional on Phase 72 findings)
  73.1-73.4: Design → write barriers → nursery → integration
```

## Previous Task

Phase 71.2: camel-snake-kebab compatibility test.
98.6% pass rate (145/147). 2 failures: clojure.string/split trailing empty string behavior.
GC crash discovered in heavy nested loops (>60 iterations with protocol dispatch).

## Known Issues

- GC crash in heavy nested loops with protocol dispatch (>60 iterations).
  Manifests as segfault in Namespace.resolve → hash. Pre-existing issue.

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
| Next phases plan   | `.dev/next-phases-plan.md`           | Phase 70-73 plan            |
| spec.alpha upstream| `~/Documents/OSS/spec.alpha/`        | spec.alpha reference source |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
