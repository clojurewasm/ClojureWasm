# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 52 COMPLETE** + zwasm integration (D92) done
- Coverage: 835+ vars (635/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.1.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 48 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (post-zwasm entry = latest baseline)

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
- [ ] 53.5: Fix colon in symbol/keyword literals
- [ ] 53.6: Port pprint tests (content-equivalent, CW-adapted)
- [ ] 53.7: Full regression + update docs

## Current Task

53.5: Fix colon in symbol/keyword literals

## Previous Task

Phase 52: Quality & Alignment (complete)
- See Phase 52 commit history for details

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- Colon in symbol/keyword literals parsed as keyword delimiter
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
