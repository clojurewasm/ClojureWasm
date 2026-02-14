# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 74 COMPLETE** (Java interop architecture)
- Coverage: 871+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 18 namespaces total)
- Wasm engine: zwasm v0.2.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 51 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v0.2.0 entry = latest baseline)
- Binary: 3.85MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
- Java interop: `src/interop/` module with URI, File, UUID classes (D101)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only, fork/adapt libraries to remove unnecessary Java deps.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (3.85MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries, add shims only when
3+ libraries need the same pattern AND it's <100 lines of Zig. Otherwise fork the
library. See `.dev/library-port-targets.md` for targets and shim decision guide.

## Current Task

Phase 75.2: camel-snake-kebab — already tested (98.6% pass, 2 fails = split edge case).
Skip to 75.3 or address Batch 1 results.

## Task Queue

```
75.2 camel-snake-kebab — already tested (98.6%), 2 fails = clojure.string/split trailing empties
75.3 Additional Batch 1 libraries (medley, hiccup, honeysql already tested)
75.4 Batch 2 planning — pick next libraries based on Batch 1 results
```

## Previous Task

Phase 75.1: clojure.data.json — CW-compatible fork (complete).
- Created `src/clj/clojure/data/json.clj` — CW fork of upstream data.json
- Replaced definterface/deftype with defprotocol/reify + volatile!
- Replaced StringWriter/Appendable with vector-based string builder
- Pure Clojure hex parser (Integer/parseInt radix not supported)
- condp workaround for case macro hash collision bug (8+ keywords)
- Lazy-loaded via `loadEmbeddedLib` in bootstrap.zig
- Fixed `(int \a)` → 97 (char→int cast in arithmetic.zig)
- Fixed Unicode writer (seq codepoints, not .charAt UTF-8 bytes)
- Fixed UUID writer (check uuid? before map?)
- 51 tests, 80 assertions, 100% pass rate
- Both VM and TreeWalk verified
- Non-functional: binary 3.87MB, startup 5.3ms, RSS 7.75MB — all pass

## Known Issues

(none currently)

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions

## Reference Chain

Session resume: read this file → roadmap.md → pick next task.

| Topic              | Location                             | When to read                |
|--------------------|--------------------------------------|-----------------------------|
| Roadmap            | `.dev/roadmap.md`                    | Always — next phases        |
| Deferred items     | `.dev/checklist.md`                  | When planning next work     |
| Decisions          | `.dev/decisions.md` (D3-D101)        | On architectural questions  |
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
| Library targets    | `.dev/library-port-targets.md`       | Phase 75 — libraries to test|
| BB class compat    | `.dev/babashka-class-compat.md`      | Java class reference (not roadmap) |
| spec.alpha upstream| `~/Documents/OSS/spec.alpha/`        | spec.alpha reference source |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
