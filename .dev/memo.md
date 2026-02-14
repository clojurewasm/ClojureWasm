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

Phase 72.1 complete. Sub-task 72.2 next.

GC crash root cause analysis and 6 fixes applied:
1. valueToForm string duplication (macro.zig) — Forms now own all string data
2. ProtocolFn cache GC tracing (gc.zig) — cached_type_key + cached_method traced
3. MultiFn cache GC tracing (gc.zig) — cached_dispatch_val + cached_method traced
4. refer() string safety (ns_ops.zig) — use GPA-owned Var.sym.name, not GC Symbol.name
5. Protocol dispatch zero-alloc lookup (collections.zig + 4 files) — getByStringKey
6. GC suppression during macro expansion (gc.zig + analyzer.zig) — prevents
   sweep of lazy-seq closure-captured Values during syntax-quote expansion

Results: honeysql segfault → real error ("No matching method toString found for char").
CSK nested loop crash (>60 iters) → passes 200 iterations cleanly.

## Task Queue

```
Phase 72: Optimization + GC Assessment
  72.2: Targeted optimizations
  72.3: GC assessment report

Phase 73: Generational GC (conditional on Phase 72 findings)
  73.1-73.4: Design → write barriers → nursery → integration
```

## Previous Task

Phase 72.1: GC crash root cause investigation and fixes (complete).
6 correctness fixes across 9 files. All segfaults resolved.

## Known Issues

- honeysql sql.cljc: "No matching method toString found for char" — char needs
  Object protocol toString method implementation.
- clojure.string/split doesn't drop trailing empty strings (Java Pattern.split does).

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
