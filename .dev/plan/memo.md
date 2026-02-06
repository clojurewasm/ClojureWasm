# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-5c, 24C.7 done)
- Babashka comparison: CW wins speed 18/20, memory 19/20
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Remaining gaps: nested_update (1.8x), gc_stress (1.3x)

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. ~~24C.2: Multimethod dispatch optimization (95x gap)~~ DONE
3. ~~24C.3: String ops optimization (15x gap)~~ DONE
4. ~~24C.4: Collection ops optimization (vector_ops 8x, list_build 8.3x)~~ DONE
5. ~~24C.5: GC optimization (gc_stress 7.7x, nested_update 5.6x)~~ DONE
6. ~~24C.7: Filter chain collapsing + active VM call bridge (sieve 75x)~~ DONE
7. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks) — deferred, 600+ call sites
8. 24C.8: Constant folding
9. 24C.9: Remaining gaps — nested_update (1.8x), gc_stress (1.3x)

## Current Task

24C.9: Close remaining gaps — nested_update (1.8x BB) and gc_stress (1.3x BB).
These are the last 2 benchmarks where CW doesn't win speed.
nested_update: 41ms vs BB 22ms. gc_stress: 63ms vs BB 42ms.

## Previous Task

24C.7: Filter chain collapsing + active VM call bridge — sieve 1645→21ms (78x improvement).
D74: New lazy_filter_chain Meta variant flattens 168 nested filter layers into flat pred array.
callFnVal now routes bytecode calls through active_vm when available (avoids ~500KB heap alloc).
Memory: 2997MB → 23.8MB (125x improvement). Beats BB's 22ms.

## Handover Notes

- **Phase 24C plan**: `.dev/plan/phase24-optimization.md` — Babashka parity targets
- **Optimization knowledge**: `.claude/references/optimization-knowledge.md`
- **Benchmark history**: `bench/history.yaml` — record after every optimization task
- **F97**: RESOLVED — stack overflow in lazy-seq realization (512MB stack, meta tracing fix)
- **F98**: fib_recursive slower in ReleaseFast than Debug (487ms vs 205ms)
- **F99**: Partially resolved by D74 filter chain collapsing. General recursion remains for Phase 25.
- **F100**: RESOLVED — adding update-in/assoc-in/get-in to hot_core_defs recovered 72→40ms
- **NaN boxing (D72)**: 600+ call sites, task 24C.6. Portable (works on wasm too)
- **deftype/reify**: Permanent skip — no JVM class generation. defrecord covers data use cases.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references:
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing layout)
  - GC: `ClojureWasmBeta/gc/generational.zig`, `gc/nursery.zig`
  - Benchmarks: `ClojureWasmBeta/status/bench.yaml`
