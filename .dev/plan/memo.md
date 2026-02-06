# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-5c, 24C.7 done)
- Babashka comparison: CW wins speed 19/20 (1 tied), Phase 24C complete
- nested_update: 23ms vs BB 22ms (tied, ±1ms noise)

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
9. ~~24C.9: Remaining gaps — nested_update (1.8x→1.3x), gc_stress (1.4x)~~ DONE
10. ~~24C.10: Collection constructor intrinsics (hash-map→map_new, vector→vec_new, etc.)~~ DONE

## Current Task

Phase 24C complete! CW wins speed 19/20 (1 tied nested_update ±1ms).
Assess Phase 24 completion and plan Phase 25 (wasm).

## Previous Task

24C.10: Collection constructor intrinsics — gc_stress 55→35ms (beats BB's 42ms).
Compiler emits map_new/vec_new/list_new/set_new opcodes directly instead of
var_load + call for hash-map/vector/list/hash-set calls.

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
