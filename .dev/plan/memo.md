# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All major phases complete: A, BE, B, C (C1-C20), CX (CX1-CX10), R, D (D1-D16)
- Coverage: 521/704 clojure.core vars done (0 todo, 182 skip)
- Phase 22 complete. Next: Phase 23 (Production GC)
- Blockers: none

## Phase Roadmap (user-specified order)

| Phase | Name                     | Status  | Key Goal                              |
| ----- | ------------------------ | ------- | ------------------------------------- |
| 20    | Infrastructure Expansion | done    | transient, chunked, sorted (~18 vars) |
| 21    | Upstream Alignment       | done    | Replace UPSTREAM-DIFF with upstream   |
| 22    | Test Porting Expansion   | done    | multimethods, protocols, transducers  |
| 23    | Production GC            | active  | Replace arena allocator               |
| 24    | Optimization             | pending | NaN boxing, fused reduce, HAMT        |
| 25    | Wasm InterOp (FFI)      | pending | wasm/load, wasm/fn, WIT              |

## Task Queue

1. 23.5: Integration — replace arena in main.zig, remove VM/TW manual tracking
2. 23.6: Verification — all tests pass, REPL memory bounded

## Current Task

23.5: Integration — replace arena in main.zig, remove VM/TW manual tracking
- Replace ArenaGc with MarkSweepGc in main.zig
- Wire gc pointer into VM and TreeWalk via .gc field
- Remove manual allocated_* tracking from VM/TW (GC handles lifetime)
- Update deinit to not double-free GC-tracked allocations
- Both backends must still pass all tests

## Previous Task

23.4: Safe points — allocation threshold trigger in VM + TreeWalk
- Added collectIfNeeded(roots) to MarkSweepGc — trace + sweep + adaptive threshold
- Updated gcCollect vtable to also trace roots before sweep
- VM: gc field, maybeTriggerGc() builds RootSet from stack[0..sp] + frame constants + env
- TreeWalk: gc field, maybeTriggerGc() builds RootSet from locals + recur_args + exception + env
- VM safe point: after each stepInstruction() in execute() loop
- TreeWalk safe point: at the top of run() before each node evaluation
- 3 unit tests: collectIfNeeded trigger/no-op/threshold-growth

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
