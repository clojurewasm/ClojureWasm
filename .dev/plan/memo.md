# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete
- Decision gate: evaluate targets → Phase 25 or 24C
- Blockers: none

## Task Queue

Phase 24A — Speed Optimization:
1. ~~24A.0: Baseline measurement~~ (done)
2. ~~24A.1: VM dispatch optimization~~ (done)
3. ~~24A.2: Stack argument buffer~~ (done)
4. ~~24A.3: Fused reduce (lazy-seq chain collapse)~~ (done)
5. ~~24A.4: Arithmetic fast-path widening (@addWithOverflow)~~ (done)
6. ~~24A.5: Inline caching (protocol dispatch IC)~~ (done)
7. ~~24A.6: Hash table bitmask optimization~~ (N/A, Zig std already uses bitmask)
8. ~~24A.7: Constant folding~~ (skip, minimal benchmark impact)
9. ~~24A.8: Superinstructions~~ (skip, frame overhead dominates over dispatch)
10. ~~24A.9: @branchHint annotations (VM hot paths)~~ (done)
11. ~~24A.10: AOT bytecode bootstrap~~ (skip, blocked by F7, startup already 10ms)

Phase 24B — Memory Optimization:
12. ~~24B.1: NaN boxing~~ (deferred — too invasive, 600+ call-site changes, see D72)
13. ~~24B.2: HAMT (persistent hash array mapped trie)~~ (done)
14. ~~24B.3: RRB-Tree~~ (skip — vector_ops 179ms not dominant bottleneck)
15. ~~24B.4: GC tuning~~ (done)

Decision gate after 24B: targets met -> Phase 25. Not met -> evaluate 24C (JIT).

## Current Task

Decision gate: evaluate Phase 24 targets and plan next phase.

## Previous Task

24B.4: GC tuning — DONE
- Eliminated redundant allocated_* list tracking in VM when GC active (17 guards)
- Fixed GC traceValue: LazySeq.meta (lazy_filter/map/take/iterate) was not traced
- F97 resolved: root cause was stack overflow from deep lazy-seq realization chain
  (168 nested filters × ~381KB/frame in Debug build), not GC collection.
  Fix: build.zig stack_size 64MB → 512MB.
- GC threshold tuning experiments (4MB, adaptive) regressed — kept 1MB default
- gc_stress benchmark: within noise (~320ms), HashMap-based GC limits further gains

## Handover Notes

- **Phase 24 plan**: `.dev/plan/phase24-optimization.md` — actual baseline data added
- **F97**: RESOLVED — stack overflow in lazy-seq realization (512MB stack, meta tracing fix)
- **F98**: fib_recursive slower in ReleaseFast than Debug (487ms vs 205ms)
- **deftype/reify**: Permanent skip — no JVM class generation. defrecord covers data use cases.
- **Phase 25 prep**: Deep lazy-seq realization uses Zig call stack recursion.
  Wasm has limited stack → may need iterative realization engine in Phase 25.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
