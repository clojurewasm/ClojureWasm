# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All major phases complete: A, BE, B, C (C1-C20), CX (CX1-CX10), R, D (D1-D16)
- Coverage: 510/704 clojure.core vars done (0 todo, 193 skip)
- Next: Phase 20 (Infrastructure Expansion — transient, chunked, sorted)
- Blockers: none

## Phase Roadmap (user-specified order)

| Phase | Name                     | Status  | Key Goal                              |
| ----- | ------------------------ | ------- | ------------------------------------- |
| 20    | Infrastructure Expansion | active  | transient, chunked, sorted (~18 vars) |
| 21    | Upstream Alignment       | pending | Replace 13 UPSTREAM-DIFF with upstream|
| 22    | Test Porting Expansion   | pending | multimethods, protocols, transducers  |
| 23    | Production GC            | pending | Replace arena allocator               |
| 24    | Optimization             | pending | NaN boxing, fused reduce, HAMT        |
| 25    | Wasm InterOp (FFI)      | pending | wasm/load, wasm/fn, WIT              |

## Task Queue

1. ~~20.1: Transient collections~~ — DONE
2. ~~20.2: Core.clj transient alignment~~ — DONE
3. 20.3: Chunked sequences — types + builtins (chunk-buffer, chunk-append, chunk, chunk-first, chunk-next, chunk-rest, chunked-seq?) — 7 vars
4. 20.4: Core.clj chunked seq paths (map, filter, doseq → chunked optimization)
5. 20.5: Sorted-map-by, sorted-set-by with custom comparators — 2 vars
6. 20.6: subseq, rsubseq — 2 vars

## Current Task

20.3: Chunked sequences — types + builtins

Design:
- Add ArrayChunk (immutable chunk), ChunkBuffer (mutable builder), ChunkedCons (chunk + rest)
- Builtins: chunk-buffer, chunk-append, chunk, chunk-first, chunk-next, chunk-rest, chunked-seq?
- ChunkBuffer: mutable array builder, finalized via (chunk buf) → ArrayChunk
- ChunkedCons: first-chunk (ArrayChunk) + rest-seq (Value) — the chunked lazy-seq
- chunked-seq? returns true for ChunkedCons

## Previous Task

20.2 completed: Core.clj transient alignment
- update-vals, update-keys → transient/persistent! (removed UPSTREAM-DIFF)
- mapv → transient/persistent! (1-arity)
- clojure.set/map-invert → transient/persistent!
- Both VM + TreeWalk verified

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
