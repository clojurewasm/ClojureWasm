# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 53 COMPLETE**
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

Ready for next phase direction.

## Current Task

None — Phase 53 complete.

## Previous Task

Phase 53: Hardening & pprint Tests (complete)
- 53.1: Updated zwasm to v0.7.0
- 53.2: Fixed loop destructuring recur bug
- 53.3: Aligned distinct? to upstream
- 53.4: Fixed BigDecimal exponent notation
- 53.5: Fixed colon in symbol/keyword literals
- 53.6: Ported pprint tests (12 tests, 78 assertions, content-equivalent)
- 53.7: Full regression — 49/49 VM, 49/49 TW, 6/6 e2e
- 53.8: Fix macroexpand list? (when macro upstream alignment)
- 53.9: Fix array negative size exception type (value_error)

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- pprint on infinite lazy seq hangs (realizeValue in singleLine/pprintImpl)
- binding *ns* doesn't affect read-string for auto-resolved keywords
- Regex capture groups/backreferences not supported

## Resolved Issues (this session)

- **Wasm call segfault**: GC was sweeping zwasm internals (~1MB VM) because
  GC only marked the CW WasmModule wrapper, not zwasm's child allocations.
  Fix: use `std.heap.smp_allocator` for all zwasm allocations (bce1c2e).
  Also copy wasm binary bytes to non-GC memory since zwasm Module stores a reference.

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
