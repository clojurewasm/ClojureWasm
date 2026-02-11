# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 48 COMPLETE** + zwasm integration (D92) done
- Coverage: 820+ vars (620/706 core, 16 namespaces total)
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

Phase 50B: Known Bug Fixes

- [x] 50B.1: Fix apropos segfault (already fixed — verified working)
- [x] 50B.2: Fix dir-fn on non-existent ns (VM panic → error)
- [x] 50B.3: Fix find-var return type (symbol → var)
- [x] 50B.4: Implement remove-ns, ns-unalias, ns-unmap
- [x] 50B.5: Fix *print-meta*, *print-readably* in pr-str
- [x] 50B.6: Fix apply on var refs
- [~] 50B.7: Defer apply on infinite lazy seq (no tests need it, architecturally complex)
- [x] 50B.8: Fix sequences.clj segfault (GC swept binding frames)

## Current Task

Phase 50B complete. Plan next phase.

## Previous Task

50B.8: Fix sequences.clj segfault — complete.
- Root cause: GC swept BindingFrame structs and entries arrays while still on binding stack
- Fix: `traceBindingStack` now calls `markPtr(frame)` and `markSlice(entries)` to keep them live
- sequences.clj: 58 tests, 593 assertions — ALL PASS (was segfaulting)

## Known Issues

- with-meta result GC'd when used inline (e.g. `(meta (with-meta v m))` → nil)
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
