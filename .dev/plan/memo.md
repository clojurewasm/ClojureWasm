# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-4 done)
- Babashka comparison: CW wins 18/20 (15 speed+mem, 3 mem only)
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. ~~24C.2: Multimethod dispatch optimization (95x gap)~~ DONE
3. ~~24C.3: String ops optimization (15x gap)~~ DONE
4. ~~24C.4: Collection ops optimization (vector_ops 8x, list_build 8.3x)~~ DONE
5. 24C.5: GC optimization (gc_stress 7.7x, nested_update 5.6x)
6. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks)
7. 24C.7: F99 iterative lazy-seq realization (wasm prerequisite)
8. 24C.8: Constant folding

## Current Task

24C.5: GC optimization (gc_stress 7.7x, nested_update 5.6x).
gc_stress: 324ms (BB 42ms), nested_update: 124ms (BB 22ms).
Both show high sys time, suggesting allocation/GC overhead.
Profile to identify: allocation frequency, GC cycle cost, tracing overhead.

## Previous Task

24C.4: Collection ops optimization (vector_ops 8x→0.6x, list_build 8.3x→0.6x).
Two optimizations:
1. **Vector conj geometric growth**: PersistentVector gains `_capacity` and `_gen`
   fields. Backing array allocated with 2x capacity + 1 gen-tag slot. Sequential
   conj extends in-place when gen matches (COW detection via integer tag in last
   slot). Branching triggers copy. Reduces allocations from O(N) to O(log N) and
   copies from O(N²) to O(N). Results: 180ms→14ms (12.9x).
2. **cons → Cons cells**: consFn always returns Cons cells (matching JVM Clojure
   semantics) instead of copying into PersistentList. Each cons is O(1) instead
   of O(N). Added `.cons` case to conjOne. Results: 178ms→13ms (13.7x).
- Bonus: real_workload 501→50ms (uses vector conj), map_filter_reduce 179→14ms
  (unexpected improvement from cons/vector changes).

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
