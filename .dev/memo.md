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

Phase 52: Quality & Alignment — IN PROGRESS

- [x] 52.1: Fix println/print hang on infinite lazy seqs
- [x] 52.2: Expand io_test.clj (revive skipped tests)
- [x] 52.3: Port test.clj (portable sections)
- [x] 52.4: Fix bugs found by test.clj (exception type checking, is macro try-expr)
- [x] 52.5: Port reader.cljc (portable sections)
- [x] 52.6: Fix reader bugs — N/A (pre-existing limitations only)
- [ ] 52.7: F94: Align distinct? to upstream style
- [ ] 52.8: F94: Audit and document remaining UPSTREAM-DIFFs
- [ ] 52.9: Implement io!, with-precision macros
- [ ] 52.10: Full upstream regression on both backends
- [ ] 52.11: Phase completion: update docs

## Current Task

52.7: F94: Align distinct? to upstream style
- Current: avoids [x & etc :as xs], uses (first xs)/(next xs) manually
- Upstream: (loop [s #{x y} [z & etc :as xs] more] ...)
- Verify CW destructuring supports this pattern, then align

## Previous Task

52.3-52.4: Port test.clj + exception type checking
- Ported test.clj: 10 tests, 41 assertions (portable sections)
- Implemented exception type checking in catch clauses (was ignored since Phase 1c)
  - analyzer: CatchClause.class_name, multi-catch → nested try
  - predicates: exceptionMatchesClass() with Java-like hierarchy
  - compiler: exception_type_check opcode (0xA5)
  - VM + TreeWalk: type check before catch body execution
- Fixed `is` macro: added try-expr pattern (outer catch Exception for unexpected errors)
- Added test-ns-hook support to run-tests
- 45 upstream test files, all passing

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
