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

Phase 70.6 COMPLETE. All 6 sub-tasks done (70.6.1-70.6.6).

Summary: 8 S markers resolved (syntax-quote fix), 2 R markers resolved (report
defmulti, assert-expr multimethod), 5 R markers reclassified to P, 2 new P added.
R markers reduced from 27 to 13. Full audit updated in cljw-diff.md.

## Task Queue

```
Phase 70.6: Reducible CLJW marker resolution
Phase 71: Library Compatibility Testing (5 libraries)
  71.1: medley
  71.2: hiccup
  71.3: clojure.data.json
  71.4: honeysql
  71.5: camel-snake-kebab

Phase 72: Optimization + GC Assessment
  72.1: Profiling infrastructure
  72.2: Targeted optimizations
  72.3: GC assessment report

Phase 73: Generational GC (conditional on Phase 72 findings)
  73.1-73.4: Design → write barriers → nursery → integration
```

## Previous Task

Phase 70.6: Reducible CLJW marker resolution (6 sub-tasks).
Syntax-quote fix, stale marker cleanup, report/assert-expr multimethod, audit update.

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
| Next phases plan   | `.dev/next-phases-plan.md`           | Phase 70-73 plan            |
| spec.alpha upstream| `~/Documents/OSS/spec.alpha/`        | spec.alpha reference source |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
