# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B active, task 24B.1
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
12. 24B.1: NaN boxing (48 bytes -> 8 bytes)
13. 24B.2: HAMT (persistent hash array mapped trie)
14. 24B.3: RRB-Tree (conditional, if vector bottleneck)
15. 24B.4: GC tuning (post NaN-boxing)

Decision gate after 24B: targets met -> Phase 25. Not met -> evaluate 24C (JIT).

## Current Task

24B.1: NaN boxing (Value: 48 bytes -> 8 bytes)
- Transform Value tagged union from 48 bytes to 8 bytes using IEEE 754 NaN boxing
- Reference: `ClojureWasmBeta/src/base/value.zig` (NaN boxing implementation)
- Biggest architectural change in Phase 24 — affects all code that touches Value
- Expected: Major improvement on collection/GC benchmarks (smaller cache footprint)

## Previous Task

24A.9: @branchHint annotations (VM hot paths)
- Added @branchHint(.unlikely) to 5 locations in vm.zig
- Results: 28-40% improvement on tight-loop benchmarks (fib 41→28ms, tak 36→23ms)
- Phase 24A summary: fib 542→28ms (19.4x), lazy_chain 21.4→6.6s (3.2x)
- 24A.10 skipped (blocked by F7, startup already 10ms)

## Handover Notes

- **Phase 24 plan**: `.dev/plan/phase24-optimization.md` — actual baseline data added
- **F97**: GC double-free in sieve benchmark (vm.zig:336 allocated_fns)
- **F98**: fib_recursive slower in ReleaseFast than Debug (487ms vs 205ms)
- **deftype/reify**: Permanent skip — no JVM class generation. defrecord covers data use cases.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
