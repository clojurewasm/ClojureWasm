# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A complete, Phase 24B complete, Phase 24C in progress (24C.1-3 done)
- Babashka comparison: CW wins ~13/20 (string_ops fixed: 398ms→28ms)
- Goal: Beat Babashka on ALL 20 benchmarks (speed AND memory)
- Blockers: none

## Task Queue

Phase 24C — Portable Optimization (Babashka Parity):
1. ~~24C.1: Fix fused reduce — restore __zig-lazy-map in redefined map~~ DONE
2. ~~24C.2: Multimethod dispatch optimization (95x gap)~~ DONE
3. ~~24C.3: String ops optimization (15x gap)~~ DONE
4. 24C.4: Collection ops optimization (vector_ops 8.5x, list_build 8.3x)
5. 24C.5: GC optimization (gc_stress 7.8x, nested_update 6.4x)
6. 24C.6: NaN boxing (D72, Value 48→8B, all benchmarks)
7. 24C.7: F99 iterative lazy-seq realization (wasm prerequisite)
8. 24C.8: Constant folding

## Current Task

24C.4: Collection ops optimization (vector_ops 8x, list_build 8.3x).
Both benchmarks show ~100ms user + ~72ms sys = ~178ms total. The heavy
sys time suggests GC/allocation overhead from collection building.
Profile vector_ops and list_build to identify allocation hot spots.

## Previous Task

24C.3: String ops optimization (15x gap → 1.0x).
- Root cause: `strSingle` used `Writer.Allocating` (dynamic buffer with multiple
  alloc/free per call) for every integer-to-string conversion
- Fix: stack-buffer fast paths for integer/boolean/keyword in `strSingle`:
  - Integer: bufPrint to 24-byte stack buffer, single allocator.dupe
  - Boolean: allocator.dupe of "true"/"false" literal
  - Keyword: direct concatenation into allocated buffer
- Results: 398ms→28ms (14.2x improvement), sys time 312ms→2ms (135x)
  Now matches Babashka (28ms)

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
