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

Phase 72 complete. See GC Assessment below.

### GC Assessment Report (Phase 72.3)

**Root causes found and fixed (D100):**
1. valueToForm string duplication — Forms referenced GC-allocated string data
2. ProtocolFn/MultiFn inline cache not traced — cached dispatch results swept
3. refer() string lifetime — GC-allocated Symbol.name stored in non-GC HashMap
4. Protocol dispatch GC pressure — 3 HeapString allocs per cache miss
5. Macro expansion GC sweep — lazy-seq closure-captured Values swept during callFnVal
6. Additional: char toString, fn name with-meta pattern

**Performance impact:**
- protocol_dispatch: 38ms → 5ms (7.6x) via getByStringKey zero-alloc lookup
- honeysql loading: crash → success (all 3 namespaces, both backends)
- CSK nested loops: crash at 60 → passes 200+ iterations

**GC architecture assessment:**
- Mark-and-sweep GC is functionally correct after fixes
- suppress_count during macro expansion is a safe workaround but masks
  a deeper tracing gap (lazy-seq thunk closure captured Values)
- Free pool recycling can mask use-after-free as data corruption
- No generational GC needed for current workloads
- Next priority: investigate the lazy-seq closure tracing gap (why
  Values captured by thunk closures aren't always reachable during GC)

**Recommendation:** Generational GC (Phase 73) is NOT needed now.
Current GC with fixes handles honeysql (1500 lines), protocol dispatch
at scale, and all upstream tests. Investigate closure tracing gap as a
correctness fix rather than architecture change.

## Task Queue

```
Phase 73: deferred (GC is adequate, see assessment)
Next: User direction needed — see roadmap.md for candidates
```

## Previous Task

Phase 72: Optimization + GC Assessment (complete).
- 72.1: 6 GC crash root causes fixed (D100)
- 72.2: getByStringKey optimization (protocol_dispatch 7.6x improvement)
- 72.3: GC assessment report (see above)

## Known Issues

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
