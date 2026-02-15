# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 74 COMPLETE** (Java interop architecture)
- Coverage: 871+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 25 embedded CLJ namespaces)
- Wasm engine: zwasm v0.2.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v0.2.0 entry = latest baseline)
- Binary: 3.92MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
- Java interop: `src/interop/` module with URI, File, UUID, PushbackReader, StringBuilder, StringWriter classes (D101)

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

Upstream test audit + multimethod cache fix — DONE.
- Fixed multimethod L1 cache bug: was hashing only first arg, caused
  thrown-with-msg?/thrown? in clojure.test to break after other assertions
- Ported 3 new upstream test files (clojure_xml, main, server)
- Added gap documentation to reader.clj, protocols.clj
- Audit of all 52 test files complete: almost all gaps are JVM-ONLY
- Portable gaps: read-string 2-arity, namespaced maps, :as-alias (features to implement)

Ready for next phase planning.

## Task Queue

```
--- External Library Testing (Phase 75) ---
75.B  DONE — tools.cli loads, 2/6 pass, 3 partial, 1 GC crash (F140)
75.C  DONE — instaparse 9/16 modules load, blocked by deftype (out of scope)
75.D  DONE — PushbackReader, StringReader, StringBuilder, StringWriter, EOFException interop
75.E  DONE — data.json blocked by definterface/deftype (out of scope for now)
75.F  DONE — data.csv fully working (read-csv, write-csv, custom sep, quoted fields)
75.G  DONE — meander 6/18 modules load (blocked by &form, case*), core.match out of scope
```

Policy:
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- When CW behavior differs from upstream, trace processing pipeline to fix root cause
- See `library-port-targets.md` for targets, `test/compat/RESULTS.md` for results

Notes:
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)

## Previous Task

Upstream test audit + multimethod cache fix:
- Root cause: MultiFn L1 cache hashed only first arg → stale cache hit
  when dispatch depended on 2nd+ arg (assert-expr dispatches on form, not msg)
- Fix: combinedArgKey() hashes ALL args with index mixing
- 3 new test files ported, 2 files updated with comprehensive gap docs
- All 52 upstream test files pass on both backends

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
