# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 24A active, task 24A.0
- Blockers: none

## Task Queue

Phase 24A — Speed Optimization:
1. 24A.0: Baseline measurement (add 9 benchmarks, profile)
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

24A.0: Baseline measurement
- Add 9 new benchmarks (12-20)
- Run all 20 benchmarks with --record
- Profile hotspots

## Previous Task

F96: VM protocol compilation
- Added defprotocol (0x4A) + extend_type_method (0x4B) opcodes
- Compiler: emitDefprotocol + emitExtendType (removed InvalidNode fallback)
- VM: defprotocol/extend_type_method handlers + protocol_fn dispatch in performCall
- bootstrap.callFnVal: added .protocol_fn case for cross-backend dispatch
- tree_walk.zig: made valueTypeKey pub for bootstrap access
- vm.zig: duplicated mapTypeKey/valueTypeKey (avoid circular imports)
- Added direct (non-eval) protocol tests: 5 tests, 18 assertions, both backends
- F96 removed from checklist.md

## Handover Notes

- **Phase 22c**: Complete. 16 tasks, all done. Gap analysis: `.dev/plan/test-gap-analysis.md`
- **Phase 24 plan**: `.dev/plan/phase24-optimization.md` — master optimization document
- **F96**: Resolved. Protocols now compile to VM bytecode and work on both backends.
- **D28 fully superseded**: All formerly TreeWalk-only features now on both backends.
- **deftype/reify**: Permanent skip — no JVM class generation. defrecord covers data use cases.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
