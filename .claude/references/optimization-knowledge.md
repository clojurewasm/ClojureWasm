# Optimization Knowledge Base

Reference for optimization decisions. Read when planning or implementing optimizations.

## 1. Portability Classification

Optimizations are classified by whether they benefit both native and wasm_rt targets.

### Portable (benefits both native and wasm_rt)

| Optimization             | Impact | Status       | Notes                                |
|--------------------------|--------|--------------|--------------------------------------|
| NaN boxing (Value 48→8B) | HIGH   | Deferred D72 | Cache locality 6x, wasm linear mem   |
| Closure specialization   | HIGH   | N/A          | Root cause was map redef, not callFn (24C.1) |
| Constant folding         | MEDIUM | Skipped 24A.7| Compile-time `(+ 1 2)` → `3`        |
| Fused reduce             | HIGH   | Done 24A.3   | But callFn per element still slow    |
| HAMT                     | MEDIUM | Done 24B.2   | Shared data structure                |
| Benchmark infrastructure | LOW    | Done         | bench/history.yaml + record.sh       |

### Native-specific (no wasm_rt benefit)

| Optimization             | Impact | Status       | Notes                                |
|--------------------------|--------|--------------|--------------------------------------|
| @branchHint              | MEDIUM | Done 24A.9   | No effect on wasm VM                 |
| Generational GC          | MEDIUM | Not started  | wasm uses WasmGC or linear memory    |
| Write barrier            | LOW    | Not started  | Only needed with generational GC     |
| F98 ReleaseFast fix      | LOW    | Not started  | Native Zig optimizer specific        |
| Batched GC               | LOW    | Done 24A.1   | GC implementation specific           |

### Recommendation

Do all portable optimizations before wasm_rt. Native-specific optimizations
can be deferred until after wasm_rt is functional — wasm_rt constraints inform
native GC design.

## 2. Biggest Bottleneck: callFn per Element

### Problem

Fused reduce detects lazy-seq chains (map/filter/take/range) and iterates
directly, but calls VM.callFunction for each user-defined closure:

```
(reduce + 0 (take 10000 (filter pred (map f (range 1000000)))))
        ^                        ^        ^
        |                        |        +-- callFn per element (VM dispatch)
        |                        +----------- callFn per element (VM dispatch)
        +------------------------------------ callFn per element (VM dispatch)
```

Each callFn involves: stack frame setup, opcode dispatch, GC checks, frame teardown.
For 20K source elements × 3 functions = 60K VM dispatches.

### Evidence

- ClojureWasm lazy_chain: 6,655ms (30,692 MB peak RSS)
- ClojureWasmBeta map_filter: 2.3ms (2.2 MB peak RSS)
- Ratio: ~2,893x slower

Beta's function call mechanism is lighter (likely direct Zig function pointer
call in builtin reduce, not full VM dispatch).

### Solution: Closure Specialization

Detect simple closure patterns at compile time and generate specialized code:

| Pattern               | Specialization                    |
|-----------------------|-----------------------------------|
| `(fn [x] (* x N))`   | Inline multiply with constant     |
| `(fn [x] (+ x N))`   | Inline add with constant          |
| `(fn [x] (= (mod x N) M))` | Inline modulo + compare     |
| `(fn [x] (< x N))`   | Inline compare with constant      |

For fused reduce, detect that transform functions are simple enough to inline,
and execute them without VM callFunction overhead.

**Alternative**: For non-inlinable closures, provide a lightweight call path
that skips full VM frame setup when the closure body is a single expression.

## 3. ClojureWasmBeta Comparison

### Optimizations in Beta NOT in ClojureWasm

| Feature              | Beta file                    | Description                       |
|----------------------|------------------------------|-----------------------------------|
| Generational GC      | gc/generational.zig          | Nursery + old gen + minor/major   |
| Nursery allocator    | gc/nursery.zig               | Bump pointer O(1) allocation      |
| Write barrier        | gc/generational.zig:136      | Card marking for old→young refs   |

### Optimizations in ClojureWasm NOT in Beta

| Feature              | File                         | Description                       |
|----------------------|------------------------------|-----------------------------------|
| HAMT                 | value.zig (PersistentHashMap)| Structural sharing, O(log32 n)    |
| @branchHint          | vm.zig                       | LLVM branch weight metadata       |
| Batched GC           | vm.zig                       | Amortized GC threshold checks     |
| Arithmetic fast-path | vm.zig                       | Inline int+int in VM step         |
| Monomorphic IC       | vm.zig                       | Protocol dispatch cache            |

### Benchmark Comparison (different conditions!)

**WARNING**: Beta uses ReleaseFast, ClojureWasm uses ReleaseSafe.
Beta benchmarks have different parameters (fib30 vs fib25, etc.).

| Benchmark       | CW param    | CW (RS) ms | Beta param    | Beta (RF) ms | Notes        |
|-----------------|-------------|------------|---------------|--------------|--------------|
| fib             | fib(25)     | 24         | fib(30)       | 69           | 11x more calls in Beta |
| map_filter/HOF  | list-based  | 1,293      | range-based   | 2.3          | CW ~2,893x slower |
| sum/arith       | loop/recur  | 57         | reduce+range  | 12.5         | Different algorithm |
| gc_stress       | 100K maps   | 329        | --            | --           | No Beta equivalent |
| lazy_chain      | range(1M)   | 6,655      | --            | --           | No Beta equivalent |

### Beta Benchmark History (key points)

From bench_improvement.yaml:
- TreeWalk baseline: fib30=1.90s, map_filter=1.75s (27GB memory)
- After fused reduce: map_filter=0.00s (6.5MB) — **1,757x improvement**
- After VM backend: fib30=0.07s (2.1MB) — **27x improvement over TreeWalk**
- Final (VM + all opts): fib30=69ms, map_filter=2.3ms

## 4. Babashka Comparison (post-24C.5, 2026-02-07)

Measured with hyperfine (CW) and single-run wall clock (BB), both cold start.
BB startup ~20ms, CW startup ~10ms.

| Benchmark             | CW ms  | BB ms | CW/BB  | CW MB     | BB MB  | CW wins? |
|-----------------------|--------|-------|--------|-----------|--------|----------|
| fib_recursive         | 23     | 34    | 0.7x   | 23.8      | 38.6   | BOTH     |
| fib_loop              | 12     | 20    | 0.6x   | 23.8      | 31.4   | BOTH     |
| tak                   | 14     | 24    | 0.6x   | 23.8      | 34.1   | BOTH     |
| arith_loop            | 57     | 80    | 0.7x   | 23.8      | 76.9   | BOTH     |
| map_filter_reduce     | 15     | 22    | 0.7x   | 25.7      | 37.7   | BOTH     |
| vector_ops            | 15     | 22    | 0.7x   | 26.0      | 34.6   | BOTH     |
| map_ops               | 13     | 20    | 0.7x   | 25.5      | 32.4   | BOTH     |
| list_build            | 13     | 21    | 0.6x   | 25.7      | 32.2   | BOTH     |
| keyword_lookup        | 20     | 26    | 0.8x   | 23.8      | 36.2   | BOTH     |
| protocol_dispatch     | 15     | 27    | 0.6x   | 23.8      | 36.4   | BOTH     |
| nqueens               | 22     | 30    | 0.7x   | 24.3      | 37.1   | BOTH     |
| atom_swap             | 13     | 19    | 0.7x   | 23.8      | 31.9   | BOTH     |
| lazy_chain            | 14     | 23    | 0.6x   | 23.8      | 37.6   | BOTH     |
| multimethod_dispatch  | 15     | 22    | 0.7x   | 23.9      | 33.5   | BOTH     |
| string_ops            | 28     | 28    | 1.0x   | 31.1      | 41.5   | BOTH     |
| real_workload         | 23     | 23    | 1.0x   | 33.2      | 41.6   | BOTH     |
| gc_stress             | 46     | 42    | 1.1x   | 25.2      | 77.0   | mem only |
| nested_update         | 41     | 22    | 1.9x   | 27.0      | 37.0   | mem only |
| sieve                 | 1665   | 22    | 75.7x  | 2997      | 36.2   | NEITHER  |
| transduce             | 2134   | 20    | 106.7x | 30657     | 32.3   | NEITHER  |

**Summary**: CW wins 18/20 (speed+memory or memory only), loses 2/20.
24C.5 fixed gc_stress (324→46ms, 7.0x), nested_update (124→41ms, 3.0x),
real_workload (50→23ms, 2.2x), transduce (3331→2134ms, 1.6x) via GC free-pool.
Remaining gaps: transduce (107x), sieve (76x), nested_update (1.9x), gc_stress (1.1x).

### Performance Categories (post-24C.5)

**Category A: CW wins speed+memory (16 benchmarks)**
fib_recursive, fib_loop, tak, arith_loop, map_filter_reduce, vector_ops,
map_ops, list_build, keyword_lookup, protocol_dispatch, nqueens, atom_swap,
lazy_chain, multimethod_dispatch, string_ops, real_workload

**Category B: CW loses speed, wins memory (2 benchmarks)**
nested_update (1.9x), gc_stress (1.1x)

**Category C: CW loses both (2 benchmarks)**
transduce (107x), sieve (76x)

### Memory Hotspots (post-24B, hyperfine measured)

| Benchmark          | Peak RSS    | Root cause                          |
|--------------------|-------------|-------------------------------------|
| lazy_chain         | 30,692 MB   | Intermediate lazy-seq allocations   |
| transduce          | 30,657 MB   | Same as lazy_chain                  |
| map_filter_reduce  | 15,367 MB   | Cons-list + lazy-seq overhead       |
| sieve              | 2,998 MB    | 168 nested filter chains            |
| multimethod_dispatch| 83.1 MB    | Dispatch table + var lookups        |
| real_workload      | 45.2 MB     | Mixed workload                      |

## 5. wasm_rt Considerations

### What's shared (common/ stays common)

- Value representation (NaN boxing layout) — same bit layout both targets
- Compiler → Bytecode — same opcode set
- Data structures (HAMT, PersistentVector) — pure algorithmic
- Fused reduce algorithm — same chain walk logic
- Builtin function semantics — map/filter/reduce/etc.

### What diverges (platform-specific)

- GC: native (mark-sweep/generational + mmap) vs wasm (WasmGC or linear memory)
- VM execution loop: different dispatch characteristics
- Stack management: native (OS stack 512MB) vs wasm (~1MB, needs F99 iterative)
- I/O: native (stdio) vs wasm (WASI)
- Memory allocator: native (page_allocator) vs wasm (WasmAllocator)

### NaN boxing on wasm

NaN boxing works on wasm32 — f64 bit manipulation is universal.
Actually MORE valuable on wasm because linear memory is limited.
Roadmap note in wasm_rt section claims "NaN boxing: No (Wasm JIT incompatible)"
but this is incorrect — NaN boxing IS compatible with wasm, it's just bit ops on f64.
The concern about JIT incompatibility applies to JVM's NaN boxing, not wasm.

### F99: Iterative lazy-seq realization

Wasm has ~1MB stack. Current realize→realizeMeta→seqFn mutual recursion
uses ~381KB/frame (Debug). Must convert to heap-based work stack before wasm_rt.
This is a portable optimization — benefits native too (removes 512MB stack hack).
