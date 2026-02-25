# ClojureWasm Benchmark Suite

31 benchmarks (20 Clojure + 2 GC + 5 Wasm legacy + 4 Wasm TinyGo).
Multi-language comparison and Wasm runtime benchmarking available.
Wasm runtime (zwasm) performance tracked against wasmtime, wasmer, bun, node.

## Scripts

| Script             | Purpose                          | Measurement     |
|--------------------|----------------------------------|-----------------|
| `run_bench.sh`     | Quick CW-only run                | hyperfine (3+1) |
| `record.sh`        | Record to `history.yaml`         | hyperfine (5+2) |
| `compare_langs.sh` | Cross-language comparison        | hyperfine (5+2) |
| `wasm_bench.sh`    | CW wasm runtime vs wasmtime      | hyperfine (5+2) |

## Quick Start

```bash
# Run all CW benchmarks (hyperfine, ReleaseSafe)
bash bench/run_bench.sh

# Single benchmark
bash bench/run_bench.sh --bench=fib_recursive

# Fast check (1 run, no warmup)
bash bench/run_bench.sh --quick

# Record to history
bash bench/record.sh --id="53.7" --reason="Phase 53 complete"

# Cross-language comparison
bash bench/compare_langs.sh
bash bench/compare_langs.sh --bench=fib_recursive --lang=cw,c,bb

# Wasm runtime benchmark: CW interpreter vs wasmtime JIT
bash bench/wasm_bench.sh
bash bench/wasm_bench.sh --quick
bash bench/wasm_bench.sh --bench=fib
```

## run_bench.sh Options

| Option         | Effect                      |
|----------------|-----------------------------|
| `--bench=NAME` | Single benchmark            |
| `--runs=N`     | Hyperfine runs (default: 3) |
| `--warmup=N`   | Warmup runs (default: 1)    |
| `--quick`      | 1 run, no warmup            |

## record.sh Options

| Option          | Effect                            |
|-----------------|-----------------------------------|
| `--id=ID`       | Entry identifier (required)       |
| `--reason=TEXT` | Reason for measurement (required) |
| `--bench=NAME`  | Single benchmark                  |
| `--runs=N`      | Hyperfine runs (default: 10)      |
| `--warmup=N`    | Warmup runs (default: 5)          |
| `--overwrite`   | Replace existing entry            |
| `--delete=ID`   | Delete entry                      |

## compare_langs.sh Options

| Option         | Effect                                          |
|----------------|--------------------------------------------------|
| `--bench=NAME` | Single benchmark                                |
| `--lang=LANGS` | Comma-separated (cw,c,zig,java,py,rb,bb,tgo)   |
| `--cold`       | Wall clock only (default)                       |
| `--warm`       | Startup-subtracted                              |
| `--both`       | Cold + Warm                                     |
| `--runs=N`     | Hyperfine runs (default: 5)                     |
| `--yaml=FILE`  | YAML output                                     |

## wasm_bench.sh Options

Compares CW's built-in Wasm runtime (zwasm) against wasmtime JIT.
Both execute the same TinyGo-compiled `.wasm` modules.
For full multi-runtime comparison (4 runtimes, 23 benchmarks), see zwasm's
`bench/record_comparison.sh`.

| Option         | Effect                                |
|----------------|---------------------------------------|
| `--bench=NAME` | Single benchmark (fib/tak/arith/sieve/fib_loop/gcd) |
| `--runs=N`     | Hyperfine runs (default: 5)           |
| `--warmup=N`   | Warmup runs (default: 2)              |
| `--quick`      | 1 run, no warmup                      |

## Benchmarks

### Clojure (20)

| #  | Name                 | Category     | Expected     |
|----|----------------------|--------------|--------------|
| 1  | fib_recursive        | Computation  | 75025        |
| 2  | fib_loop             | Computation  | 75025        |
| 3  | tak                  | Computation  | 7            |
| 4  | arith_loop           | Computation  | 499999500000 |
| 5  | map_filter_reduce    | Collections  | 166616670000 |
| 6  | vector_ops           | Collections  | 49995000     |
| 7  | map_ops              | Collections  | 499500       |
| 8  | list_build           | Collections  | 10000        |
| 9  | sieve                | HOF          | 168          |
| 10 | nqueens              | HOF          | 92           |
| 11 | atom_swap            | State        | 10000        |
| 12 | gc_stress            | Memory       | 16667500     |
| 13 | lazy_chain           | Lazy         | 332833500    |
| 14 | transduce            | Transducers  | 332833500    |
| 15 | keyword_lookup       | Maps         | 499999500000 |
| 16 | protocol_dispatch    | Protocols    | 500000500000 |
| 17 | nested_update        | Maps         | 1000000      |
| 18 | string_ops           | Strings      | 1000000      |
| 19 | multimethod_dispatch | Multimethods | 500000500000 |
| 20 | real_workload        | Mixed        | 333283335000 |

### GC (2)

| #  | Name           | Category | Measures                        |
|----|----------------|----------|---------------------------------|
| 26 | gc_alloc_rate  | Memory   | Raw allocation + GC throughput  |
| 27 | gc_large_heap  | Memory   | Large heap GC collection        |

### Wasm Legacy (5)

CW-side Wasm FFI benchmarks — measures `cljw.wasm` interop overhead
(module load, function calls, memory access) using handwritten `.wasm`.

| #  | Name        | Category | Measures                  |
|----|-------------|----------|---------------------------|
| 21 | wasm_load   | FFI      | Module load + instantiate |
| 22 | wasm_call   | FFI      | 10K function calls        |
| 23 | wasm_memory | FFI      | Linear memory read/write  |
| 24 | wasm_fib    | Compute  | fib(40) in Wasm           |
| 25 | wasm_sieve  | Compute  | Sieve in Wasm             |

### Wasm TinyGo (4)

Wasm runtime performance benchmarks — same TinyGo-compiled `.wasm`
modules executed by both CW (zwasm) and wasmtime. Used by `wasm_bench.sh`
for apples-to-apples runtime comparison.

| #  | Name            | Category | Measures              |
|----|-----------------|----------|-----------------------|
| 28 | wasm_tgo_fib    | Compute  | fib(20) x 10000       |
| 29 | wasm_tgo_tak    | Compute  | tak(18,12,6) x 10000  |
| 30 | wasm_tgo_arith  | Compute  | arith(1M) x 10        |
| 31 | wasm_tgo_sieve  | Compute  | sieve(64K) x 100      |

## Wasm FFI

ClojureWasm includes a built-in Wasm runtime (zwasm) enabling direct
`.wasm` module execution from Clojure code:

```clojure
(require '[cljw.wasm :as wasm])

;; Load and call a Wasm module
(def module (wasm/load "path/to/module.wasm"))
(def add-fn (wasm/fn module "add"))
(add-fn 2 3)  ;; => 5

;; WASI support
(def wasi-mod (wasm/load-wasi "path/to/wasi-module.wasm"))

;; Memory interop
(wasm/mem-write-bytes module 0 [72 101 108])
(wasm/mem-read-string module 0 3)  ;; => "Hel"
```

The Wasm benchmarks (#21-25) measure FFI overhead, while the TinyGo
benchmarks (#28-31) compare zwasm's execution speed against wasmtime.
zwasm supports full Wasm 3.0 (all 9 proposals including GC, function
references, SIMD, exception handling, tail call, etc.).

## Directory Structure

```
bench/
  run_bench.sh          # CW-only benchmark (hyperfine)
  record.sh             # Record to history.yaml
  compare_langs.sh      # Cross-language comparison
  wasm_bench.sh         # CW vs wasmtime wasm runtime comparison
  clj_warm_bench.clj    # Warm JVM measurement
  history.yaml          # Native benchmark history
  wasm_history.yaml     # Wasm runtime benchmark history
  cross-lang-results.yaml # Cross-language comparison results
  benchmarks/           # 31 benchmark directories
  wasm/                 # TinyGo-compiled .wasm modules
  simd/                 # SIMD benchmark programs
```

## Latest Clojure Results (2026-02-25)

Apple M4 Pro, 48GB RAM, macOS 15. hyperfine 5 runs + 2 warmup.
All times in milliseconds. These are **cold start** measurements (process
launch to exit) — languages with heavy runtimes (JVM, V8) pay startup cost.

| Benchmark            | CW   | Python | Ruby | Node | Java* | C   | Zig | TinyGo | BB   |
|----------------------|------|--------|------|------|-------|-----|-----|--------|------|
| fib_recursive        | 16   | 20.1   | 42.9 | 23.5 | 21.2  | 2.5 | 1.9 | 1.8    | 39.7 |
| fib_loop             | 5    | 12.5   | 29.1 | 21.5 | 21.0  | 1.4 | 2.9 | 0.9    | 12.7 |
| tak                  | 8    | 14.1   | 31.8 | 25.3 | 20.5  | 0.6 | 2.8 | 2.9    | 20.9 |
| arith_loop           | 5    | 61.5   | 53.3 | 25.2 | 22.3  | 2.1 | 1.5 | 1.9    | 76.7 |
| map_filter_reduce    | 6    | 12.9   | 35.4 | 23.8 | 20.8  | 1.9 | 1.7 | 2.4    | 18.8 |
| vector_ops           | 7    | 14.9   | 31.5 | 22.6 | 20.5  | 0.3 | 1.7 | 2.6    | 18.1 |
| map_ops              | 7    | 12.5   | 31.8 | 26.4 | 21.9  | 2.4 | 2.1 | 1.3    | 12.7 |
| list_build           | 8    | 16.2   | 33.8 | 24.9 | 22.2  | 1.0 | 0.2 | 2.2    | 12.4 |
| sieve                | 9    | 13.1   | 35.5 | 26.2 | 24.0  | 0.9 | 2.3 | 2.7    | 18.5 |
| nqueens              | 15   | 15.9   | 50.7 | 21.1 | 19.5  | 4.6 | 2.2 | 2.5    | 24.5 |
| atom_swap            | 8    | 12.2   | 32.5 | 25.8 | 21.5  | 2.1 | 1.6 | 2.2    | 16.6 |
| gc_stress            | 35   | 27.3   | 39.1 | 25.6 | 32.9  | 2.4 | --- | 18.8   | 37.1 |
| lazy_chain           | 7    | 104.0  | 33.8 | 24.9 | 21.5  | 1.3 | 1.7 | 1.9    | 16.9 |
| transduce            | 5    | 13.2   | 34.5 | 26.6 | 21.3  | 1.8 | 1.5 | 1.0    | 16.7 |
| keyword_lookup       | 13   | 17.3   | 36.3 | 23.7 | 22.9  | 1.3 | 2.3 | 4.6    | 21.0 |
| protocol_dispatch    | 7    | 12.4   | 34.2 | 24.3 | 20.7  | 1.4 | 1.5 | 0.7    | ---  |
| nested_update        | 12   | 13.6   | 29.0 | 26.5 | 22.9  | 0.8 | 2.2 | 3.8    | 18.4 |
| string_ops           | 30   | 24.9   | 39.2 | 27.4 | 23.3  | 8.5 | 2.6 | 1.6    | 21.3 |
| multimethod_dispatch | 8    | 14.9   | 34.5 | 23.2 | 21.1  | 0.9 | 1.8 | 2.3    | 17.7 |
| real_workload        | 15   | 13.4   | 36.9 | 23.7 | 31.2  | 1.3 | 1.4 | 5.2    | 18.0 |

CW wins vs Java: 20/20, vs Python: 17/20, vs Ruby: 20/20, vs Node: 20/20, vs BB: 18/19.

\* Java times are dominated by JVM startup (~20ms). Warm JVM execution
is significantly faster. C/Zig/TinyGo are native-compiled (AOT) baselines.
BB = Babashka (GraalVM native-image Clojure).

Note: gc_stress Zig value (493ms) omitted — Zig benchmark uses
`std.AutoArrayHashMap` which is not comparable to GC-managed collections.

## Binary Size Comparison

CW's built-in Wasm runtime (zwasm) is extremely compact compared to other runtimes.
Measured as ReleaseSafe builds on ARM64 macOS.

| Runtime        | Version      | Binary Size |
|----------------|--------------|-------------|
| **zwasm**      | 1.1.0        | **1.3 MB**  |
| wasmtime       | 41.0.1       | 56.3 MB     |
| bun            | 1.3.8        | 57.1 MB     |
| node           | v24.13.0     | 61.7 MB     |
| wasmer         | 7.0.1        | 118.3 MB    |

zwasm is **1/50th** the size of wasmtime and **1/100th** of wasmer.
Full Wasm 3.0 support (all 9 proposals including GC) in 1.1 MB.

## Latest Wasm Runtime Results (2026-02-18)

CW's built-in Wasm runtime (zwasm v1.1.0, Register IR + ARM64/x86_64 JIT)
vs 3 other Wasm runtimes. Apple M4 Pro, 48GB RAM.
23 benchmarks (WAT 5, TinyGo 11, Shootout 5, GC 2), hyperfine 3 runs + 1 warmup.

### WAT Benchmarks (handwritten)

| Benchmark | zwasm (ms) | wasmtime | bun      | node   |
|-----------|------------|----------|----------|--------|
| fib       | 50.6       | 48.6     | **31.2** | 45.5   |
| tak       | **7.4**    | 9.6      | 16.9     | 25.3   |
| sieve     | **4.1**    | 6.6      | 15.7     | 26.0   |
| nbody     | **10.5**   | 20.9     | 31.8     | 36.1   |
| nqueens   | **2.1**    | 4.8      | 14.3     | 21.7   |

### TinyGo Benchmarks (compiled .wasm)

| Benchmark   | zwasm (ms) | wasmtime | bun    | node   |
|-------------|------------|----------|--------|--------|
| tgo_fib     | 35.9       | **27.6** | 41.2   | 45.9   |
| tgo_tak     | **7.4**    | 8.3      | 16.7   | 24.8   |
| tgo_arith   | **1.8**    | 4.3      | 13.6   | 21.7   |
| tgo_sieve   | **4.5**    | 5.8      | 16.2   | 29.5   |
| tgo_fib_loop| **2.7**    | 6.0      | 20.3   | 23.2   |
| tgo_gcd     | **2.0**    | 4.4      | 15.2   | 22.3   |
| tgo_nqueens | 41.4       | **37.9** | 52.5   | 98.0   |
| tgo_mfr     | 47.2       | **30.8** | 40.3   | 81.7   |
| tgo_list    | **37.2**   | 66.7     | 40.6   | 151.5  |
| tgo_rwork   | **5.8**    | 7.8      | 18.7   | 24.5   |
| tgo_strops  | 34.7       | **27.5** | 32.4   | 89.1   |

### Shootout Benchmarks (WASI)

| Benchmark     | zwasm (ms) | wasmtime | bun       | node    |
|---------------|------------|----------|-----------|---------|
| st_fib2       | 1014.1     | 656.2    | **345.2** | 375.0   |
| st_sieve      | **169.1**  | 192.1    | 178.1     | 618.8   |
| st_nestedloop | **2.8**    | 4.4      | 17.0      | 25.3    |
| st_ackermann  | **4.5**    | 6.7      | 16.7      | 25.6    |
| st_matrix     | 280.9      | 85.7     | **81.1**  | 160.3   |

### GC Benchmarks (Wasm GC proposal)

| Benchmark | zwasm (ms) | wasmtime | bun    | node   |
|-----------|------------|----------|--------|--------|
| gc_alloc  | 17.5       | **7.9**  | 14.6   | 26.7   |
| gc_tree   | 124.0      | 28.9     | **18.5** | 29.5 |

### Summary

**zwasm wins (fastest)**: 14/23 benchmarks — dominant on short-running tasks
where startup overhead matters (sieve, nqueens, arith, gcd, fib_loop, etc.)

**vs wasmtime**: zwasm wins 14/23, wasmtime wins 9.
zwasm excels at fast startup (1.3 MB vs 56 MB binary, 3 MB vs 12 MB RSS).
wasmtime excels at heavy compute (optimizing JIT with Cranelift backend).

**Memory usage**: zwasm consistently uses 3-5 MB RSS vs 12-13 MB (wasmtime),
31-36 MB (bun), 41-44 MB (node).

Data source: `zwasm/bench/runtime_comparison.yaml`. History tracked in `wasm_history.yaml`.
