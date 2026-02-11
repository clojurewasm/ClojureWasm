# ClojureWasm Optimizations

Completed optimizations and future opportunities, ordered by introduction.

**Environment**: Apple M4 Pro, 48 GB RAM, Darwin 25.2.0, ReleaseSafe
**Measurement**: hyperfine (`bench/history.yaml`)
**Result**: CW wins cold 14/19 vs Babashka, NaN boxing (D85) live, zwasm (D92) integrated

---

## 1. Completed Optimizations

### Phase 3-23: Foundational

| # | Optimization                     | Phase | Key Impact                                |
|---|----------------------------------|-------|-------------------------------------------|
| 1 | Arithmetic intrinsics            | 3     | Direct opcodes for +,-,*,/,<,>,= etc.     |
| 2 | BuiltinFn pointer dispatch       | 3     | No var resolution for core builtins       |
| 3 | Unified callFnVal dispatch (D36) | 10    | Single dispatch point for all fn types    |
| 4 | VM heap allocation (D71)         | 22c   | Prevents C stack overflow in nested calls |
| 5 | Mark-Sweep GC (D69, D70)         | 23    | Three-allocator architecture              |

### Phase 24A: VM Core (Pre-24 → 24A.9)

| #  | Task  | Optimization                     | Biggest Improvement           |
|----|-------|----------------------------------|-------------------------------|
| 6  | 24A.1 | Switch dispatch + batched GC     | fib_loop 56→31ms (1.8x)       |
| 7  | 24A.2 | Stack arg buffer (TreeWalk)      | Avoids GC allocation per call |
| 8  | 24A.3 | Fused reduce (lazy-seq collapse) | sieve 2152→40ms (54x)         |
| 9  | 24A.4 | Arithmetic fast-path inlining    | fib_recursive 502→41ms (12x)  |
| 10 | 24A.5 | Monomorphic inline cache         | protocol_dispatch 30→27ms     |
| 11 | 24A.9 | @branchHint annotations          | fib_recursive 41→28ms (1.5x)  |

### Phase 24B: Data Structures

| #  | Task  | Optimization             | Biggest Improvement    |
|----|-------|--------------------------|------------------------|
| 12 | 24B.2 | HAMT persistent hash map | map_ops 26→14ms (1.9x) |
| 13 | 24B.4 | GC tuning + meta tracing | Fixed F97 sieve crash  |

### Phase 24C: Babashka Parity (24A.9 → 24C.10)

| #  | Task   | Optimization                      | Biggest Improvement          |
|----|--------|-----------------------------------|------------------------------|
| 14 | 24C.1  | Fix fused reduce (__zig-lazy-map) | lazy_chain 6655→17ms (391x)  |
| 15 | 24C.2  | Multimethod 2-level cache         | multimethod 2053→14ms (147x) |
| 16 | 24C.3  | String stack buffer fast path     | string_ops 398→28ms (14x)    |
| 17 | 24C.4  | Vector geometric COW + Cons cells | vector_ops 180→14ms (13x)    |
| 18 | 24C.5  | GC free-pool recycling            | gc_stress 324→46ms (7x)      |
| 19 | 24C.5b | Two-phase bootstrap (D73)         | transduce 2134→15ms (142x)   |
| 20 | 24C.7  | Filter chain collapsing (D74)     | sieve 1645→16ms (103x)       |
| 21 | 24C.9  | Zig builtins for update-in etc.   | nested_update 39→23ms (1.7x) |
| 22 | 24C.10 | Collection constructor intrinsics | gc_stress 55→35ms (1.6x)     |

### Phase 35X: NaN Boxing (D85)

| #  | Optimization                  | Impact                     |
|----|-------------------------------|----------------------------|
| 23 | 4-heap-tag NaN boxing         | Value 48→8 bytes, 6x cache |
|    | 28 heap types, 48-bit address | VM stack 1.5MB→256KB       |

### Phase 36.7: Wasm Interpreter (D86)

| #  | Optimization             | Impact                        |
|----|--------------------------|-------------------------------|
| 24 | VM reuse (stack cache)   | wasm_call 931→118ms (7.9x)    |
| 25 | Sidetable (branch table) | wasm_fib 11046→7663ms (1.44x) |
|    | cached_memory + @memset  | DECIDED-AGAINST (ROI < 1%)    |

### Phase 37.2-37.3: VM Superinstructions + Branch Fusion

| #  | Optimization                      | Impact                           |
|----|-----------------------------------|----------------------------------|
| 26 | Superinstructions (10 fused ops)  | arith_loop 53→40ms (1.33x)       |
| 27 | Compare-and-branch fusion (7 ops) | arith_loop 40→31ms (1.29x)       |
| 28 | Recur-loop fusion                 | Dispatch: 6→4 per loop iteration |
|    | Cumulative (37.1 base → 37.3)     | arith_loop 53→31ms (1.71x)       |

### Phase 37.4: JIT PoC — ARM64 Hot Loop Native Code (D87)

| #  | Optimization                    | Impact                           |
|----|---------------------------------|----------------------------------|
| 29 | ARM64 JIT (hot integer loops)   | arith_loop 31→3ms (10.3x)        |
|    | used_slots bitset (skip fn_val) | Avoids deopt on closure self-ref |
|    | THEN path skip in analyzeLoop   | Handles real compiler bytecode   |
|    | Cumulative (37.1 base → 37.4)   | arith_loop 53→3ms (17.7x)        |

---

## 2. Performance Summary

### End-to-End Progression (Pre-24 → Post-zwasm)

| Benchmark            | Pre-24 | 24C.10 | Post-zwasm | Speedup    |
|----------------------|--------|--------|------------|------------|
| fib_recursive        | 542    | 24     | 18         | **30x**    |
| map_filter_reduce    | 4,013  | 17     | 6          | **669x**   |
| sieve                | 2,152  | 16     | 6          | **359x**   |
| lazy_chain           | 21,375 | 16     | 9          | **2,375x** |
| transduce            | 8,409  | 16     | 6          | **1,402x** |
| multimethod_dispatch | 2,373  | 15     | 6          | **396x**   |
| real_workload        | 1,286  | 22     | 9          | **143x**   |

All times in ms (warm), ReleaseSafe, Apple M4 Pro. Post-zwasm = latest entry.
Full table: `bench/history.yaml`.

### Cross-Language Summary (Cold, Phase 24C.10)

CW vs Babashka (Cold): CW wins 14/19, BB wins 5/19, 1 skip.
CW vs Ruby: CW wins 20/20. CW vs Java: CW wins 18/20. CW vs Python: CW wins 11/20.

Startup: C 3.9 / Zig 5.8 / BB 8.0 / Py 11.1 / CW 14.2 / Java 21.2 / Ruby 30.1 ms.

Re-run with `bash bench/compare_langs.sh --both` for latest numbers.

---

## 3. Future Optimizations

### CW-side (can implement now)

| ID   | Technique                     | Expected Impact | Effort | Notes                             |
|------|-------------------------------|-----------------|--------|-----------------------------------|
| F102 | map/filter chunked processing | lazy-seq alloc  | MEDIUM | CW range is eager; deferred       |
| F103 | Escape analysis               | GC overhead     | HIGH   | Compiler detects local-only       |
| F104 | Profile-guided IC extension   | 2x polymorphic  | MEDIUM | Beyond monomorphic IC             |
| —    | Generational GC               | 2-5x allocation | HIGH   | Write barriers required           |
| —    | SmallVector (inline 2-3 elts) | Small vec alloc | MEDIUM | NaN boxing extension              |
| —    | Closure stack allocation      | 1-2 capture     | MEDIUM | Avoid heap for small closures     |

### Wasm-side (in zwasm repository)

| Technique                 | Expected Impact | Notes                                    |
|---------------------------|-----------------|------------------------------------------|
| Register-based IR         | 1.5-3x all      | Major rewrite of zwasm interpreter       |
| ARM64 JIT for Wasm        | 5-20x           | Reuse CW JIT PoC (D87) patterns         |
| Constant folding / DCE    | 5-10%           | Low ROI for current benchmarks           |

### LOW PRIORITY

| ID   | Technique                  | Notes                              |
|------|----------------------------|------------------------------------|
| F99  | Iterative lazy-seq realize | D74 partial fix, general case left |
| F4   | HAMT persistent vectors    | Current ArrayMap sufficient        |
| F120 | Native SIMD (@Vector)      | Profile first before investing     |

### DECIDED-AGAINST

| Technique            | Reason                                                     |
|----------------------|------------------------------------------------------------|
| wasmtime-as-library  | +20MB binary, Rust dep. Keep zwasm (small, controlled)     |
| Tail-call dispatch   | 0% improvement on Apple M4 (45.3 measured)                 |
| RRB-Tree vectors     | Vectors rarely sliced in practice                          |
| cached_memory (Wasm) | ROI < 1% in benchmarks                                     |
| SmallString widening | asString() returns []const u8 — lifetime problem           |
| String interning     | string_ops bottleneck is alloc, not comparison             |

### COMPLETED (Phase 36.11+37+45)

| Technique                         | Phase | Result                                  |
|-----------------------------------|-------|-----------------------------------------|
| F101 into() transient             | 36.11 | core.clj transient/persistent!          |
| F105 JIT compilation (PoC)        | 37.4  | ARM64 hot loops, arith_loop 17.7x      |
| Predecoded IR (Wasm)              | 45.2  | Fixed-width 8-byte instrs, 1.7-2.5x    |
| Superinstructions (Wasm)          | 45.4  | 11 fused opcodes, fib 1.3x             |
| Cached memory pointer (Wasm)      | 45.5  | Marginal (~3% on sieve)                |

---

## 4. Wasm Performance (Post-zwasm v0.1.0, Register IR + ARM64 JIT)

| Benchmark          | CW warm (ms) | wasmtime (ms) | Ratio | vs Phase 45 |
|--------------------|--------------|---------------|-------|-------------|
| fib(20)x10K        | 641          | 211           | 3.0x  | **6.8x**    |
| tak(18,12,6)x10K   | 2,786        | 1,174         | 2.4x  | **5.1x**    |
| arith(1M)x10       | 0.8          | 0.1           | 8.0x  | —           |
| sieve(64K)x100     | 21           | 4.8           | 4.4x  | **9.4x**    |
| fib_loop(25)x1M    | 22           | 2.2           | 10.0x | **8.0x**    |
| gcd(1M,700K)x1M    | 54           | 41            | 1.3x  | **5.8x**    |

CW startup (4.1ms) < wasmtime startup (5.5ms).
zwasm Register IR + ARM64 JIT brings most benchmarks within 3-10x of wasmtime.
gcd achieves near-parity (1.3x). Call-heavy workloads (fib, tak) at 2.4-3.0x.
Full history: `bench/wasm_history.yaml`.

---

## References

| Topic                 | Location                       |
|-----------------------|--------------------------------|
| Benchmark history     | `bench/history.yaml`           |
| Wasm bench history    | `bench/wasm_history.yaml`      |
| Cross-language script | `bench/compare_langs.sh`       |
| Cross-language results| `bench/cross-lang-results.yaml`|
| D85 NaN boxing        | `.dev/decisions.md`            |
| D87 JIT PoC           | `.dev/decisions.md`            |
| D92 zwasm integration | `.dev/decisions.md`            |
| Checklist items       | `.dev/checklist.md`            |
| zwasm repository      | `../zwasm/` or GitHub          |
