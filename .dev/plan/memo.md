# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A active, task 24A.0
- Blockers: none

## Task Queue

Phase 24A — Speed Optimization:
1. ~~24A.0: Baseline measurement~~ (done)
2. 24A.1: VM dispatch optimization (function pointer table)
3. 24A.2: Stack argument buffer (stack-local 1-4 args)
4. 24A.3: Fused reduce (lazy-seq chain collapse)
5. 24A.4: Arithmetic fast-path widening (@addWithOverflow)
6. 24A.5: Inline caching (protocol dispatch IC)
7. 24A.6: Hash table bitmask optimization
8. 24A.7: Constant folding (analyzer pass)
9. 24A.8: Superinstructions (opcode fusion)

Phase 24B — Memory Optimization:
10. 24B.1: NaN boxing (48 bytes -> 8 bytes)
11. 24B.2: HAMT (persistent hash array mapped trie)
12. 24B.3: RRB-Tree (conditional, if vector bottleneck)
13. 24B.4: GC tuning (post NaN-boxing)

Decision gate after 24B: targets met -> Phase 25. Not met -> evaluate 24C (JIT).

## Current Task

24A.1: VM dispatch optimization (function pointer table)
- Replace switch(instr.op) with comptime-generated function pointer table
- Expected: 10-30% VM throughput improvement

## Previous Task

24A.0: Baseline measurement
- Added 9 new benchmarks (12-20): gc_stress, lazy_chain, transduce, keyword_lookup,
  protocol_dispatch, nested_update, string_ops, multimethod_dispatch, real_workload
- Recorded Pre-Phase24 baseline (Debug + ReleaseFast, VM)
- Top bottlenecks: lazy_chain(19.4s), transduce(7.9s), map_filter_reduce(3.6s),
  multimethod_dispatch(1.75s), sieve(1.7s)
- Found F97 (GC double-free in sieve) and F98 (fib_recursive ReleaseFast anomaly)
- Optimization priority targets are lazy-seq chain and allocation overhead

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
