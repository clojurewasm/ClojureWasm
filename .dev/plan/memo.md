# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1 done)
- Babashka comparison: CW wins ~11/20 (lazy_chain fixed: 6655ms→17ms)
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. 24C.2: Multimethod dispatch optimization (95x gap)
3. 24C.3: String ops optimization (15x gap)
4. 24C.4: Collection ops optimization (vector_ops 8.5x, list_build 8.3x)
5. 24C.5: GC optimization (gc_stress 7.8x, nested_update 6.4x)
6. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks)
7. 24C.7: F99 iterative lazy-seq realization (wasm prerequisite)
8. 24C.8: Constant folding

## Current Task

24C.2: Multimethod dispatch optimization (95x gap — 2053ms vs BB 22ms).
Multimethod lookup currently goes through full hierarchy search per call.
Profile and optimize the dispatch path.

## Previous Task

24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map.
- Root cause: `map` was redefined at line 1736 in core.clj (for multi-collection arities)
  but the 2-arity was changed from `(__zig-lazy-map f coll)` to standard lazy-seq,
  causing fused reduce to NEVER trigger
- Fix: restored `(__zig-lazy-map f coll)` for 2-arity in redefined map
- Results: lazy_chain 6655ms→17ms (391x), map_filter_reduce 1293ms→179ms (7.2x)

## Handover Notes

- **Phase 24C plan**: `.dev/plan/phase24-optimization.md` — Babashka parity targets
- **Optimization knowledge**: `.claude/references/optimization-knowledge.md`
- **Benchmark history**: `bench/history.yaml` — record after every optimization task
- **F97**: RESOLVED — stack overflow in lazy-seq realization (512MB stack, meta tracing fix)
- **F98**: fib_recursive slower in ReleaseFast than Debug (487ms vs 205ms)
- **F99**: Iterative lazy-seq realization — task 24C.7
- **NaN boxing (D72)**: 600+ call sites, task 24C.6. Portable (works on wasm too)
- **deftype/reify**: Permanent skip — no JVM class generation. defrecord covers data use cases.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references:
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing layout)
  - GC: `ClojureWasmBeta/gc/generational.zig`, `gc/nursery.zig`
  - Benchmarks: `ClojureWasmBeta/status/bench.yaml`
