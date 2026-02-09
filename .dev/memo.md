# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 37 COMPLETE**
- Coverage: 742 vars done across all namespaces (540/706 core, 45/45 math, 28/28 zip, 32/39 test, 9/26 pprint, 6/6 stacktrace, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Wasm interpreter**: 461 opcodes (225 core + 236 SIMD), 7.9x FFI improvement (D86), multi-module linking
- **JIT**: ARM64 hot integer loops (D87), arith_loop 53→3ms (17.7x cumulative)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 38: Core Library Completeness
1. [x] 38.1: thrown-with-msg? test assertion — enable skipped multimethod tests
2. [x] 38.2: Matcher Value type + re-matcher, re-groups — regex group extraction
3. [x] 38.3: Upstream alignment pass — fix highest-impact UPSTREAM-DIFF items
4. [-] 38.4: case* compiler special form — DEFERRED (case works, O(1) is optimization)
5. [x] 38.5: ns macro enhancement — :import support, docstring

## Task Queue

Phase 40: Library Expansion — COMPLETE
1. [x] 40.1: clojure.zip — zipper library (28 vars, upstream near-verbatim)
2. [x] 40.2: clojure.data — diff (skipped, protocols only)
3. [x] 40.3: clojure.test expansion — 18 vars added
4. [x] 40.4: clojure.walk/math/repl remaining vars (6 vars)

## Task Queue

Phase 41: Polish & Hardening
1. [x] 41.1: ex-cause fix + pprint dynamic vars (7 vars)
2. [x] 41.2: clojure.edn/read — SKIPPED (needs PushbackReader)
3. [x] 41.3: clojure.core.reducers — SKIPPED (needs reify, protocols, ForkJoin)
4. [x] 41.4: Upstream test porting
5. [ ] 41.5: Additional bug fixes and edge cases

## Current Task

41.5: Continue bug fixes and edge cases.
- Remaining known issues: control.clj (case throw in VM), sequences (cons+set, subseq), transducers (interpose, halt-when)

## Previous Task

41.5: Bug fixes and edge cases (round 1).
- Fixed concat 0-arity: return (lazy-seq nil) instead of nil (fixes nil-punning)
- Fixed into: preserve metadata through transient/persistent cycle
- Fixed assoc: preserve metadata during ArrayMap→HashMap transition
- Fixed math tests: adapt negate-exact/floor-div for CW 48-bit integers
- Result: walk 4→0, logic 2→0, math 2→0, metadata 7→0 test failures fixed
- Both VM + TreeWalk verified

## Known Issues

- (none currently open)

## Reference Chain

Session resume procedure: read this file → follow references below.

### Phase 36 (COMPLETE)

| Item                         | Location                                          |
|------------------------------|---------------------------------------------------|
| **Phase plan**               | `.dev/archive/phase36-simd-ffi.md`                   |
| **Optimization decision**    | `.dev/decisions.md` D86                     |
| **SIMD benchmarks**          | `bench/simd/` (4 programs + results.md)           |
| **Wasm benchmarks**          | `bench/benchmarks/21-25_wasm_*/`                  |
| **Conformance tests**        | `src/wasm/testdata/conformance/` (9 WAT+WASM)     |
| **E2E tests**                | `test/e2e/wasm/*.clj`, `test/e2e/run_e2e.sh`     |
| **Multi-module tests**       | `src/wasm/testdata/20-24_*.wasm`                  |

### Global references

| Topic               | Location                                  |
|----------------------|-------------------------------------------|
| Roadmap              | `.dev/roadmap.md`                    |
| Deferred items       | `.dev/checklist.md` (F3-F120)             |
| Decisions            | `.dev/decisions.md` (D1-D88)        |
| Optimizations        | `.dev/optimizations.md`             |
| Benchmarks           | `bench/history.yaml`                      |
| Zig tips             | `.claude/references/zig-tips.md`          |
| Archived plans       | `.dev/archive/` (Phase 24-30, CX, A) |

## Handover Notes

- **Phase 37 COMPLETE**: VM Optimization + JIT PoC
  - 37.1: Profiling (-Dprofile-opcodes, -Dprofile-alloc), GC benchmarks 26/27
  - 37.2: 10 superinstructions (0xC0-0xC9), arith_loop 53→40ms (1.33x)
  - 37.3: 7 fused branch/loop ops (0xD0-0xD6), arith_loop 40→31ms (1.29x)
  - 37.4: ARM64 JIT hot loops (D87), arith_loop 31→3ms (10.3x), cumulative 17.7x
  - 37.5/37.6: SKIPPED (GC not bottleneck, remaining gap is call/ret overhead)
- **Phase 37.4 COMPLETE**: JIT PoC — ARM64 hot loop native code generation
  - New file: `src/native/vm/jit.zig` — ARM64 JIT compiler (~700 lines)
  - Hot loop detection in vmRecurLoop: 64-iteration warmup threshold
  - Supported ops: branch_ne/ge/gt (locals/const), add/sub (locals/const), recur_loop
  - NaN-box type guards: unbox at entry, re-box at exit, deopt on non-integer
  - used_slots bitset: only loads/checks referenced slots (skips closure self-ref)
  - analyzeLoop: skips THEN path (exit code) via exit_offset from data word
  - JitState per VM: single cached loop, maxInt(u32) sentinel prevents retry after deopt
  - arith_loop: 31ms → 3ms (10.3x), cumulative 53ms → 3ms (17.7x)
  - ARM64 only (aarch64 comptime check); no-op on other architectures
- **Phase 37.3 COMPLETE**: Fused branch + loop superinstructions
  - 7 fused opcodes (0xD0-0xD6): compare-and-branch, recur_loop
  - In-place replacement: second instruction becomes consumed data word
  - arith_loop 40→31ms (1.29x), cumulative 53→31ms (1.71x)
  - Dispatch: 6→4 instructions/iteration (33% fewer dispatches)
- **Phase 37.2 COMPLETE**: Superinstructions
  - 10 fused opcodes: add/sub/eq/lt/le_locals, add/sub/eq/lt/le_local_const
  - Peephole optimizer in compiler.zig with jump offset fixup
  - arith_loop 56→40ms (1.4x), fib_recursive 19→16ms (1.2x)
- **Phase 37.1 COMPLETE**: Profiling infrastructure
  - Opcode frequency: `-Dprofile-opcodes` → VM dispatch loop counter + sorted dump
  - Allocation histogram: `-Dprofile-alloc` → per-size bucket counting in MarkSweepGc
  - New GC benchmarks: 26_gc_alloc_rate (200K vectors), 27_gc_large_heap (100K live maps)
  - Profiling data: arith_loop local_load 41.7%, add 16.7%, eq 8.3%
- **Phase 36.11 COMPLETE**: Pre-JIT optimizations
  - F101 DONE: into() transient optimization
  - F102, SmallString, String interning: analyzed and deferred (see optimizations.md)
  - Baseline benchmark recorded (36.11-base in history.yaml)
- **F113 RESOLVED**: nREPL GC integration
  - Added MarkSweepGc to ServerState, GC safe point after each eval
  - startServer creates local GC; startServerWithEnv receives caller's GC
  - Transient Values now collected automatically during long nREPL sessions
- **Phase 36 COMPLETE**: Wasm SIMD + FFI Deep (F118)
  - 36.1-36.6: SIMD full implementation (236 opcodes, v128 type, 2.58x speedup)
  - 36.7: Interpreter optimization (VM reuse 7.9x, sidetable 1.44x, D86)
  - 36.8: Multi-module linking (cross-module function imports)
  - 36.9: F119 fix (WIT string return ptr/len swap)
  - 36.10: Documentation update (wasm-spec-support.md, 461 opcodes)
- **Phase 35X COMPLETE**: Cross-platform build (D85 NaN boxing, CI)
- **Phase 35W COMPLETE** (D84): Custom Wasm runtime (8 files, switch dispatch)
- **Phase 35.5 COMPLETE**: Wasm runtime hardening (WASI 84%, conformance tests)
- **Architecture**: NaN boxing 4-tag 48-bit (D85), single binary trailer, ~3ms startup
- **nREPL/CIDER**: 14 ops. `cljw --nrepl-server --port=0`
