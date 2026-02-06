# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A active, task 24A.5
- Blockers: none

## Task Queue

Phase 24A — Speed Optimization:
1. ~~24A.0: Baseline measurement~~ (done)
2. ~~24A.1: VM dispatch optimization~~ (done)
3. ~~24A.2: Stack argument buffer~~ (done)
4. ~~24A.3: Fused reduce (lazy-seq chain collapse)~~ (done)
5. ~~24A.4: Arithmetic fast-path widening (@addWithOverflow)~~ (done)
6. 24A.5: Inline caching (protocol dispatch IC)
7. 24A.6: Hash table bitmask optimization
8. 24A.7: Constant folding (analyzer pass)
9. 24A.8: Superinstructions (opcode fusion)
10. 24A.9: @branchHint annotations (VM hot paths)
11. 24A.10: AOT bytecode bootstrap (partial, blocked by F7)

Phase 24B — Memory Optimization:
12. 24B.1: NaN boxing (48 bytes -> 8 bytes)
13. 24B.2: HAMT (persistent hash array mapped trie)
14. 24B.3: RRB-Tree (conditional, if vector bottleneck)
15. 24B.4: GC tuning (post NaN-boxing)

Decision gate after 24B: targets met -> Phase 25. Not met -> evaluate 24C (JIT).

## Current Task

24A.5: Inline caching (protocol dispatch IC)
- Protocol dispatch: monomorphic IC at call sites
- Cache (type, method_fn) per call site
- Expected: 2-5x on protocol-heavy code

## Previous Task

24A.4: Arithmetic fast-path widening (@addWithOverflow)
- Inlined int+int fast path in VM vmBinaryArith (avoid cross-file call to arithmetic.zig)
- @addWithOverflow/@subWithOverflow/@mulWithOverflow for overflow detection
- Inlined int+int fast path in vmBinaryCompare
- Overflow promotes to float (matches Clojure auto-promotion)
- fib_recursive: 542→41ms (13.2x!) from eliminating function call overhead
- Also fixes correctness: ReleaseSafe no longer panics on integer overflow

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
