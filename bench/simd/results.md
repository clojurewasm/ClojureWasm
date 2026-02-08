# SIMD Benchmark Results

## Baseline (Phase 35.5, interpreter-only)

Date: 2026-02-08
CPU: Apple M4 Pro
ClojureWasm: interpreter-based Wasm runtime (switch dispatch)

| Benchmark    | Native(ms) | Wasmtime(ms) | CljWasm(ms) | WT/Native | CW/Native |
|--------------|------------|--------------|-------------|-----------|-----------|
| mandelbrot   | 9.98       | 18.28        | 735.75      | 1.8x      | 73.7x     |
| vector_add   | 15.59      | 51.04        | 4511.14     | 3.3x      | 289.4x    |
| dot_product  | 54.97      | 69.15        | 3525.11     | 1.3x      | 64.1x     |
| matrix_mul   | 39.47      | 52.17        | 531.27      | 1.3x      | 13.5x     |

## Analysis

- **Wasmtime overhead**: 1.3x-3.3x (JIT compiled, expected for Wasm)
- **ClojureWasm overhead**: 13.5x-289.4x (interpreter, no SIMD)
  - matrix_mul (13.5x): small working set, fits in cache
  - mandelbrot (73.7x): branch-heavy code, reasonable for interpreter
  - dot_product (64.1x): memory-bound, large array traversal
  - vector_add (289.4x): memory bandwidth limited, worst case for interpreter

## Target improvements

- Phase 36 (SIMD): Expect 4-8x improvement on vector_add/dot_product
- Phase 37 (JIT): Expect 10-50x improvement across all benchmarks

## Environment

- Native: `cc -O2` (Apple Silicon, auto-vectorized by compiler)
- Wasmtime: v41.0.0 (Cranelift JIT)
- ClojureWasm: switch-based interpreter
- Each benchmark: 5 runs, hyperfine timing
