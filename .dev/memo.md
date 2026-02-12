# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 57 COMPLETE**, Phase 58 in progress
- Coverage: 869+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 18 namespaces total)
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

58.6: Port reducers.clj upstream test.

## Task Queue

Phase 58: clojure.core.reducers (see below)
- ~~58.1: Create `clojure.core.protocols` namespace (CollReduce, IKVReduce)~~ DONE
- ~~58.2: Implement reducers core (reduce, fold, CollFold, monoid)~~ DONE
- ~~58.3: Implement reducer/folder wrappers (reify-based)~~ DONE
- ~~58.4: Implement transformation fns (map, filter, remove, take, take-while, drop, flatten, mapcat)~~ DONE
- ~~58.5: Implement Cat type (defrecord) + cat/append!/foldcat~~ DONE
- 58.6: Port reducers.clj upstream test

## Previous Task

58.2-58.5: Implemented full clojure.core.reducers namespace (22 vars). Key changes:
- defrecord now adds `:__reify_type` for protocol dispatch on record types
- Namespace-qualified protocol names in extend-type/reify (protocol_ns field added to node)
- core/reduce redefined in protocols.clj to dispatch through CollReduce for reify objects
- Object CollReduce extension uses __zig-reduce directly (avoids circular reduce→coll-reduce→reduce)
- Multi-arity reify methods use nested arity form (single method, multiple arities)

## Known Issues

- apply on infinite lazy seq realizes eagerly (deferred — no tests need it)
- binding *ns* doesn't affect read-string for auto-resolved keywords

## Resolved Issues (this session)

- **swap! race condition**: swap!/swap-vals! had no CAS retry loop. Fixed with lock-free
  `@cmpxchgStrong` CAS. Also made reset!/reset-vals!/deref atomic.
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
