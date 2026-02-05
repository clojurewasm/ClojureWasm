# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All major phases complete: A, BE, B, C (C1-C20), CX (CX1-CX10), R, D (D1-D16)
- Coverage: 521/704 clojure.core vars done (0 todo, 182 skip)
- Next task: 22.8 (Port protocols.clj)
- Blockers: none

## Phase Roadmap (user-specified order)

| Phase | Name                     | Status  | Key Goal                              |
| ----- | ------------------------ | ------- | ------------------------------------- |
| 20    | Infrastructure Expansion | done    | transient, chunked, sorted (~18 vars) |
| 21    | Upstream Alignment       | done    | Replace UPSTREAM-DIFF with upstream   |
| 22    | Test Porting Expansion   | active  | multimethods, protocols, transducers  |
| 23    | Production GC            | pending | Replace arena allocator               |
| 24    | Optimization             | pending | NaN boxing, fused reduce, HAMT        |
| 25    | Wasm InterOp (FFI)      | pending | wasm/load, wasm/fn, WIT              |

## Task Queue

1. ~~22.1: Port transients.clj (82 lines)~~ — DONE (4 tests, 29 assertions)
2. ~~22.2: keywords.clj — SKIP (find-keyword F80 + regex needed)~~
3. ~~22.3: fn.clj — SKIP (fails-with-cause? + clojure.spec)~~
4. ~~22.4: try_catch.clj — SKIP (100% JVM: Java exception classes + test fixtures)~~
5. ~~22.5: Port multimethods.clj (271 lines)~~ — DONE (9 tests, 102 assertions)
6. ~~22.6: Port transducers.clj (410 lines)~~ — DONE (14 tests, 90 assertions)
7. ~~22.7: Port vectors.clj (491 lines)~~ — DONE (9 tests, 68 assertions)
8. 22.8: Port protocols.clj (721 lines) — roadmap target
9. 22.9: Port math.clj (326 lines) — math functions

## Current Task

22.8: Port protocols.clj (721 lines)

## Previous Task

22.7: Port vectors.clj — 9 tests, 68 assertions, 16 CLJW markers
- Added vector comparison to compareValues (element-by-element)
- Added .map and .string handling to collectSeqItems
- Added multi-collection arities to map (3, 4, variadic)
- Added multi-collection arities to mapv (2, 3, variadic)
- Fixed reduce-kv to support vectors (index-based iteration)

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
- **Phase order (user decision)**: A(infra) → B(upstream align) → F(tests) → C(GC) → D(optimize) → E(wasm)
  - Mapped to Phase 20 → 21 → 22 → 23 → 24 → 25 in roadmap.md
  - Rationale: transient/chunked enables more upstream code, tests benefit from wider coverage,
    GC needed for production use, optimization after GC, wasm last as differentiation
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Zig tips: `.claude/references/zig-tips.md`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- Beta delay reference: `ClojureWasmBeta/src/lib/core/concurrency.zig`, `ClojureWasmBeta/src/base/value.zig`
- Beta hierarchy reference: `ClojureWasmBeta/src/lib/core/interop.zig`
