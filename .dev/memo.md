# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 60 COMPLETE**
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

Phase 62.1: F99 Iterative lazy-seq realization engine.
Deep nested lazy-seq (map→filter→map→...) の realize が再帰的で stack overflow する。
D74 は filter chain collapsing で sieve を修正したが、一般ケースは未対応。

## Task Queue

Phase 61 — Bug Fixes:
- [x] 61.1: F138 binding *ns* + read-string
- [x] 61.2: record hash edge case (already works — stale CLJW marker removed)

Phase 62 — Edge Cases:
- [ ] 62.1: F99 Iterative lazy-seq realization engine

Phase 63 — import → wasm mapping:
- [ ] 63.1: F135 :import-wasm ns macro

Phase 64 — Upstream Alignment 再評価:
- [ ] 64.1: UPSTREAM-DIFF 再評価 (F138/F99 修正後)
- [ ] 64.2: checklist.md / roadmap.md 最終更新

## Previous Task

v0.1.0 release complete. zwasm v0.1.0 dependency, docs overhaul, binary size audit,
benchmark recording (60.4 entry). All CI green.

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
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
