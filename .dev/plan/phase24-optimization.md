# Phase 24: Optimization Plan

Master optimization plan for ClojureWasm.

**Two-phase structure**: 24A (Speed) -> 24B (Memory) -> 24C (JIT, conditional)

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

## 5. Phase 24C: JIT (conditional)

Record as technical reference. Proceed only if 24A/24B targets not met.

**Decision gate**: After 24B completion, measure against targets.
If targets met -> Phase 25 (Wasm). If not -> evaluate 24C options.

### 24C.1: Copy-and-patch JIT

- Pre-compiled code templates, patched with runtime values
- CPython 3.13 uses this approach
- **Zig advantage**: comptime template generation
- Lower complexity than tracing JIT

### 24C.2: Tracing JIT

- Record hot loop traces, compile to native
- Multi-tier: Tier-1 threaded code, Tier-2 tracing
- **Zig advantage**: Can leverage Zig x86/ARM backend (forklift project)
- Highest complexity, highest potential payoff

### 24C.3: Superinstructions (extended)

- Profile-guided opcode fusion, wider scope than 24A.8

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

| Benchmark                | Baseline (ms) | After 24A.4 (ms) | Speedup | Category    |
|--------------------------|---------------|-------------------|---------|-------------|
| protocol_dispatch (10K)  | 52            | 29                | 1.8x    | dispatch    |
| fib_loop                 | 56            | 29                | 1.9x    | computation |
| atom_swap                | 51            | 30                | 1.7x    | concurrency |
| keyword_lookup (100K)    | 59            | 35                | 1.7x    | collections |
| tak                      | 53            | 36                | 1.5x    | computation |
| map_ops                  | 62            | 38                | 1.6x    | collections |
| nqueens                  | 61            | 40                | 1.5x    | hof         |
| fib_recursive            | 542           | 41                | 13.2x   | computation |
| arith_loop               | 98            | 72                | 1.4x    | computation |
| nested_update (10K)      | 292           | 135               | 2.2x    | collections |
| vector_ops               | 426           | 186               | 2.3x    | collections |
| list_build               | 420           | 188               | 2.2x    | collections |
| gc_stress (100K)         | 372           | 351               | 1.1x    | gc          |
| string_ops (100K)        | 446           | 417               | 1.1x    | string      |
| real_workload (10K)      | 1,286         | 513               | 2.5x    | composite   |
| sieve                    | 2,152 (F97)   | 42 (F97)          | --      | hof         |
| multimethod_dispatch(10K)| 2,373         | 1,985             | 1.2x    | dispatch    |
| map_filter_reduce        | 4,013         | 1,315             | 3.1x    | collections |
| transduce (10K)          | 8,409         | 3,043             | 2.8x    | sequences   |
| lazy_chain (10K)         | 21,375        | 7,425             | 2.9x    | sequences   |

### Optimizations applied (24A.1-24A.4)

- **24A.1**: Switch dispatch + batched GC (general 1.5-1.8x improvement)
- **24A.2**: Stack argument buffer for TreeWalk (reduces heap alloc in interpreter)
- **24A.3**: Fused reduce (lazy-seq chain collapse) — eliminates intermediate lazy-seq
  allocations but still requires per-element VM callFunction for closures
- **24A.4**: Arithmetic fast-path inlining + @addWithOverflow — inline int+int
  arithmetic and comparison directly in VM step, avoid cross-file function calls.
  fib_recursive 542→41ms (13.2x) from eliminating function call overhead per operation.

### Key findings

- **fib_recursive**: 542ms → 41ms (13.2x!). Inlining int+int arithmetic in VM step
  eliminated function call overhead for ~33M operations in fib(25).
- **Lazy-seq chain**: 21.4s → 7.4s (2.9x). Still slow due to per-element callFunction overhead.
  Further improvement requires inlining simple closures or JIT compilation.
- **Transducer pipeline**: 8.4s → 3.0s (2.8x). Same callFunction overhead bottleneck.
- **multimethod_dispatch**: 2.4s → 2.0s (1.2x). Dispatch table lookup, mostly unaffected.
- **sieve**: GC double-free (F97) makes timing unreliable.
- **gc_stress**: No change — allocation-bound, awaits NaN boxing (24B.1).

## 9. Success Criteria

| Benchmark          | Baseline (RS) | Current    | 24A target | 24B target | Babashka | JVM warm |
|--------------------|---------------|------------|------------|------------|----------|----------|
| fib_recursive      | 542ms         | **41ms**   | <50ms ✅   | <30ms      | 152ms    | 10ms     |
| map_filter_reduce  | 4,013ms       | 1,315ms    | <200ms     | <100ms     | --       | --       |
| arith_loop         | 98ms          | 72ms       | <50ms      | <30ms      | --       | --       |
| lazy_chain         | 21,375ms      | 7,425ms    | <500ms     | <200ms     | --       | --       |
| gc_stress          | 372ms         | 351ms      | baseline   | <50% base  | --       | --       |

**Gate**: Beat Babashka on all comparable benchmarks after 24A.
