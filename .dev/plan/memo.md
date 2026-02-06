# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-2 done)
- Babashka comparison: CW wins ~12/20 (multimethod fixed: 2053ms→14ms)
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. ~~24C.2: Multimethod dispatch optimization (95x gap)~~ DONE
3. 24C.3: String ops optimization (15x gap)
4. 24C.4: Collection ops optimization (vector_ops 8.5x, list_build 8.3x)
5. 24C.5: GC optimization (gc_stress 7.8x, nested_update 6.4x)
6. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks)
7. 24C.7: F99 iterative lazy-seq realization (wasm prerequisite)
8. 24C.8: Constant folding

## Current Task

24C.3: String ops optimization (15x gap — 398ms vs BB 28ms).
String operations are heavily GC-bound (311ms sys time). Profile and optimize
the string ops benchmark path — likely string allocation/concatenation overhead.

## Previous Task

24C.2: Multimethod dispatch optimization (95x gap → 0.6x).
- Root cause: VM used bootstrap.callFnVal (creates new VM instance per call)
  for both dispatch fn and method fn — 20000 VM creations for 10000 iterations
- Fix: 3-layer optimization:
  1. VM-native calls: self.callFunction for dispatch fn (reuses current VM)
  2. 2-level monomorphic dispatch cache:
     - Level 1: arg identity cache (skip dispatch fn call entirely)
     - Level 2: dispatch-val cache (skip findBestMethod)
  3. performCall for method fn (no VM creation)
  4. Keyword dispatch fn inlining for (defmulti foo :type) pattern
- Results: 2053ms→14ms (147x improvement), now faster than Babashka (22ms)
- Both VM and TreeWalk optimized

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
