# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 74 COMPLETE** (Java interop architecture)
- Coverage: 871+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 20 embedded CLJ namespaces)
- Wasm engine: zwasm v0.2.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 51 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v0.2.0 entry = latest baseline)
- Binary: 3.85MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
- Java interop: `src/interop/` module with URI, File, UUID classes (D101)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only. Libraries requiring heavy Java interop are out of scope.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (3.85MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).
When behavior differs from upstream Clojure, trace CW's processing pipeline to find
and fix the root cause. Add Java interop shims only when 3+ libraries need the same
pattern AND it's <100 lines of Zig. If a library requires heavy Java interop that
CW won't implement, that library is out of scope — document and move on.
See `.dev/library-port-targets.md` for targets and decision guide.

## Current Task

Phase 75.0f: clojure.java.process — process API via Zig std.process.
Detail: `.dev/missing-clj-namespaces.md`

## Task Queue

Batch 0: Missing clojure.jar namespaces (embed, CLJW markers OK).
Read `.dev/missing-clj-namespaces.md` for detailed analysis per namespace.

```
--- Batch 0: Small ---
--- Batch 0: Medium ---
75.0f clojure.java.process — process API via Zig std.process (196 lines, multi-task)
--- Batch 0: Large ---
75.0g clojure.main — CW-native main ns (676 lines, map existing CW features)
75.0h clojure.core.server — socket REPL + prepl (341 lines, after 0g)
75.0i clojure.repl.deps — CW-native REPL deps (97 lines, after deps.edn stable)
--- External Library Testing ---
75.A  Fix CW limitations (regex backtracking, catch empty body, split trailing empties, apply map vector)
75.B  Retry tools.cli as-is (should work after 75.A)
75.C  Test instaparse as-is (pure Clojure, ~3000 LOC)
75.D  Implement PushbackReader/StringWriter interop shims
75.E  Test data.json as-is (after 75.D)
75.F  Test data.csv as-is (after 75.D)
75.G  Test remaining pure Clojure libraries (meander, specter, core.match, etc.)
```

Policy:
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- When CW behavior differs from upstream, trace processing pipeline to fix root cause
- See `library-port-targets.md` for targets, `test/compat/RESULTS.md` for results

Notes:
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- CSK's split issue addressable in 75.A
- clojure.xml deferred until library testing surfaces demand

## Previous Task

Phase 75.0e: clojure.instant (complete):
- Created `src/clj/clojure/instant.clj` — RFC3339 parser, validator, construct-date
- Ported upstream parser/validator (parse-timestamp, validated, leap-year?, days-in-month)
- Date type: reified java.util.Date map with `:inst` key (like UUID pattern)
- `#inst` reader tag creates Date instance via `__inst-from-string` builtin
- `read-string` also creates Date instance (macro.zig formToValueWithNs)
- Fixed `format "%02d"` zero-padding bug in misc.zig
- Updated `default-data-readers` in core.clj to use proper constructors

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
| Missing clj ns     | `.dev/missing-clj-namespaces.md`     | Batch 0 — embed ns details  |
| BB class compat    | `.dev/babashka-class-compat.md`      | Java class reference (not roadmap) |
| spec.alpha upstream| `~/Documents/OSS/spec.alpha/`        | spec.alpha reference source |
| zwasm (archived)   | `.dev/wasm-opt-plan.md`              | Historical only             |
