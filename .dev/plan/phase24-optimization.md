# Phase 24: Optimization Plan

Master optimization plan for ClojureWasm.

**Three-phase structure**: 24A (Speed) -> 24B (Memory) -> 24C (Portable Optimization)

## 1. Goals & Principles

- **Two-phase**: 24A targets throughput, 24B targets memory footprint
- **Target**: Outperform Babashka on all benchmarks, approach warm JVM on compute
- **Zig-native idioms**: Exploit comptime, packed structs, @Vector, stack locals
  — not Java patterns re-implemented in Zig
- **Readability**: Extract optimized hot paths into dedicated files, keep API clean
- **Benchmark-gated**: Optimize only what profiling shows matters
- **JIT (24C)**: Investigate only if 24A/24B targets not met. If met, move to Phase 25.

## 2. Benchmark Expansion (24A.0)

### Current benchmarks (1-11)

| #  | Name              | Category    |
|----|-------------------|-------------|
| 01 | fib_recursive     | Computation |
| 02 | fib_loop          | Computation |
| 03 | tak               | Computation |
| 04 | arith_loop        | Computation |
| 05 | map_filter_reduce | Sequences   |
| 06 | vector_ops        | Collections |
| 07 | map_ops           | Collections |
| 08 | list_build        | Collections |
| 09 | sieve             | Computation |
| 10 | nqueens           | Computation |
| 11 | atom_swap         | Concurrency |

### New benchmarks (12-20)

| #  | Name                 | Category    | Measures                             | Target optimization  |
|----|----------------------|-------------|--------------------------------------|----------------------|
| 12 | gc_stress            | GC/Memory   | Allocation-heavy loop (1M small maps)| GC, NaN boxing       |
| 13 | lazy_chain           | Sequences   | (take N (filter (map (range))))      | Fused reduce         |
| 14 | transduce            | Sequences   | (transduce (comp (map) (filter)) +)  | Transducer pipeline  |
| 15 | keyword_lookup       | Collections | Keyword map access in tight loop     | Inline caching       |
| 16 | protocol_dispatch    | Dispatch    | Protocol method call in loop         | Inline caching       |
| 17 | nested_update        | Collections | assoc-in/update-in deep nesting      | HAMT                 |
| 18 | string_ops           | String      | str concat, subs, string join        | String repr          |
| 19 | multimethod_dispatch | Dispatch    | defmulti dispatch in loop            | Dispatch optimization|
| 20 | real_workload        | Composite   | Data transform pipeline              | Overall throughput   |

### Measurement methodology

- **Build mode: ReleaseSafe** (mandatory, never use Debug or ReleaseFast)
- **Backend: VM** (primary benchmark target)
- `hyperfine` for wall-clock, `time -l` for RSS
- Comparison: Babashka, JVM Clojure (cold+warm), C, Zig
- Command: `bash bench/run_bench.sh --release-safe --backend=vm --record --version="..."`

## 3. Phase 24A: Speed Optimization

Implementation order by dependency + ROI:

### 24A.0: Baseline measurement

- Add 9 new benchmarks (12-20)
- Run all 20 benchmarks with `--record`
- Profile hotspots with `perf`/`instruments`

### 24A.1: VM dispatch optimization

- **Current**: `switch (instr.op)` in vm.zig execute()
- **Target**: Function pointer table dispatch (comptime-generated handler array)
- **Zig advantage**: comptime handler table, zero runtime setup
- **Expected**: 10-30% VM throughput
- **Reference**: ziggit.dev dispatch discussion, sudw1n dispatch article

### 24A.2: Stack argument buffer

- **Current**: Every `call` allocates args on GC allocator
- **Target**: Stack-local buffer for 1-4 args
- **Zig advantage**: `var buf: [4]Value = undefined;` zero-cost
- **Beta reference**: `call_args_buf` eliminated 1M allocs in reduce
- **Expected**: 2-5x on reduce-heavy benchmarks

### 24A.3: Fused reduce

- Detect `(reduce f init (take/map/filter chain))` patterns
- Compile-time: emit fused_reduce opcodes
- Runtime fallback: walk lazy-seq chain, fuse at dispatch
- **Beta result**: 27GB -> 2MB, massive speedup
- **Expected**: 10-100x on lazy-seq benchmarks

### 24A.4: Arithmetic fast-path widening

- Verify int+int fast path in add/sub/mul opcodes
- Add `@addWithOverflow` for overflow detection
- **Expected**: 10-30% on computation benchmarks

### 24A.5: Inline caching

- Protocol dispatch: monomorphic IC at call sites
- Quickening: rewrite opcode after first dispatch
- Cache `(type, method_fn)` per call site
- **Expected**: 2-5x on protocol-heavy code

### 24A.6: Hash table bitmask optimization

- Power-of-two capacity + `&` instead of `%`
- Verify if Zig std.HashMap already does this
- Crafting Interpreters: 2x from this alone

### 24A.7: Constant folding

- Analyzer pass: `(+ 1 2)` -> `3` at compile time
- Low complexity, moderate payoff
- Beta has reference implementation

### 24A.8: Superinstructions

- Fuse common opcode pairs: `local_load + local_load + add` -> `add_locals`
- Profile top N sequences, comptime-generate handlers
- **Expected**: 5-15% on general code

### 24A.9: @branchHint annotations

- Add `@branchHint(.likely)` / `@branchHint(.unlikely)` to VM hot paths
- **Targets**: execute loop error path (unlikely), performCall fn_val (likely),
  stack overflow checks (unlikely), GC threshold checks (unlikely)
- **Zig advantage**: Direct LLVM branch weight metadata, no runtime cost
- **Expected**: 5-10% on all benchmarks (better branch prediction in Release)

### 24A.10: AOT bytecode bootstrap (partial)

- **Current**: core.clj is `@embedFile`'d as source text, parsed+evaluated at runtime
- **Target**: Pre-serialize Reader AST or pre-compile non-macro forms to bytecode
- **Blocker**: F7 (macro body serialization) prevents full AOT. Partial approach:
  1. Pre-parse core.clj to serialized Reader AST (skip re-parsing at startup)
  2. Or pre-compile all non-defmacro forms, eval macros at runtime
  3. Embed pre-compiled bytecode via `@embedFile`
- **Zig advantage**: `@embedFile` + comptime deserialization
- **Impact**: Bootstrap startup time reduction (currently dominates short-running programs)
- **Reference**: D18 (hybrid architecture), T4.7 (full AOT, blocked by F7)

## 4. Phase 24B: Memory Optimization

### 24B.1: NaN Boxing (Value: 48 bytes -> 8 bytes)

- Float: stored directly as f64 bits
- Int (small): inline in mantissa (48-bit range)
- Pointers: lower 48 bits + NaN quiet tag
- Singletons: unique bit patterns
- **Zig advantage**: `@bitCast`, packed structs
- **Scope**: ~20 files need value dispatch updates
- **Impact**: 6x smaller values, better cache locality

### 24B.2: HAMT

- Replace PersistentArrayMap for large maps
- 32-way branching, O(log32 n) lookup
- **Zig**: `@popCount` for population count, packed bits
- Structural sharing for immutable updates

### 24B.3: RRB-Tree (conditional)

- Replace PersistentVector internals if vector_ops bottleneck found
- O(log32 n) append/lookup/slice

### 24B.4: GC tuning

- Re-tune collection threshold post NaN-boxing (smaller footprint)
- Evaluate Beta's nursery/generational prototype
- Measure GC pause times

## 5. Phase 24C: Portable Optimization (Babashka Parity)

All optimizations in this phase benefit both native and wasm_rt targets.
Goal: Beat Babashka on ALL 20 benchmarks in both speed AND memory.

**Knowledge base**: `.claude/references/optimization-knowledge.md`
**Benchmark recording**: `bash bench/record.sh --id="24C.N" --reason="description"`

### 24C.1: Closure specialization

- **Root cause**: callFn per element in fused reduce (289x slower on lazy_chain)
- Detect simple closure patterns at compile time: `(fn [x] (op x const))`
- Generate specialized code that avoids full VM dispatch per element
- Alternative: lightweight call path skipping full frame setup for single-expression closures
- **Targets**: lazy_chain, transduce, map_filter_reduce, sieve, real_workload
- **Expected**: 10-100x on sequence benchmarks

### 24C.2: Multimethod dispatch optimization

- **Gap**: 95x slower than Babashka (2,094ms vs 22ms)
- Profile dispatch table lookup, identify per-call overhead sources
- Consider: dedicated VM opcode, cached dispatch, method table inlining
- **Expected**: 10-50x improvement

### 24C.3: String ops optimization

- **Gap**: 15x slower than Babashka (419ms vs 28ms)
- Profile concat/join/subs bottleneck
- Potential: rope strings, pre-allocated buffers, reduce intermediate allocations
- **Expected**: 5-15x improvement

### 24C.4: Collection ops optimization

- **Gap**: vector_ops 8.5x, list_build 8.3x slower than Babashka
- Profile: transient path efficiency, cons allocation, conj performance
- Potential: bump allocator for cons cells, optimized transient! path
- **Expected**: 3-8x improvement

### 24C.5: GC optimization

- **Gap**: gc_stress 7.8x, nested_update 6.4x slower than Babashka
- Evaluate: nursery/bump allocator (Beta reference: gc/nursery.zig)
- Generational collection for short-lived allocations
- **Expected**: 3-8x improvement on allocation-heavy benchmarks

### 24C.6: NaN boxing (D72)

- Value 48→8 bytes. 6x cache locality improvement for ALL benchmarks
- Portable: works on wasm32 (f64 bit manipulation is universal)
- ~600+ call sites need updating. Largest single refactoring effort
- **Reference**: Beta value.zig for NaN boxing layout
- **Expected**: 2-4x improvement on collection/sequence benchmarks from cache effects

### 24C.7: F99 iterative lazy-seq realization

- Convert realize→realizeMeta→seqFn mutual recursion to heap-based work stack
- Removes 512MB stack size hack in build.zig
- Required for wasm_rt (wasm has ~1MB stack)
- Portable optimization that benefits native too
- **Expected**: Enables deeper lazy-seq chains, slight speed improvement

### 24C.8: Constant folding

- Compile-time evaluation of constant expressions: `(+ 1 2)` → `3`
- Analyzer pass before compilation
- **Expected**: Moderate improvement on benchmarks with literal arithmetic

## 6. Zig-Specific Optimization Advantages

| Area                  | Java/JVM                   | Zig-Native                                |
|-----------------------|----------------------------|-------------------------------------------|
| Value representation  | Object boxing + GC         | NaN boxing, stack values, no boxing       |
| Dispatch              | vtable (JVM optimized)     | comptime function pointer table           |
| Collections           | HAMT with Java objects     | HAMT with packed bits, @popCount          |
| String                | Immutable String objects   | Slice-based, zero-copy substrings         |
| Memory                | Generational GC            | Arena + mark-sweep, bump allocator        |
| Hot loop              | JIT to native              | Stack-local buffers, inline, SIMD         |
| Compile-time          | None (runtime only)        | comptime: tables, type specialization     |
| Error handling        | Exception objects + stack  | Error union, zero-cost when no error      |
| SIMD                  | Auto-vectorization         | Explicit @Vector, portable SIMD types     |

## 7. Readability Strategy

- Dedicated hot-path files (e.g., `vm_fast_arith.zig`, `fused_reduce.zig`)
- comptime abstractions: generate specialized code from readable templates
- Benchmark-gated: optimize only what profiling shows matters
- Fallback paths: keep readable generic path alongside fast path
- D## entries for each optimization trade-off decision

## 8. Actual Baseline (Pre-Phase24, VM, ReleaseSafe, Apple M4 Pro)

**Standard build mode: ReleaseSafe** (all benchmarks use this consistently).

| Benchmark                | Baseline (ms) | After 24A.9 (ms) | Speedup | Category    |
|--------------------------|---------------|-------------------|---------|-------------|
| atom_swap                | 51            | 18                | 2.8x    | concurrency |
| fib_loop                 | 56            | 19                | 2.9x    | computation |
| protocol_dispatch (10K)  | 52            | 19                | 2.7x    | dispatch    |
| tak                      | 53            | 23                | 2.3x    | computation |
| keyword_lookup (100K)    | 59            | 24                | 2.5x    | collections |
| map_ops                  | 62            | 26                | 2.4x    | collections |
| fib_recursive            | 542           | 28                | 19.4x   | computation |
| nqueens                  | 61            | 29                | 2.1x    | hof         |
| arith_loop               | 98            | 61                | 1.6x    | computation |
| nested_update (10K)      | 292           | 128               | 2.3x    | collections |
| list_build               | 420           | 178               | 2.4x    | collections |
| vector_ops               | 426           | 179               | 2.4x    | collections |
| gc_stress (100K)         | 372           | 330               | 1.1x    | gc          |
| string_ops (100K)        | 446           | 397               | 1.1x    | string      |
| real_workload (10K)      | 1,286         | 496               | 2.6x    | composite   |
| sieve                    | 2,152 (F97)   | 30 (F97)          | --      | hof         |
| multimethod_dispatch(10K)| 2,373         | 2,127             | 1.1x    | dispatch    |
| map_filter_reduce        | 4,013         | 1,281             | 3.1x    | collections |
| transduce (10K)          | 8,409         | 2,893             | 2.9x    | sequences   |
| lazy_chain (10K)         | 21,375        | 6,588             | 3.2x    | sequences   |

### Optimizations applied (24A.1-24A.9)

- **24A.1**: Switch dispatch + batched GC (general 1.5-1.8x improvement)
- **24A.2**: Stack argument buffer for TreeWalk (reduces heap alloc in interpreter)
- **24A.3**: Fused reduce (lazy-seq chain collapse) — eliminates intermediate lazy-seq
  allocations but still requires per-element VM callFunction for closures
- **24A.4**: Arithmetic fast-path inlining + @addWithOverflow — inline int+int
  arithmetic and comparison directly in VM step, avoid cross-file function calls.
  fib_recursive 542→41ms (13.2x) from eliminating function call overhead per operation.
- **24A.5**: Monomorphic inline cache for protocol dispatch — small improvement (~10%)
- **24A.9**: @branchHint(.unlikely) on error/rare paths — 28-40% on tight-loop benchmarks
- **24A.10**: Skipped (blocked by F7, startup already 10ms)

### Key findings

- **fib_recursive**: 542ms → 28ms (19.4x!). Combined inline arithmetic + branch hints.
- **Lazy-seq chain**: 21.4s → 6.6s (3.2x). Still slow due to per-element callFunction overhead.
  Further improvement requires inlining simple closures or JIT compilation.
- **Transducer pipeline**: 8.4s → 2.9s (2.9x). Same callFunction overhead bottleneck.
- **multimethod_dispatch**: 2.4s → 2.1s (1.1x). Dispatch table lookup, mostly unaffected.
- **sieve**: GC double-free (F97) makes timing unreliable.
- **gc_stress**: Minimal change — allocation-bound, awaits NaN boxing (24B.1).
- **Branch hints**: Surprisingly effective on tight loops (28-40%), modest on collection-heavy code.

## 9. Success Criteria: Beat Babashka on ALL 20 Benchmarks

**Gate**: CW must beat Babashka on every benchmark in BOTH speed AND memory.
Measured with hyperfine (ReleaseSafe). Babashka measured single-run wall clock.

### Current Status (post-24B)

| Benchmark             | CW ms  | BB ms | CW/BB  | CW MB     | BB MB  | Status   |
|-----------------------|--------|-------|--------|-----------|--------|----------|
| fib_recursive         | 24     | 34    | 0.7x   | 23.8      | 38.6   | WIN      |
| fib_loop              | 13     | 20    | 0.7x   | 23.8      | 31.4   | WIN      |
| tak                   | 16     | 24    | 0.7x   | 23.8      | 34.1   | WIN      |
| arith_loop            | 57     | 80    | 0.7x   | 23.8      | 76.9   | WIN      |
| map_ops               | 13     | 20    | 0.7x   | 25.6      | 32.4   | WIN      |
| keyword_lookup        | 20     | 26    | 0.8x   | 23.8      | 36.2   | WIN      |
| protocol_dispatch     | 15     | 27    | 0.6x   | 23.9      | 36.4   | WIN      |
| nqueens               | 26     | 30    | 0.9x   | 26.1      | 37.1   | WIN      |
| atom_swap             | 15     | 19    | 0.8x   | 23.8      | 31.9   | WIN      |
| gc_stress             | 329    | 42    | 7.8x   | 26.0      | 77.0   | LOSE spd |
| nested_update         | 141    | 22    | 6.4x   | 27.7      | 37.0   | LOSE spd |
| string_ops            | 419    | 28    | 15.0x  | 31.2      | 41.5   | LOSE spd |
| list_build            | 174    | 21    | 8.3x   | 34.1      | 32.2   | LOSE     |
| vector_ops            | 186    | 22    | 8.5x   | 34.2      | 34.6   | LOSE     |
| real_workload         | 511    | 23    | 22.2x  | 45.2      | 41.6   | LOSE     |
| map_filter_reduce     | 1293   | 22    | 58.8x  | 15367     | 37.7   | LOSE     |
| sieve                 | 1675   | 22    | 76.1x  | 2998      | 36.2   | LOSE     |
| multimethod_dispatch  | 2094   | 22    | 95.2x  | 83.1      | 33.5   | LOSE     |
| transduce             | 3348   | 20    | 167x   | 30657     | 32.3   | LOSE     |
| lazy_chain            | 6655   | 23    | 289x   | 30692     | 37.6   | LOSE     |

**Score**: 9 WIN / 11 LOSE. Target: 20 WIN / 0 LOSE.
