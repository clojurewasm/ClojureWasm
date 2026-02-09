# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Phase 43 COMPLETE** (Array + BigInt + BigDecimal + auto-promotion + Ratio)
- Coverage: 795+ vars done across all namespaces (593/706 core, 45/45 math, 28/28 zip, 32/39 test, 9/26 pprint, 6/6 stacktrace, etc.)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Wasm interpreter**: 461 opcodes (225 core + 236 SIMD), 7.9x FFI improvement (D86), multi-module linking
- **JIT**: ARM64 hot integer loops (D87), arith_loop 53→3ms (17.7x cumulative)
- **Test porting**: 38 upstream test files, all passing. See `.dev/test-porting-plan.md`

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (2.9MB macOS, 14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

## Task Queue

Phase 45: Wasm Runtime Optimization
Plan: `.dev/wasm-opt-plan.md`

1. [x] 45.1: Benchmark infrastructure — TinyGo native + wasm benchmarks
2. [ ] 45.2: Predecoded IR (fixed-width instruction encoding)
3. [ ] 45.3: Tail-call threaded dispatch
4. [ ] 45.4: Superinstructions (fuse common patterns)
5. [ ] 45.5: Memory access optimization

## Current Task

Phase 45.1 COMPLETE: Wasm benchmark infrastructure.
Next: Phase 45.2 — Predecoded IR.

## Previous Task

Phase 45.1 COMPLETE: TinyGo benchmark infrastructure.
- TinyGo added to flake.nix (tinygo 0.40.1)
- bench.go added to all 20 cross-language benchmarks (01-20)
- compare_langs.sh: `tgo` language support added
- bench/wasm/: 4 TinyGo .go sources + 8 .wasm modules (single + bench variants)
- bench/wasm_bench.sh: CW vs wasmtime comparison (startup subtracted)
- Baseline (warm, CW interpreter vs wasmtime JIT):
  - fib(20)x10K: CW 10054ms vs wt 205ms (49x)
  - tak(18,12,6)x10K: CW 27301ms vs wt 1148ms (24x)
  - arith(1M)x10: CW ~1ms vs wt ~1ms (1x — parity)
  - sieve(64K)x100: CW 545ms vs wt 6ms (99x)
- 44.15: CLJW marker header counts verified and fixed in 23 test files
- FUNDING.yml + Support section (GitHub Sponsors)
- Acknowledgments expanded: Rich Hickey, Clojure community, Zig community

Phase 44.1+44.2 COMPLETE: Lazy range with infinite range support.
- rangeFn returns lazy_seq with Meta.range (no new Value type needed)
- `(range)` 0-arg → infinite lazy sequence (maxInt(i64) sentinel)
- Meta.float_range added for float ranges
- O(1) count for Meta.range/float_range in countFn
- O(1) nth for Meta.range/float_range in nthFn
- Fused reduce handles float_range for zero-alloc iteration
- Both backends verified, all 38 upstream test files pass
- Ratio: numerator/denominator BigInt pair, GCD-reduced, shares slot 30 via NumericExtKind
- Reader: ratio literal (1/3) → Form.ratio → Value.ratio conversion
- Arithmetic: +/-/*// with Ratio, cross-type with int/float/BigInt/BigDecimal
- Integer division that doesn't divide evenly → Ratio (e.g. (/ 1 3) → 1/3)
- Comparison: cross-multiply (a/b vs c/d → compare a*d vs c*b)
- Predicates: ratio?, number?, zero?, pos?, neg? handle Ratio
- Builtins: numerator, denominator, rationalize
- Cross-type equality: numericEql in value.zig (Ratio vs int/float/BigInt)
- macro.zig: valueToForm Ratio→Form round-trip (critical for `are` macro)
- compiler.zig: (/ x) uses integer 1 not float 1.0 for correct Ratio result
- Upstream tests: numbers.clj 31 tests, 402 assertions (was 29/360)
  - test-ratios-simplify-to-ints, test-ratios (15 assertions), ratio comparisons
  - Restored ratio results in test-divide, test-quot, equality, predicates

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
| Roadmap              | `.dev/roadmap.md`                         |
| OSS release plan     | `private/20260208/02_oss_plan.md`         |
| Deferred items       | `.dev/checklist.md` (F3-F135)             |
| Decisions            | `.dev/decisions.md` (D1-D89)              |
| Optimizations        | `.dev/optimizations.md`                   |
| Benchmarks           | `bench/history.yaml`                      |
| Zig tips             | `.claude/references/zig-tips.md`          |
| Skip recovery        | `.dev/skip-recovery.md`                   |
| Test porting plan    | `.dev/test-porting-plan.md`               |
| Archived plans       | `.dev/archive/` (Phase 24-30, CX, A)     |

## Handover Notes

- **Phase 43 COMPLETE**: All 8 sub-tasks done
  - 43.1-43.4: Array subsystem (34 builtins, ZigArray Value type)
  - 43.5-43.6: BigInt + BigDecimal (pure Zig, reader N/M literals)
  - 43.7: Auto-promoting arithmetic (+', -', *', inc', dec')
  - 43.8: Ratio (GCD-reduced, cross-type arithmetic/comparison/equality)
  - numbers.clj: 31 tests, 402 assertions
- **Next**: Phase 44 (OSS Release Prep) — read `private/20260208/02_oss_plan.md`
- **Phase 43.5-43.6 COMPLETE**: BigInt + BigDecimal
  - D89 updated: Four Value types (array, big_int, ratio+big_decimal) in NaN boxing
  - BigDecimal shares slot 30 with Ratio via NumericExtKind discriminator (extern struct)
  - Full arithmetic, predicates, equality, coercion for both types
  - numbers.clj: 26 tests, 323 assertions
- **Phase 43.1-43.4 COMPLETE**: Array subsystem
  - D89: Array, BigInt, Ratio NanHeapTag slots in Group D
  - 34 array builtins: constructors, typed arrays, setters, coercion, macros
  - Array seq integration (seq/first/rest/nth/count/vec on arrays)
  - Upstream test port: arrays.clj (14 tests, 144 assertions)
- **Phase 42 COMPLETE**: Quick Wins + Protocol Extension
  - 42.1: uri?, uuid?, destructure, seq-to-map-for-destructuring
  - 42.2: extend, extenders, extends?, find-protocol-impl, find-protocol-method
  - 42.3: get-thread-bindings, bound-fn*, bound-fn
  - Test porting: protocols.clj (8 tests, 27 assertions), vars.clj (7 tests, 18 assertions)
- **EvalError fix**: All bare `return error.EvalError` now set error details (~50 sites)
  - Added `err.ensureInfoSet()` helper in error.zig
  - bootstrap.zig, eval.zig, file_io.zig, misc.zig, ns_ops.zig all fixed
- **Test porting plan**: `.dev/test-porting-plan.md` — mandatory for Phase 42+
  - Each sub-task: implement → port tests → regression check → commit
  - 38 upstream test files all passing
- **Phase 41 COMPLETE**: Polish & Hardening
  - 41.1: ex-cause fix + pprint dynamic vars (7 vars)
  - 41.4: Upstream test porting (control, sequences, transducers)
  - 41.5: Bug fixes (try/catch peephole, sorted collections, take 0)
- **SKIP Recovery Plan**: 165 skip vars analyzed, 8 categories decided:
  - Cat 1 (Array 35 vars): IMPLEMENT Phase 43 — new Array Value type
  - Cat 2 (Agent 17 vars): DEFER — needs multi-thread GC
  - Cat 3 (STM 9 vars): OUT OF SCOPE — atom sufficient
  - Cat 4 (Proxy/Reify ~20 vars): PARTIAL — 5 protocol extension vars in Phase 42
  - Cat 5 (Future 9 vars): IMPLEMENT Phase 44 — Zig thread pool
  - Cat 6 (import 2 vars): DESIGN EXPLORE Phase 45
  - Cat 7 (BigNum 7 vars): IMPLEMENT Phase 43 — pure Zig BigInt/BigDecimal
  - Cat 8 (Quick wins ~10 vars): IMPLEMENT Phase 42
  - Full details: `.dev/skip-recovery.md`
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
