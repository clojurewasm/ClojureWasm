# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 46 COMPLETE** + zwasm integration (D92) done
- Coverage: 795+ vars (593/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.1.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 43 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (post-zwasm entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 48: v0.2.0-alpha — Concurrency

- [x] 48.0: Plan Phase 48 (audit + architectural decisions)
- [x] 48.1: Thread-safe global state (threadlocal/atomic conversions)
- [x] 48.2: GC thread safety (D94 — mutex + stop-the-world)
- [x] 48.3: Thread pool infrastructure + per-thread evaluator
- [x] 48.4: Future Value type + future/future-call/deref
- [ ] 48.5: pmap, pcalls, pvalues
- [ ] 48.6: promise + deliver

## Current Task

48.5: pmap, pcalls, pvalues

Plan:
- Implement pmap (parallel map using futures + thread pool)
- Implement pcalls (parallel function calls)
- Implement pvalues (parallel value computation)
- All are bootstrap Clojure, implemented on top of future-call

## Previous Task

48.4: Future Value type + future/future-call/deref.
- FutureObj: extern struct sharing delay NanHeapTag slot 18, DeferredKind discriminator
- NO_VALUE sentinel (0xDEAD) for extern struct fields (replaces ?Value)
- future-call, future?, future-done?, future-cancel, future-cancelled? builtins
- future macro in bootstrap clj
- deref supports 1-arity (blocking) and 3-arity (timeout) for futures
- Thread pool shutdown wired into lifecycle.runShutdownHooks

## Known Issues

- apropos segfaults (GC bug in namespace iteration)
- dir-fn on non-existent ns causes VM panic (error code gap)
- find-var returns symbol instead of var
- remove-ns, ns-unalias, ns-unmap not yet implemented
- *print-meta*, *print-readably* not yet respected by pr-str
- apply on var refs not supported

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
