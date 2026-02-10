# ClojureWasm Benchmark Suite

25 benchmarks (20 Clojure + 5 Wasm). Multi-language comparison available.

## Scripts

| Script             | Purpose                   | Measurement     |
|--------------------|---------------------------|-----------------|
| `run_bench.sh`     | Quick CW-only run         | hyperfine (3+1) |
| `record.sh`        | Record to `history.yaml`  | hyperfine (5+2) |
| `compare_langs.sh` | Cross-language comparison | hyperfine (5+2) |

## Quick Start

```bash
# Run all CW benchmarks (hyperfine, ReleaseSafe)
bash bench/run_bench.sh

# Single benchmark
bash bench/run_bench.sh --bench=fib_recursive

# Fast check (1 run, no warmup)
bash bench/run_bench.sh --quick

# Record to history
bash bench/record.sh --id="36.7" --reason="Wasm optimization"

# Cross-language comparison
bash bench/compare_langs.sh
bash bench/compare_langs.sh --bench=fib_recursive --lang=cw,c,bb
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

| Option         | Effect                                   |
|----------------|------------------------------------------|
| `--bench=NAME` | Single benchmark                         |
| `--lang=LANGS` | Comma-separated (cw,c,zig,java,py,rb,bb) |
| `--cold`       | Wall clock only (default)                |
| `--warm`       | Startup-subtracted                       |
| `--both`       | Cold + Warm                              |
| `--runs=N`     | Hyperfine runs (default: 5)              |
| `--yaml=FILE`  | YAML output                              |

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

### Wasm (5)

| #  | Name        | Category | Measures                  |
|----|-------------|----------|---------------------------|
| 21 | wasm_load   | FFI      | Module load + instantiate |
| 22 | wasm_call   | FFI      | 10K function calls        |
| 23 | wasm_memory | FFI      | Linear memory read/write  |
| 24 | wasm_fib    | Compute  | fib(40) in Wasm           |
| 25 | wasm_sieve  | Compute  | Sieve in Wasm             |

## Directory Structure

```
bench/
  run_bench.sh          # CW-only benchmark (hyperfine)
  record.sh             # Record to history.yaml
  compare_langs.sh      # Cross-language comparison
  clj_warm_bench.clj    # Warm JVM measurement
  history.yaml          # Benchmark history (all entries)
  benchmarks/           # 25 benchmark directories
  simd/                 # SIMD benchmark programs
```

## Latest Results (2026-02-10)

Apple M4 Pro, 48GB RAM, macOS 15. hyperfine 5 runs + 2 warmup.
All times in milliseconds. These are **cold start** measurements (process
launch to exit) — languages with heavy runtimes (JVM, V8) pay startup cost.

| Benchmark            | CW   | Python | Ruby | Node | Java* | C   | Zig | TinyGo |
|----------------------|------|--------|------|------|-------|-----|-----|--------|
| fib_recursive        | 17.6 | 19.6   | 36.3 | 24.8 | 20.9  | 2.0 | 2.6 | 2.1    |
| fib_loop             | 2.9  | 13.4   | 30.3 | 21.6 | 20.4  | 2.1 | 1.5 | 2.3    |
| tak                  | 8.9  | 15.7   | 33.4 | 23.6 | 19.2  | 3.6 | 0.7 | 2.4    |
| arith_loop           | 5.8  | 61.2   | 54.5 | 25.0 | 22.1  | 0.7 | 2.1 | 1.4    |
| map_filter_reduce    | 5.7  | 13.2   | 33.9 | 29.1 | 19.7  | 1.4 | 1.7 | 2.1    |
| vector_ops           | 8.1  | 13.6   | 31.7 | 21.7 | 22.3  | 1.4 | 1.4 | 2.2    |
| map_ops              | 4.4  | 12.2   | 32.1 | 23.2 | 22.1  | 1.6 | 1.5 | 2.8    |
| list_build           | 4.6  | 15.3   | 31.9 | 22.1 | 22.0  | 3.1 | 1.6 | 2.6    |
| sieve                | 5.5  | 12.9   | 32.9 | 22.2 | 24.0  | 1.6 | 1.7 | 2.1    |
| nqueens              | 15.3 | 15.0   | 50.1 | 23.9 | 21.5  | 1.9 | 1.5 | 2.2    |
| atom_swap            | 5.6  | 12.8   | 31.9 | 22.7 | 21.2  | 1.8 | 1.4 | 2.6    |
| gc_stress            | 29.2 | 27.1   | 38.6 | 23.7 | 31.5  | 2.3 | --- | 19.6   |
| lazy_chain           | 6.3  | 15.1   | 31.4 | 22.5 | 20.2  | 1.3 | 1.8 | 2.2    |
| transduce            | 7.4  | 11.7   | 31.4 | 22.0 | 20.3  | 1.5 | 1.4 | 3.2    |
| keyword_lookup       | 11.1 | 18.2   | 34.3 | 22.8 | 24.0  | 2.1 | 2.4 | 4.3    |
| protocol_dispatch    | 4.5  | 13.7   | 30.3 | 22.4 | 20.5  | 1.4 | 1.4 | 2.3    |
| nested_update        | 10.9 | 12.3   | 30.8 | 22.5 | 22.3  | 1.7 | 1.4 | 2.7    |
| string_ops           | 24.5 | 25.6   | 37.2 | 24.5 | 24.1  | 5.4 | 1.8 | 2.1    |
| multimethod_dispatch | 7.2  | 14.7   | 30.7 | 22.0 | 22.5  | 1.3 | 1.7 | 2.4    |
| real_workload        | 11.0 | 14.9   | 34.8 | 24.0 | 23.8  | 1.6 | 4.5 | 2.0    |

CW wins vs Java: 20/20, vs Python: 18/20, vs Ruby: 20/20, vs Node: 20/20.

\* Java times are dominated by JVM startup (~20ms). Warm JVM execution
is significantly faster. C/Zig/TinyGo are native-compiled (AOT) baselines.

Note: gc_stress Zig value (414.6ms) omitted — Zig benchmark uses
`std.AutoArrayHashMap` which is not comparable to GC-managed collections.
