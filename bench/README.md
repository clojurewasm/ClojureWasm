# ClojureWasm Benchmark Suite

25 benchmarks (20 Clojure + 5 Wasm). Multi-language comparison available.

## Scripts

| Script             | Purpose                           | Measurement      |
|--------------------|-----------------------------------|-------------------|
| `run_bench.sh`     | Quick CW-only run                 | hyperfine (3+1)   |
| `record.sh`        | Record to `history.yaml`          | hyperfine (5+2)   |
| `compare_langs.sh` | Cross-language comparison         | hyperfine (5+2)   |

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

| Option         | Effect                              |
|----------------|-------------------------------------|
| `--bench=NAME` | Single benchmark                    |
| `--runs=N`     | Hyperfine runs (default: 3)         |
| `--warmup=N`   | Warmup runs (default: 1)            |
| `--quick`      | 1 run, no warmup                    |

## record.sh Options

| Option         | Effect                              |
|----------------|-------------------------------------|
| `--id=ID`      | Entry identifier (required)         |
| `--reason=TEXT` | Reason for measurement (required)  |
| `--bench=NAME` | Single benchmark                    |
| `--runs=N`     | Hyperfine runs (default: 5)         |
| `--warmup=N`   | Warmup runs (default: 2)            |
| `--overwrite`  | Replace existing entry              |
| `--delete=ID`  | Delete entry                        |

## compare_langs.sh Options

| Option         | Effect                              |
|----------------|-------------------------------------|
| `--bench=NAME` | Single benchmark                    |
| `--lang=LANGS` | Comma-separated (cw,c,zig,java,py,rb,bb) |
| `--cold`       | Wall clock only (default)           |
| `--warm`       | Startup-subtracted                  |
| `--both`       | Cold + Warm                         |
| `--runs=N`     | Hyperfine runs (default: 5)         |
| `--yaml=FILE`  | YAML output                         |

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

| #  | Name        | Category  | Measures                  |
|----|-------------|-----------|---------------------------|
| 21 | wasm_load   | FFI       | Module load + instantiate |
| 22 | wasm_call   | FFI       | 10K function calls        |
| 23 | wasm_memory | FFI       | Linear memory read/write  |
| 24 | wasm_fib    | Compute   | fib(40) in Wasm           |
| 25 | wasm_sieve  | Compute   | Sieve in Wasm             |

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
