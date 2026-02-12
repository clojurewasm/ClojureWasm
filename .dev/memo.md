# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 55 COMPLETE**
- Coverage: 837+ vars (637/706 core, 16 namespaces total)
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

57.1: Zig test — multiple futures allocating concurrently (GC mutex contention).

## Task Queue

Phase 57: Concurrency Test Suite (see `.dev/concurrency-test-plan.md`)
- 57.1: Zig — multiple futures allocating concurrently
- 57.2: Zig — GC collection during future execution
- 57.3: Zig — agent actions with heavy allocation
- 57.4: Zig — deref-blocked thread survives GC
- 57.5: Clj — atom swap! N-thread contention
- 57.6: Clj — delay N-thread simultaneous deref
- 57.7: Clj — mass future spawn + collect all results
- 57.8: Clj — agent high-frequency send
- 57.9: Clj — future inherits bindings
- 57.10: Clj — nested binding + future
- 57.11: Clj — agent send inherits bindings
- 57.12: Clj — shutdown-agents then send
- 57.13: Clj — future-cancel
- 57.14: Clj — promise deref with timeout
- 57.15: Clj — agent restart-agent after error

## Previous Task

56.2: Implemented `read`, `read+string`, and `clojure.edn/read`. No PushbackReader type needed —
reads from `with-in-str` input source or stdin directly. Added Reader.position() for tracking
consumed bytes. Supports 0/1/3-arg arities with eof handling. `read+string` returns [form string].
Both backends verified. 637/706 core vars done.

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
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
| Concurrency tests  | `.dev/concurrency-test-plan.md`      | Phase 57 task details       |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
