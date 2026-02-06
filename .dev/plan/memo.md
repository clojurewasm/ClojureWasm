# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-5c done)
- Babashka comparison: CW wins speed 17/20, memory 18/20
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none (F100 resolved)

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

24C.5b: Hot core recompilation — transduce 2134→15ms (142x, beats BB).
**Root cause**: core.clj loaded via TreeWalk makes ALL core functions TreeWalk
closures. Transducer step fns (map/filter/comp 1-arity) called in reduce hot
loops dispatch through treewalkCallBridge (~200x overhead per call).
**Fix**: D73 two-phase bootstrap — Phase 1 TreeWalk (fast), Phase 2 re-evaluates
map/filter/comp via VM compiler (evalStringVMBootstrap) producing bytecode closures.
Also: range/iterate fast-path in reduceGeneric (memory 30GB→0.9MB), VM variadic
rest args nil fix (rest_count==0 returns nil not ()).
**Trade-off**: nested_update 42→72ms (F100 — bytecode footprint cache side effect).

## Handover Notes

- **Phase 24C plan**: `.dev/plan/phase24-optimization.md` — Babashka parity targets
- **Optimization knowledge**: `.claude/references/optimization-knowledge.md`
- **Benchmark history**: `bench/history.yaml` — record after every optimization task
- **F97**: RESOLVED — stack overflow in lazy-seq realization (512MB stack, meta tracing fix)
- **F98**: fib_recursive slower in ReleaseFast than Debug (487ms vs 205ms)
- **F99**: Iterative lazy-seq realization — task 24C.7
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
