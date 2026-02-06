# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B active, task 24B.2 (HAMT)
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
14. 24B.3: RRB-Tree (conditional, if vector bottleneck)
15. 24B.4: GC tuning

Decision gate after 24B: targets met -> Phase 25. Not met -> evaluate 24C (JIT).

## Current Task

24B.3: RRB-Tree (conditional — evaluate if vector bottleneck exists)
- Check vector_ops benchmark (179ms) for optimization potential
- If vector operations dominate, implement RRB-Tree persistent vector
- Otherwise skip to 24B.4 (GC tuning)

## Previous Task

24B.2: HAMT (persistent hash array mapped trie) — DONE
- Added PersistentHashMap with HAMT internals to collections.zig
- Added hash_map Value variant, updated 13 files for full dispatch
- ArrayMap promotes to HashMap above 8 entries
- map_ops: 26ms → 13.7ms (1.9x), keyword_lookup: 24ms → 19.7ms (18%)
- fib_recursive: 28ms → 23ms (no regression, slight improvement)

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
