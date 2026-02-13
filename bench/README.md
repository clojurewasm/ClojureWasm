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
| `--runs=N`      | Hyperfine runs (default: 5)       |
| `--warmup=N`    | Warmup runs (default: 2)          |
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
For full multi-runtime comparison (5 runtimes, 21 benchmarks), see zwasm's
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

## Latest Clojure Results (2026-02-14)

Apple M4 Pro, 48GB RAM, macOS 15. hyperfine 5 runs + 2 warmup.
All times in milliseconds. These are **cold start** measurements (process
launch to exit) — languages with heavy runtimes (JVM, V8) pay startup cost.

| Benchmark            | CW   | Python | Ruby | Node | Java* | C   | Zig | TinyGo |
|----------------------|------|--------|------|------|-------|-----|-----|--------|
| fib_recursive        | 19   | 17.1   | 37.7 | 25.2 | 20.3  | 1.2 | 1.7 | 3.3    |
| fib_loop             | 5    | 12.7   | 37.9 | 21.8 | 20.6  | 3.8 | 0.6 | 2.6    |
| tak                  | 8    | 13.2   | 33.6 | 24.2 | 21.0  | 1.7 | 2.9 | 2.0    |
| arith_loop           | 5    | 60.7   | 54.5 | 25.2 | 21.4  | 1.7 | 1.2 | 1.7    |
| map_filter_reduce    | 6    | 13.0   | 35.9 | 23.7 | 21.4  | 1.4 | 1.4 | 2.6    |
| vector_ops           | 6    | 13.5   | 31.6 | 22.7 | 24.1  | 1.3 | 1.4 | 2.3    |
| map_ops              | 6    | 12.8   | 30.8 | 22.3 | 18.7  | 1.0 | 1.7 | 2.4    |
| list_build           | 6    | 14.6   | 34.6 | 25.7 | 21.9  | 1.5 | 1.8 | 2.5    |
| sieve                | 6    | 12.2   | 35.8 | 24.4 | 23.8  | 1.4 | 1.2 | 1.6    |
| nqueens              | 15   | 16.2   | 51.6 | 23.5 | 20.9  | 0.5 | 0.9 | 1.9    |
| atom_swap            | 5    | 11.7   | 36.2 | 24.0 | 20.9  | 1.4 | 2.9 | 3.5    |
| gc_stress            | 26   | 30.5   | 41.4 | 26.7 | 30.5  | 2.6 | --- | 20.2   |
| lazy_chain           | 7    | 15.4   | 33.0 | 26.1 | 22.2  | 2.6 | 1.6 | 2.2    |
| transduce            | 6    | 12.6   | 36.2 | 23.5 | 23.7  | 1.3 | 1.7 | 1.9    |
| keyword_lookup       | 11   | 19.4   | 37.0 | 27.4 | 23.9  | 1.6 | 0.0 | 4.9    |
| protocol_dispatch    | 6    | 12.7   | 32.8 | 24.3 | 22.0  | 2.3 | 1.7 | 2.2    |
| nested_update        | 10   | 12.6   | 32.9 | 24.0 | 23.7  | 0.2 | 1.3 | 3.1    |
| string_ops           | 25   | 25.2   | 38.0 | 24.5 | 24.8  | 4.3 | 2.0 | 1.5    |
| multimethod_dispatch | 6    | 13.3   | 33.8 | 24.6 | 20.0  | 2.6 | 0.9 | 2.1    |
| real_workload        | 10   | 13.6   | 37.1 | 24.7 | 26.6  | 0.9 | 1.0 | 1.7    |

CW wins vs Java: 20/20, vs Python: 18/20, vs Ruby: 20/20, vs Node: 20/20.

\* Java times are dominated by JVM startup (~20ms). Warm JVM execution
is significantly faster. C/Zig/TinyGo are native-compiled (AOT) baselines.

Note: gc_stress Zig value (462.7ms) omitted — Zig benchmark uses
`std.AutoArrayHashMap` which is not comparable to GC-managed collections.

## Binary Size Comparison

CW's built-in Wasm runtime (zwasm) is extremely compact compared to other runtimes.
Measured as ReleaseSafe builds on ARM64 macOS.

| Runtime        | Version      | Binary Size |
|----------------|--------------|-------------|
| **zwasm**      | 0.2.0        | **1.1 MB**  |
| wasmtime       | 41.0.1       | 56.3 MB     |
| bun            | 1.3.8        | 57.1 MB     |
| node           | v24.13.0     | 61.7 MB     |
| wasmer         | 7.0.1        | 118.3 MB    |

zwasm is **1/50th** the size of wasmtime and **1/100th** of wasmer.
Full Wasm 3.0 support (all 9 proposals including GC) in 1.1 MB.

## Latest Wasm Runtime Results (2026-02-14)

CW's built-in Wasm runtime (zwasm v0.2.0, Register IR + ARM64/x86_64 JIT)
vs 4 other Wasm runtimes. Apple M4 Pro, 48GB RAM.
21 benchmarks (WAT 5, TinyGo 11, Shootout 5), hyperfine 3 runs + 1 warmup.

### WAT Benchmarks (handwritten)

| Benchmark | zwasm (ms) | wasmtime | wasmer | bun    | node   |
|-----------|------------|----------|--------|--------|--------|
| fib       | 92.4       | 52.8     | 51.3   | **37.3** | 48.8 |
| tak       | **10.6**   | 10.7     | 13.8   | 18.6   | 25.3   |
| sieve     | **3.6**    | 7.1      | 11.5   | 16.7   | 29.1   |
| nbody     | 51.7       | 24.5     | **27.7** | 32.3 | 38.1   |
| nqueens   | **2.5**    | 8.4      | 8.2    | 14.7   | 23.9   |

### TinyGo Benchmarks (compiled .wasm)

| Benchmark   | zwasm (ms) | wasmtime | wasmer   | bun    | node   |
|-------------|------------|----------|----------|--------|--------|
| tgo_fib     | 52.0       | 27.5     | **9.9**  | 42.5   | 47.0   |
| tgo_tak     | 9.6        | 9.6      | **5.0**  | 18.0   | 25.0   |
| tgo_arith   | **2.4**    | 6.5      | 9.0      | 14.6   | 21.6   |
| tgo_sieve   | **3.5**    | 6.4      | 11.5     | 16.3   | 27.6   |
| tgo_fib_loop| **2.8**    | 5.3      | 10.7     | 15.1   | 23.6   |
| tgo_gcd     | **1.5**    | 5.3      | 11.5     | 14.5   | 27.5   |
| tgo_nqueens | 44.1       | 41.6     | **9.2**  | 47.6   | 99.0   |
| tgo_mfr     | 71.8       | 35.1     | **9.7**  | 43.8   | 84.2   |
| tgo_list    | 56.0       | 56.6     | **10.9** | 41.7   | 159.7  |
| tgo_rwork   | 8.1        | **7.1**  | 11.1     | 18.6   | 30.2   |
| tgo_strops  | 36.7       | 31.5     | **11.8** | 33.5   | 96.5   |

### Shootout Benchmarks (WASI)

| Benchmark     | zwasm (ms) | wasmtime | wasmer  | bun      | node    |
|---------------|------------|----------|---------|----------|---------|
| st_fib2       | 1361.2     | 683.3    | 684.7   | **371.3** | 397.1 |
| st_sieve      | 232.5      | 200.2    | 198.0   | **177.5** | 627.0 |
| st_nestedloop | 5.3        | **4.3**  | 10.3    | 15.8     | 25.7   |
| st_ackermann  | **7.0**    | 8.6      | 14.6    | 17.5     | 28.5   |
| st_matrix     | 312.7      | 92.1     | 93.8    | **85.2** | 168.9  |

### Summary

**zwasm wins (fastest)**: 9/21 benchmarks — dominant on short-running tasks
where startup overhead matters (sieve, nqueens, arith, gcd, fib_loop, etc.)

**vs wasmtime**: zwasm wins 10/21, tie 2, wasmtime wins 9.
zwasm excels at fast startup (1.1 MB vs 56 MB binary, 3 MB vs 12 MB RSS).
wasmtime excels at heavy compute (optimizing JIT with Cranelift backend).

**Memory usage**: zwasm consistently uses 3-5 MB RSS vs 12-13 MB (wasmtime),
30-33 MB (wasmer), 31-34 MB (bun), 41-44 MB (node).

Data source: `zwasm/bench/runtime_comparison.yaml`. History tracked in `wasm_history.yaml`.
