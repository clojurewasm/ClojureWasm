# ClojureWasm Benchmark Suite

11 benchmarks across 5 categories, comparing ClojureWasm against C, Zig, Java, Python, Ruby, Clojure JVM, and Babashka.

## Quick Start

```bash
# ClojureWasm only (all benchmarks)
bash bench/run_bench.sh

# All languages
bash bench/run_bench.sh --all

# Specific benchmark
bash bench/run_bench.sh --bench=fib_recursive

# Specific language
bash bench/run_bench.sh --lang=python

# High-precision with hyperfine (recommended)
bash bench/run_bench.sh --bench=fib_recursive --hyperfine

# Record to bench.yaml
bash bench/run_bench.sh --all --record --version="Phase 5 baseline"

# ReleaseFast build
bash bench/run_bench.sh --release
```

## Options

| Option             | Effect                                |
| ------------------ | ------------------------------------- |
| (none)             | ClojureWasm only, all benchmarks      |
| `--all`            | All languages                         |
| `--lang=LANG`      | Specific language only                |
| `--bench=NAME`     | Specific benchmark only               |
| `--record`         | Append to bench.yaml                  |
| `--version="NAME"` | Version label for record              |
| `--hyperfine`      | High-precision measurement            |
| `--backend=vm`     | Use VM backend (default: TreeWalk)    |
| `--release`        | Build with ReleaseFast before running |

## Benchmarks

### Computation (4)

| #   | Name          | Description       | Expected     |
| --- | ------------- | ----------------- | ------------ |
| 1   | fib_recursive | Naive fib(25)     | 75025        |
| 2   | fib_loop      | Iterative fib(25) | 75025        |
| 3   | tak           | Takeuchi(18,12,6) | 7            |
| 4   | arith_loop    | Sum 0..999999     | 499999500000 |

### Collections (4)

| #   | Name              | Description        | Expected     |
| --- | ----------------- | ------------------ | ------------ |
| 5   | map_filter_reduce | HOF chain (10K)    | 166616670000 |
| 6   | vector_ops        | conj + nth (10K)   | 49995000     |
| 7   | map_ops           | assoc + get (1K)   | 499500       |
| 8   | list_build        | cons + count (10K) | 10000        |

### HOF / Functional Patterns (2)

| #   | Name    | Description       | Expected |
| --- | ------- | ----------------- | -------- |
| 9   | sieve   | Eratosthenes (1K) | 168      |
| 10  | nqueens | N-Queens (N=8)    | 92       |

### State (1)

| #   | Name      | Description        | Expected |
| --- | --------- | ------------------ | -------- |
| 11  | atom_swap | reset!/deref (10K) | 10000    |

### Removed benchmarks

- **ackermann**: Stack depth limit in ClojureWasm makes fair comparison impossible
- **str_concat**: Fixed 4KB string buffer in `str` builtin limits scale

## Design Notes

- Parameters sized so each ClojureWasm run completes in 10ms-1s (ideal for hyperfine)
- `.clj` files shared between ClojureWasm, Clojure JVM, and Babashka
- `range` not available in ClojureWasm, so all Clojure benchmarks use loop/recur
- `empty?` not available, use `(nil? (seq ...))` instead

## Languages

| Language    | How                           |
| ----------- | ----------------------------- |
| ClojureWasm | `zig build` + `clj-wasm`      |
| C           | `cc -O3`                      |
| Zig         | `zig build-exe -OReleaseFast` |
| Java        | `javac` + `java` (JDK 25)     |
| Python      | `python3` (3.14)              |
| Ruby        | `ruby` (4.0)                  |
| Clojure JVM | `clojure -M` (cold start)     |
| Babashka    | `bb` (SCI interpreter)        |

## Warm JVM Benchmark

For JIT-warmed Clojure measurements:

```bash
clojure -M bench/clj_warm_bench.clj bench/benchmarks/01_fib_recursive/bench.clj
```

## Directory Structure

```
bench/
  run_bench.sh              # Main benchmark script
  clj_warm_bench.clj        # Warm JVM measurement
  README.md                 # This file
  lib/
    common.sh               # Shared functions
  benchmarks/
    01_fib_recursive/
      bench.clj             # ClojureWasm / Clojure / Babashka
      bench.c               # C version
      bench.zig             # Zig version
      Bench.java            # Java version
      bench.py              # Python version
      bench.rb              # Ruby version
      meta.yaml             # Metadata
    ...
```
