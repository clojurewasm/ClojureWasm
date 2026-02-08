# Optimization Roadmap

Future optimization opportunities, organized by category. Updated Phase 36.7.

## Status Legend

- **DONE**: Implemented and measured
- **READY**: Dependencies met, can implement now
- **DEFERRED**: Waiting on prerequisite phase
- **DECIDED-AGAINST**: Evaluated and rejected (with reason)

---

## 1. Wasm Interpreter (Phase 36.7 completed, Phase 37 JIT)

### Done (Phase 36.7, D86)

| Technique               | Result   | Commit  |
|--------------------------|----------|---------|
| VM reuse (stack cache)   | 7.9x call | 65c4679 |
| Sidetable (branch table) | 1.44x fib | e077ba5 |
| cached_memory + @memset  | DECIDED-AGAINST (ROI < 1%) | — |

### JIT-Only (Phase 37)

These require code generation and are not feasible in the interpreter.

| Technique              | Expected impact | Complexity |
|------------------------|-----------------|------------|
| Register-based IR      | 1.5-3x all      | HIGH       |
| Superinstructions      | 10-20% general  | MEDIUM     |
| Tail-call dispatch     | 15-25% general  | LOW (native only, violates D84) |
| Loop JIT (hot loops)   | 10-50x compute  | HIGH       |
| Cranelift integration  | ~wasmtime parity | HUGE      |

### Remaining Interpreter (READY, low priority)

| Technique              | Expected impact | Complexity | Notes |
|------------------------|-----------------|------------|-------|
| LEB128 predecode       | 10-15% decode   | MEDIUM     | Fixed-width IR from bytecode |
| Function table direct  | 5% call_indirect | LOW       | Pointer instead of index lookup |

### wasmtime-as-library (DECIDED-AGAINST for now)

**Decision**: Keep custom Wasm runtime. wasmtime adds ~20MB binary size
and Rust build dependency. Custom runtime gives:
- 2.9MB single binary (vs ~23MB with wasmtime)
- NaN boxing Value direct integration (no marshalling)
- ClojureWasm-specific optimizations possible
- Full control, no upstream dependency

**Revisit condition**: If JIT in Phase 37 proves too complex, reconsider
wasmtime-c-api as a `--wasm-backend=wasmtime` build option.

---

## 2. GC Improvements (Phase 37)

Current: MarkSweepGc (Phase 23, D69/D70). Works but not optimized.

| Technique              | Expected impact | Complexity | Status |
|------------------------|-----------------|------------|--------|
| Generational GC        | 2-5x allocation | HIGH       | DEFERRED (Phase 37) |
| Write barriers         | Required for gen GC | MEDIUM  | DEFERRED |
| Nursery sizing         | Reduced pause   | LOW        | DEFERRED |
| Escape analysis (F103) | Skip GC for locals | HIGH    | DEFERRED |
| Concurrent marking     | Reduced pause   | VERY HIGH  | DEFERRED (Phase 37+) |

**Note**: F113 (nREPL GC) is a separate issue — nREPL uses GPA without
GC, so transient Values accumulate. Fix: integrate MarkSweepGc into nREPL.

---

## 3. ClojureWasm Runtime Optimizations

### READY (can implement now)

| ID   | Technique                    | Expected impact | Effort | Notes |
|------|------------------------------|-----------------|--------|-------|
| F101 | into() transient optimization | 2-5x into      | LOW    | core.clj change only |
| F102 | map/filter chunked processing | 2-4x map/filter | MEDIUM | chunk.zig exists |
| —    | SmallString widening         | 5-10% string ops | LOW   | Inline strings > 7 bytes |
| —    | String interning expansion   | Memory + compare | LOW   | Beyond keywords |

### DEFERRED (need Phase 37 infrastructure)

| ID   | Technique                    | Expected impact | Effort | Notes |
|------|------------------------------|-----------------|--------|-------|
| F103 | Escape analysis              | GC overhead     | HIGH   | Compiler detects local-only Values |
| F104 | Profile-guided IC extension  | 2x polymorphic  | MEDIUM | Beyond monomorphic inline cache |
| F105 | JIT compilation              | 5-50x hot paths | HUGE   | Trace or method JIT |
| —    | SmallVector (inline 2-3 elts)| Small vec alloc  | MEDIUM | NaN boxing extension |
| —    | Closure stack allocation     | 1-2 capture     | MEDIUM | Avoid heap for small closures |

### Low Priority

| ID    | Technique                  | Notes |
|-------|----------------------------|-------|
| 24C.8 | Constant folding           | Low benchmark impact |
| F98   | ReleaseFast anomaly        | Investigation only |
| F99   | Iterative lazy-seq realize | D74 partial fix, general case remains |
| F4    | HAMT persistent maps       | Current ArrayMap sufficient for typical sizes |

---

## 4. Build & Distribution

| Technique              | Impact           | Status |
|------------------------|------------------|--------|
| LTO (link-time opt)    | 5-10% binary size | Investigate |
| Strip debug symbols    | Smaller release  | Available via -Dstrip |
| UPX compression        | 2-3x smaller     | Trade-off: slower startup |

---

## 5. Benchmark Baselines (Phase 36.7)

Reference: `bench/history.yaml` entry "36.7"

### Clojure benchmarks (top 5 by time)

| Benchmark    | Time (ms) | Notes                |
|--------------|-----------|----------------------|
| arith_loop   | 58        | Arithmetic hot path  |
| gc_stress    | 30        | GC throughput        |
| string_ops   | 28        | String manipulation  |
| fib_recursive| 22        | Function call        |
| nqueens      | 17        | Collection + recursion |

### Wasm benchmarks

| Benchmark   | Time (ms) | Native equiv | Gap    |
|-------------|-----------|--------------|--------|
| wasm_call   | 118       | ~1ms         | ~100x  |
| wasm_fib    | 7663      | ~500ms       | ~15x   |
| wasm_sieve  | 792       | ~30ms        | ~26x   |
| wasm_memory | 26        | ~1ms         | ~26x   |
| wasm_load   | 7         | N/A          | —      |

JIT (Phase 37) target: bring Wasm gap to 2-5x of native.

---

## References

| Topic                  | Location                                    |
|------------------------|---------------------------------------------|
| Phase 36.7 decision    | `.dev/notes/decisions.md` D86               |
| Phase 24 optimization  | `.dev/notes/optimization-catalog.md`         |
| Benchmark history      | `bench/history.yaml`                         |
| Checklist items        | `.dev/checklist.md` (F98-F120)               |
| Wasm runtime design    | `.dev/notes/decisions.md` D84                |
| NaN boxing design      | `.dev/notes/decisions.md` D85                |
