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

Phase 50: v0.4.0-beta — Ecosystem

- [x] 50.1: `cljw test` command (project-based test runner)
- [x] 50.2: cljw.edn `:deps` with local paths
- [x] 50.3: cljw.edn `:deps` with git/sha resolution
- [ ] 50.4: Homebrew tap
- [ ] 50.5: Wasm module dependency declaration

## Current Task

50.4: Homebrew tap.

## Previous Task

50.3: cljw.edn `:deps` with git/sha resolution — complete.
- Parse `:deps {lib/name {:git/url "..." :git/sha "..."}}` in cljw.edn
- Cache: `~/.cljw/gitlibs/_repos/<hash>.git` (bare clone) + `~/.cljw/gitlibs/<hash>/<sha>/` (extracted)
- Marker file `.cljw-resolved` for fast skip on re-run
- Pipes `git archive | tar -x` for extraction
- Fetching progress message on stderr
- Transitive deps resolved via dep's cljw.edn
- Updated vars.yaml: reify/reify*/set!/instance? → done, coverage 620/706
- Updated stale markers in walk.clj, defn, class?, eduction, definline, iteration
- F94 checklist updated with audit results
- clojure.walk (built-in): all functions verified
- clojure.set (built-in): 10 tests, 24 assertions — ALL PASS
- clojure.data (built-in): 6 tests, 21 assertions — ALL PASS
- clojure.zip (built-in): 8 tests, 16 assertions — ALL PASS
- clojure.pprint (built-in): basic pprint works, cl-format not impl

Fixes in this session:
1. seq? now returns true for cons/lazy-seq/chunked-cons (was list-only)
2. Smart type hint stripping: only strip (with-meta x {:tag T}), preserve other metadata

## Known Issues

- apropos segfaults (GC bug in namespace iteration)
- dir-fn on non-existent ns causes VM panic (error code gap)
- find-var returns symbol instead of var
- remove-ns, ns-unalias, ns-unmap not yet implemented
- *print-meta*, *print-readably* not yet respected by pr-str
- apply on var refs not supported
- apply on infinite lazy seq realizes eagerly (should pass trailing ISeq lazily)
- sequences.clj CLJ-1633 segfault (nested apply with & rest args → GC/binding corruption)

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
