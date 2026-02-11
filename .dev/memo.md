# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 48 COMPLETE** + zwasm integration (D92) done
- Coverage: 810+ vars (604/706 core, 16 namespaces total)
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

Phase 49: v0.3.0-alpha — Compatibility

- [x] 49.1: Thread/sleep + shutdown-agents + analyzer rewrite
- [x] 49.2: Upstream test expansion (concurrency tests)
- [x] 49.3: Quick-win skip recovery pass
- [ ] 49.4: Pure Clojure library compatibility testing
- [ ] 49.5: Upstream alignment pass (UPSTREAM-DIFF cleanup)

## Current Task

49.4 (continued): Test more libraries (honeysql v2 next).
- medley: 31 tests, 48 assertions — ALL PASS
- camel-snake-kebab: 7 tests, 14 assertions — ALL PASS
- Next: honeysql v2, editscript, or core.match

## Previous Task

49.4: Library compat fixes — medley + CSK passing.
Implemented 11 compatibility features:
1. Type hints on fn params (^Type param unwrap)
2. instance? as compiler special form with Java class mapping
3. in-ns with-meta unwrap (^:no-doc ns)
4. .cljc file loading support
5. Octal character literals (\oNNN)
6. set! for dynamic vars at top level
7. .method Java instance method calls (→ __java-method builtin)
8. Static method rewrites: String/, Pattern/, Integer/, Double/, Character/, Boolean/
9. reify special form (protocol impl on anonymous objects)
10. :import registers class short names as symbol vars
11. with-meta type hint stripping in analyzer
Also: common java.lang class defs, __regex-quote, Character type key

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
