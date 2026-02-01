# Task 3.17: Benchmark — startup time, fib(30), basic operations

## Goal

Establish baseline performance numbers for ClojureWasm.

## Benchmarks

1. **Startup time**: `clj-wasm -e "nil"` — measures bootstrap overhead
2. **fib(30)**: `(defn fib [n] (if (<= n 1) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 30)`
3. **Arithmetic loop**: `(loop [i 0 s 0] (if (< i 1000000) (recur (inc i) (+ s i)) s))`
4. **Higher-order**: `(reduce + 0 (map inc (list 1 2 3 4 5 6 7 8 9 10)))`

## Plan

### Step 1: Create benchmark script

bash script using `time` or hyperfine (if available).

### Step 2: Run benchmarks and record results

### Step 3: Record in task log

## Results (TreeWalk backend, Debug build, Apple M1 Pro)

| Benchmark                    | Result       | Time (hyperfine) |
| ---------------------------- | ------------ | ---------------- |
| Startup (`-e "nil"`)         | nil          | 2.6ms ± 0.2ms    |
| fib(30)                      | 832040       | 3.24s ± 0.03s    |
| Arithmetic loop (1M)         | 499999500000 | ~1.3s            |
| Higher-order (map+reduce 10) | 65           | ~3ms             |

Notes:

- Startup includes core.clj parse + eval (all macros/fns), well under 10ms target
- fib(30) is pure TreeWalk (no VM compilation), recursive fn calls
- Arithmetic loop uses core.clj `inc` (function call overhead per iteration)
- Higher-order is small input, dominated by startup

## Log

- Ran benchmarks with `time` and `hyperfine`
- All results recorded above
