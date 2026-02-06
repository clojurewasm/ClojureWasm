# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-5 done)
- Babashka comparison: CW wins 18/20 (16 speed+mem, 2 mem only)
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. ~~24C.2: Multimethod dispatch optimization (95x gap)~~ DONE
3. ~~24C.3: String ops optimization (15x gap)~~ DONE
4. ~~24C.4: Collection ops optimization (vector_ops 8x, list_build 8.3x)~~ DONE
5. ~~24C.5: GC optimization (gc_stress 7.7x, nested_update 5.6x)~~ DONE
6. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks)
7. 24C.7: F99 iterative lazy-seq realization (wasm prerequisite)
8. 24C.8: Constant folding

## Current Task

24C.6: NaN boxing (D72, Value 48→8B, all benchmarks).
Current Value is a tagged union at 48 bytes. NaN boxing encodes all values in
8 bytes using IEEE 754 NaN payload bits. This improves cache locality (~6x),
reduces allocation sizes, and benefits wasm linear memory.
600+ call sites need migration. See optimization-knowledge.md section 5 for
wasm compatibility notes. Beta reference: ClojureWasmBeta/src/base/value.zig.

## Previous Task

24C.5: GC optimization (gc_stress 7.7x→1.1x, nested_update 5.6x→1.9x).
**Free-pool recycling** in MarkSweepGc: dead allocations during sweep are cached
in per-(size, alignment) free pools instead of rawFree. Next allocation of same
size pops from free pool (avoids GPA rawAlloc + rawFree overhead). Entries are
removed from HashMap during sweep and re-added on alloc from pool.
- gc_stress: 324→46ms (7.0x improvement)
- nested_update: 124→41ms (3.0x improvement)
- real_workload: 50→23ms (2.2x improvement, now ties BB)
- transduce: 3331→2134ms (1.6x improvement, bonus)

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
