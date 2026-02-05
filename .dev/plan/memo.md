# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All major phases complete: A, BE, B, C (C1-C20), CX (CX1-CX10), R, D (D1-D16)
- Coverage: 521/704 clojure.core vars done (0 todo, 182 skip)
- Phase 22 complete. Next: Phase 23 (Production GC)
- Blockers: none

## Phase Roadmap (user-specified order)

| Phase | Name                     | Status  | Key Goal                                       |
| ----- | ------------------------ | ------- | ---------------------------------------------- |
| 20    | Infrastructure Expansion | done    | transient, chunked, sorted (~18 vars)          |
| 21    | Upstream Alignment       | done    | Replace UPSTREAM-DIFF with upstream             |
| 22    | Test Porting Expansion   | done    | multimethods, transducers, transients, vectors  |
| 23    | Production GC            | done    | Replace arena allocator                         |
| 22b   | Test Porting Round 2     | pending | keywords, printer, protocols, math (~68 tests)  |
| 24    | Optimization             | pending | NaN boxing, fused reduce, HAMT                  |
| 25    | Wasm InterOp (FFI)      | pending | wasm/load, wasm/fn, WIT                        |

## Task Queue

Tier 2 — Port + implement (new namespace or feature):
1. 22b.10: Port math.clj (326 lines, 41 tests — needs clojure.math ns)
2. 22b.11: Port data.clj (32 lines, 1 test — needs clojure.data/diff)

Deferred/skipped:
- 22b.4 (test.clj) deferred — needs test-ns-hook/custom report/test-all-vars
- 22b.5 (test_fixtures.clj) deferred — needs use-fixtures (not implemented)
- 22b.6 (try_catch.clj) skipped — entirely JVM-specific (ReflectorTryCatchFixture)
- 22b.8 (protocols.clj) deferred — defprotocol/defrecord VM-only, most tests JVM interop

## Current Task

22b.10: Port math.clj (326 lines, 41 tests — needs clojure.math ns)
- Read upstream test/clojure/test_clojure/math.clj
- Implement clojure.math namespace
- Port tests with CLJW markers
- Both backends must pass

## Previous Task

22b.9: Port parse.clj (102 lines, 6 tests — needs parse-long/parse-double)
- Fixed parse-long/parse-double/parse-boolean: non-string args now throw TypeError
- Fixed parse-boolean: invalid strings return nil (not throw)
- 3 tests ported (46 assertions), 3 tests skipped (test.check generative, parse-uuid)
- Both backends pass
- Three-allocator architecture (D70): GPA + node_arena + GC confirmed stable

## Completed Phases (reverse chronological)

Phase D (parallel expansion) — D1-D16, all complete.
- D1: JVM-skip batch (124 vars)
- D2: Dynamic vars (27 vars)
- D3: Exception & var system
- D4: Atom watchers & validators
- D5: Hashing (Murmur3)
- D6: refer-clojure + ns enhancements
- D10: Unchecked math
- D11: IO macros (with-out-str)
- D12: Binding & redefs
- D13: munge, namespace-munge
- D14: load-string builtin
- D15: Easy wins sweep (10 vars + ~50 skip)
- D16: random-uuid

Phase R (require/load/ns) — R1-R7, all complete.
- File-based namespace loading, require/use with :as/:refer/:reload
- ns macro, multi-file project support

Phase C (upstream test porting) — C1-C20, all complete.
- 20 upstream test files ported with CLJW markers
- Both VM + TreeWalk verified

Phase CX (known issue resolution) — CX1-CX10, all complete.
- F51, F24, F68, F70-74, F80-83, F86-87, F89, F91, F94 resolved

Phase B (fix known issues) — B0-B4, all complete.
Phase BE (error system overhaul) — BE1-BE6, all complete.
Phase A (audit & document) — all 399 done vars annotated.

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- Phase CX plan: `.dev/plan/phase-cx-plan.md`
- Roadmap: `.dev/plan/roadmap.md`
- **Phase order (user decision)**: 20(infra) → 21(upstream align) → 22(tests) → 23(GC) → 22b(tests2) → 24(optimize) → 25(wasm)
  - 22b inserted between GC and Optimization (GC完了後にテスト追加、Optimization前の安全網)
  - 22b Tier 1: keywords, printer, errors, protocols, try_catch, test, test_fixtures, fn
  - 22b Tier 2: math(+clojure.math), parse, data(+clojure.data), ns_libs, repl
  - See roadmap.md Phase 22b for full file list and portability assessment
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Zig tips: `.claude/references/zig-tips.md`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- Beta delay reference: `ClojureWasmBeta/src/lib/core/concurrency.zig`, `ClojureWasmBeta/src/base/value.zig`
- Beta hierarchy reference: `ClojureWasmBeta/src/lib/core/interop.zig`
