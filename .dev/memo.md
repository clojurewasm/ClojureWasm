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

Phase 70.5: spec.gen implementation + CLJW workaround audit — sub-task 70.5.4.

70.5.3 done: Removed stale gen stub CLJW marker (gen now implemented). Clarified fspec,
k-gen, ex-info comments. 36 CLJW + 2 UPSTREAM-DIFF markers remain (all permanent Java→Zig diffs).

## Task Queue

```
Phase 70.5: spec.gen + CLJW workaround audit
  70.5.4: CLJW workaround full audit

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

Phase 70.5.3: spec UPSTREAM-DIFF reduction.
Removed 1 stale CLJW marker (gen stub), clarified fspec/k-gen/ex-info comments.
36 CLJW + 2 UPSTREAM-DIFF markers remain, all permanent Java→Zig diffs.

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
