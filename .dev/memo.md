# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 52 COMPLETE** + Phase 53 in progress
- Coverage: 835+ vars (635/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.7.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 49 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/wasm_history.yaml` (zwasm-0.7.0 entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 53: Hardening & pprint Tests — IN PROGRESS

- [x] 53.1: Update zwasm to v0.7.0
- [x] 53.2: Fix loop destructuring recur bug
- [x] 53.3: Align distinct? to upstream (enabled by 53.2)
- [x] 53.4: Fix BigDecimal exponent notation (1.0e+1M)
- [x] 53.5: Fix colon in symbol/keyword literals
- [x] 53.6: Port pprint tests (content-equivalent, CW-adapted)
- [ ] 53.7: Full regression + update docs

## Current Task

53.7: Full regression + update docs

## Previous Task

53.6: Port pprint tests — 12 tests, 78 assertions
- Content-equivalent approach: test names from upstream, CW-adapted content
- Tests: pprint-test, pprint-reader-macro-test, print-length-tests,
  print-level-tests, pprint-datastructures-tests, pprint-wrapping-test,
  pprint-empty-collections-test, pprint-strings-test, pprint-nested-test,
  print-table-test, pprint-special-values-test, pprint-print-length-and-level-combined
- Both VM + TreeWalk passing

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- pprint on infinite lazy seq hangs (realizeValue in singleLine/pprintImpl)
- binding *ns* doesn't affect read-string for auto-resolved keywords
- Regex capture groups/backreferences not supported

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
