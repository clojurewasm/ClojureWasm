# SIMD Benchmark Results

## Phase 36 (SIMD implemented, interpreter)

Date: 2026-02-08
CPU: Apple M4 Pro
ClojureWasm: switch-based interpreter with SIMD Phase 36 (all 236 opcodes)

| Benchmark    | Native(ms) | Wasmtime(ms) | CW-scalar(ms) | CW-SIMD(ms) | Scalar/N | SIMD/N | Speedup |
|--------------|------------|--------------|----------------|-------------|----------|--------|---------|
| mandelbrot   | 10.53      | 19.06        | 712.85         | 705.40      | 67.7x    | 67.0x  | 1.01x   |
| vector_add   | 13.59      | 22.85        | 4438.60        | 1723.26     | 326.6x   | 126.8x | 2.58x   |
| dot_product  | 88.70      | 101.12       | 3535.42        | 3503.87     | 39.9x    | 39.5x  | 1.01x   |
| matrix_mul   | 39.77      | 51.95        | 530.15         | 537.21      | 13.3x    | 13.5x  | 0.99x   |

## Phase 35.5 Baseline (pre-SIMD, scalar wasm only)

Date: 2026-02-08
CPU: Apple M4 Pro

| Benchmark    | Native(ms) | Wasmtime(ms) | CljWasm(ms) | WT/Native | CW/Native |
|--------------|------------|--------------|-------------|-----------|-----------|
| mandelbrot   | 9.98       | 18.28        | 735.75      | 1.8x      | 73.7x     |
| vector_add   | 15.59      | 51.04        | 4511.14     | 3.3x      | 289.4x    |
| dot_product  | 54.97      | 69.15        | 3525.11     | 1.3x      | 64.1x     |
| matrix_mul   | 39.47      | 52.17        | 531.27      | 1.3x      | 13.5x     |

## Analysis

### SIMD Impact
- **vector_add**: 2.58x speedup — auto-vectorized loop benefits directly from SIMD
  (4 f32 ops per instruction vs 1). Sub-4x due to interpreter dispatch overhead.
- **mandelbrot/dot_product/matrix_mul**: Minimal change — either branch-heavy,
  memory-bound, or not auto-vectorized by the compiler.

### Overall
- No regression from SIMD code changes (scalar wasm performance unchanged)
- Interpreter overhead remains the dominant factor (13-327x vs native)
- SIMD provides real benefit for vectorizable workloads even in interpreter

## Environment

- Native: `cc -O2` (Apple Silicon, auto-vectorized by compiler)
- Wasmtime: v41.0.0 (Cranelift JIT)
- Scalar wasm: `zig cc -target wasm32-wasi -O2`
- SIMD wasm: `zig cc -target wasm32-wasi -O2 -msimd128`
- ClojureWasm: switch-based interpreter
- Each benchmark: 5 runs, hyperfine timing
