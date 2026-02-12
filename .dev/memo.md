# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 55 COMPLETE**
- Coverage: 835+ vars (635/706 core, 16 namespaces total)
- Wasm engine: zwasm v0.11.0 (GitHub URL dependency, build.zig.zon)
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 49 upstream test files, all passing. 6/6 e2e tests pass.
- Benchmarks: `bench/history.yaml` (zwasm-v0.11.0 entry = latest baseline)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 55: Upstream Test Recovery
- ~~55.1: Restore Java static field references in upstream tests~~ DONE
- ~~55.2: Restore Double/POSITIVE_INFINITY in reader.clj~~ DONE
- ~~55.3: N/A — upstream tests don't use parseInt/toBinaryString directly~~

## Current Task

Phase 55 complete. No active task. Awaiting direction.
Candidates for next phase:
- Bug fixes (pprint infinite seq hang)
- Implement read/read+string (PushbackReader, roadmap 49.1)
- Port additional upstream test files (limited options — most remaining are JVM-only)
- Begin v0.2.0-alpha concurrency work (future, pmap — requires GC thread safety)

## Previous Task

55.1: Restored Java static field references in parse.clj (Long/MAX_VALUE, Double/POSITIVE_INFINITY,
Double/isNaN), math.clj (Long/MAX_VALUE, Double/MIN_VALUE, Double/MAX_EXPONENT), numbers.clj
(Integer/MAX_VALUE, Integer/MIN_VALUE), printer.clj (print-symbol-values un-skipped).

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- pprint on infinite lazy seq hangs (realizeValue in singleLine/pprintImpl)
- binding *ns* doesn't affect read-string for auto-resolved keywords

## Resolved Issues (this session)

- **Checklist cleanup**: F136/F137 resolved (zwasm v0.11.0 implements table.copy
  cross-table + table.init). F6 resolved (multi-thread dynamic bindings done).
- **Regex fix**: Capture groups + backreferences actually work — removed from Known Issues.

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
