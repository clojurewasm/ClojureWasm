# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 64 COMPLETE**
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

Phase 65.4: Implement source-fn (:file metadata on vars).

## Task Queue

Phase 61 — Bug Fixes:
- [x] 61.1: F138 binding *ns* + read-string
- [x] 61.2: record hash edge case (already works — stale CLJW marker removed)

Phase 62 — Edge Cases:
- [x] 62.1: F99 Iterative lazy-seq realization engine (D96)

Phase 63 — import → wasm mapping:
- [x] 63.1: F135 :import-wasm ns macro

Phase 64 — Upstream Alignment 再評価:
- [x] 64.1: UPSTREAM-DIFF 再評価 (416 markers — all permanent)
- [x] 64.2: checklist.md / roadmap.md 最終更新

Phase 65 — Edge Case Cleanup (pre-deps.edn):
- [x] 65.1: Restore apropos + dir-fn tests (already working)
- [x] 65.2: Reader duplicate key detection
- [x] 65.3: Fix (fn "a" []) analyzer
- [ ] 65.4: Implement source-fn (:file metadata)
- [ ] 65.5: Implement *print-dup* (basic)

## Previous Task

Phase 61-64: Bug fixes (F138 binding *ns* + read-string, record hash), edge cases
(F99 iterative lazy-seq D96), :import-wasm ns macro (F135), upstream alignment review
(416 CLJW + 36 UPSTREAM-DIFF — all permanent design diffs).

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
