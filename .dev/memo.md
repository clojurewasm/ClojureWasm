# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 37 COMPLETE**
- Coverage: 661 vars done across all namespaces (539/704 core, 44/45 math, 7/19 java.io, etc.)
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
4. [ ] 38.4: case* compiler special form — O(1) hash dispatch (if time permits)
5. [ ] 38.5: ns macro enhancement — :import support, docstring

## Current Task

38.4: case* compiler special form — O(1) hash dispatch.
Add case* special form to the compiler for constant-time case dispatch using
hash tables instead of linear cond chains. Currently `case` macro compiles to
nested `cond` which is O(n).

## Previous Task

38.1: Infrastructure fixes enabling thrown-with-msg? in multimethod tests (D88).
- var_ref bootstrap serialization + deferred fixup (serialize.zig)
- test.clj report ns-qualification for bootstrap cache (test.clj)
- compiler emitDefmulti stack_depth double-increment fix (compiler.zig)
- Cross-boundary exception handling: call_target_frame scope isolation (vm.zig, D88)
- callFunction errdefer state restoration on error propagation (vm.zig)
- Namespace restoration in bytecodeCallBridge (bootstrap.zig)
- Result: 9 tests / 123 assertions pass on both VM + TreeWalk

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
