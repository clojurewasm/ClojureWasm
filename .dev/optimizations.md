# ClojureWasm Optimizations

Completed optimizations and future opportunities, ordered by introduction.

**Environment**: Apple M4 Pro, 48 GB RAM, Darwin 25.2.0, ReleaseSafe
**Measurement**: hyperfine (`bench/history.yaml`)
**Result**: CW wins cold 14/19 vs Babashka, NaN boxing (D85) live

---

## 1. Completed Optimizations

### Phase 3-23: Foundational

| # | Optimization                      | Phase | Key Impact                                |
|---|-----------------------------------|-------|-------------------------------------------|
| 1 | Arithmetic intrinsics             | 3     | Direct opcodes for +,-,*,/,<,>,= etc.    |
| 2 | BuiltinFn pointer dispatch        | 3     | No var resolution for core builtins       |
| 3 | Unified callFnVal dispatch (D36)  | 10    | Single dispatch point for all fn types    |
| 4 | VM heap allocation (D71)          | 22c   | Prevents C stack overflow in nested calls |
| 5 | Mark-Sweep GC (D69, D70)         | 23    | Three-allocator architecture              |

### Phase 24A: VM Core (Pre-24 → 24A.9)

| # | Task   | Optimization                        | Biggest Improvement              |
|---|--------|-------------------------------------|----------------------------------|
| 6 | 24A.1  | Switch dispatch + batched GC        | fib_loop 56→31ms (1.8x)         |
| 7 | 24A.2  | Stack arg buffer (TreeWalk)         | Avoids GC allocation per call    |
| 8 | 24A.3  | Fused reduce (lazy-seq collapse)    | sieve 2152→40ms (54x)           |
| 9 | 24A.4  | Arithmetic fast-path inlining       | fib_recursive 502→41ms (12x)    |
|10 | 24A.5  | Monomorphic inline cache            | protocol_dispatch 30→27ms       |
|11 | 24A.9  | @branchHint annotations             | fib_recursive 41→28ms (1.5x)    |

### Phase 24B: Data Structures

| # | Task   | Optimization                        | Biggest Improvement              |
|---|--------|-------------------------------------|----------------------------------|
|12 | 24B.2  | HAMT persistent hash map            | map_ops 26→14ms (1.9x)          |
|13 | 24B.4  | GC tuning + meta tracing            | Fixed F97 sieve crash            |

### Phase 24C: Babashka Parity (24A.9 → 24C.10)

| # | Task   | Optimization                        | Biggest Improvement              |
|---|--------|-------------------------------------|----------------------------------|
|14 | 24C.1  | Fix fused reduce (__zig-lazy-map)   | lazy_chain 6655→17ms (391x)     |
|15 | 24C.2  | Multimethod 2-level cache           | multimethod 2053→14ms (147x)    |
|16 | 24C.3  | String stack buffer fast path       | string_ops 398→28ms (14x)       |
|17 | 24C.4  | Vector geometric COW + Cons cells   | vector_ops 180→14ms (13x)       |
|18 | 24C.5  | GC free-pool recycling              | gc_stress 324→46ms (7x)         |
|19 | 24C.5b | Two-phase bootstrap (D73)           | transduce 2134→15ms (142x)      |
|20 | 24C.7  | Filter chain collapsing (D74)       | sieve 1645→16ms (103x)          |
|21 | 24C.9  | Zig builtins for update-in etc.     | nested_update 39→23ms (1.7x)    |
|22 | 24C.10 | Collection constructor intrinsics   | gc_stress 55→35ms (1.6x)        |

### Phase 35X: NaN Boxing (D85)

| # | Optimization                        | Impact                            |
|---|-------------------------------------|-----------------------------------|
|23 | 4-heap-tag NaN boxing               | Value 48→8 bytes, 6x cache        |
|   | 28 heap types, 48-bit address       | VM stack 1.5MB→256KB              |

### Phase 36.7: Wasm Interpreter (D86)

| # | Optimization                        | Impact                            |
|---|-------------------------------------|-----------------------------------|
|24 | VM reuse (stack cache)              | wasm_call 931→118ms (7.9x)        |
|25 | Sidetable (branch table)            | wasm_fib 11046→7663ms (1.44x)     |
|   | cached_memory + @memset             | DECIDED-AGAINST (ROI < 1%)        |

---

## 2. Performance Summary

### End-to-End Progression (Pre-24 → Current)

| Benchmark            | Pre-24  | 24C.10 | Current | Speedup      |
|----------------------|---------|--------|---------|--------------|
| fib_recursive        | 542     | 24     | 22      | **24.6x**    |
| map_filter_reduce    | 4,013   | 17     | 5       | **803x**     |
| sieve                | 2,152   | 16     | 4       | **538x**     |
| lazy_chain           | 21,375  | 16     | 5       | **4,275x**   |
| transduce            | 8,409   | 16     | 5       | **1,682x**   |
| multimethod_dispatch | 2,373   | 15     | 5       | **475x**     |
| real_workload        | 1,286   | 22     | 10      | **129x**     |

All times in ms (warm), ReleaseSafe, Apple M4 Pro. Current = 36.7 entry.
Full table: `bench/history.yaml`.

### Cross-Language Summary (Cold, Phase 24C.10)

CW vs Babashka (Cold): CW wins 14/19, BB wins 5/19, 1 skip.
CW vs Ruby: CW wins 20/20. CW vs Java: CW wins 18/20. CW vs Python: CW wins 11/20.

Startup: C 3.9 / Zig 5.8 / BB 8.0 / Py 11.1 / CW 14.2 / Java 21.2 / Ruby 30.1 ms.

Re-run with `bash bench/compare_langs.sh --both` for latest numbers.

---

## 3. Future Optimizations

### READY (can implement now)

| ID   | Technique                    | Expected Impact | Effort | Notes                      |
|------|------------------------------|-----------------|--------|----------------------------|
| F101 | into() transient optimization| 2-5x into       | LOW    | core.clj change only       |
| F102 | map/filter chunked processing| 2-4x map/filter | MEDIUM | chunk.zig infra exists     |
| —    | SmallString widening         | 5-10% string ops| LOW    | Inline strings > 7 bytes   |
| —    | String interning expansion   | Memory + compare| LOW    | Beyond keywords            |
| —    | LEB128 predecode (Wasm)      | 10-15% decode   | MEDIUM | Fixed-width IR from bytecode|

### DEFERRED (need JIT/GC infrastructure — Phase 37)

| ID   | Technique                    | Expected Impact | Effort | Notes                      |
|------|------------------------------|-----------------|--------|----------------------------|
| F103 | Escape analysis              | GC overhead     | HIGH   | Compiler detects local-only|
| F104 | Profile-guided IC extension  | 2x polymorphic  | MEDIUM | Beyond monomorphic IC      |
| F105 | JIT compilation              | 5-50x hot paths | HUGE   | Trace or method JIT        |
| —    | Register-based IR (Wasm)     | 1.5-3x all      | HIGH   | Major rewrite              |
| —    | Superinstructions (Wasm)     | 10-20% general  | MEDIUM | Bytecode fusion            |
| —    | Generational GC              | 2-5x allocation | HIGH   | Write barriers required    |
| —    | SmallVector (inline 2-3 elts)| Small vec alloc  | MEDIUM | NaN boxing extension       |
| —    | Closure stack allocation     | 1-2 capture     | MEDIUM | Avoid heap for small closures|

### LOW PRIORITY

| ID   | Technique                    | Notes                              |
|------|------------------------------|------------------------------------|
| F99  | Iterative lazy-seq realize   | D74 partial fix, general case left |
| F4   | HAMT persistent vectors      | Current ArrayMap sufficient        |
| F120 | Native SIMD (@Vector)        | Profile first before investing     |
| —    | Constant folding             | Low benchmark impact               |

### DECIDED-AGAINST

| Technique              | Reason                                                     |
|------------------------|------------------------------------------------------------|
| wasmtime-as-library    | +20MB binary, Rust dep. Keep custom runtime (2.9MB binary) |
| Tail-call dispatch     | Incompatible with cross-compile (D84 switch decision)      |
| RRB-Tree vectors       | Vectors rarely sliced in practice                          |
| cached_memory (Wasm)   | ROI < 1% in benchmarks                                     |

**Revisit condition** for wasmtime: if JIT proves too complex, consider
`--wasm-backend=wasmtime` build option.

---

## 4. Wasm Performance Baselines (Phase 36.7)

| Benchmark   | CW (ms) | Native equiv | Gap    | JIT Target |
|-------------|---------|--------------|--------|------------|
| wasm_call   | 118     | ~1ms         | ~100x  | ~5ms       |
| wasm_fib    | 7663    | ~500ms       | ~15x   | ~1s        |
| wasm_sieve  | 792     | ~30ms        | ~26x   | ~50ms      |
| wasm_memory | 26      | ~1ms         | ~26x   | ~2ms       |

JIT (Phase 37) target: bring Wasm gap to 2-5x of native.

---

## References

| Topic                  | Location                             |
|------------------------|--------------------------------------|
| Benchmark history      | `bench/history.yaml`                 |
| Cross-language script  | `bench/compare_langs.sh`             |
| D84 Custom Wasm        | `.dev/decisions.md`            |
| D85 NaN boxing         | `.dev/decisions.md`            |
| D86 Wasm optimization  | `.dev/decisions.md`            |
| Checklist items        | `.dev/checklist.md` (F99-F120)       |
