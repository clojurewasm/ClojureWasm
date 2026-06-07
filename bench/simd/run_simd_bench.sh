#!/usr/bin/env bash
# SIMD benchmark runner — compares native, wasmtime, CljWasm (scalar), CljWasm (SIMD)
# Usage: bash bench/simd/run_simd_bench.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"
TMPDIR="${TMPDIR:-/tmp}"
JSON_FILE="$TMPDIR/simd_bench_result.json"

cd "$SCRIPT_DIR"

# Build all variants
echo "=== Building benchmarks ==="
make -s all
echo "  Native + Wasm (scalar + SIMD) builds: OK"

# Build ClojureWasm (ReleaseSafe)
echo "  Building cljw (ReleaseSafe)..."
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe 2>/dev/null)
echo "  cljw build: OK"
echo ""

extract_mean_ms() {
    python3 -c "
import json
d = json.load(open('$JSON_FILE'))
print(f\"{d['results'][0]['mean'] * 1000:.2f}\")"
}

BENCHMARKS=("mandelbrot" "vector_add" "dot_product" "matrix_mul")
INIT_FNS=("" "init" "init" "init")
WARMUP=2
RUNS=5

# Print header
printf "%-14s  %10s  %10s  %10s  %10s  %10s  %10s\n" \
    "Benchmark" "Native" "Wasmtime" "CW-scalar" "CW-SIMD" "Scalar/N" "SIMD/N"
printf "%-14s  %10s  %10s  %10s  %10s  %10s  %10s\n" \
    "---------" "------" "--------" "---------" "-------" "--------" "------"

for i in "${!BENCHMARKS[@]}"; do
    name="${BENCHMARKS[$i]}"
    init_fn="${INIT_FNS[$i]}"

    # --- Native ---
    hyperfine --warmup $WARMUP --runs $RUNS \
        --export-json "$JSON_FILE" "./${name}_native" >/dev/null 2>&1
    native_ms=$(extract_mean_ms)

    # --- Wasmtime (SIMD wasm) ---
    if [ -n "$init_fn" ]; then
        cmd="wasmtime run --invoke $init_fn $SCRIPT_DIR/${name}_simd.wasm >/dev/null 2>&1; wasmtime run --invoke ${name} $SCRIPT_DIR/${name}_simd.wasm >/dev/null 2>&1"
    else
        cmd="wasmtime run --invoke ${name} $SCRIPT_DIR/${name}_simd.wasm >/dev/null 2>&1"
    fi
    hyperfine --warmup $WARMUP --runs $RUNS -i \
        --export-json "$JSON_FILE" "$cmd" >/dev/null 2>&1
    wasmtime_ms=$(extract_mean_ms)

    # --- ClojureWasm (scalar wasm) ---
    cat > /tmp/cw_bench_${name}.clj << CLJEOF
(require '[cljw.wasm :as wasm])
(let [mod (wasm/load "$SCRIPT_DIR/${name}.wasm")]
  $(if [ -n "$init_fn" ]; then echo "((wasm/fn mod \"$init_fn\"))"; fi)
  ((wasm/fn mod "$name")))
CLJEOF

    hyperfine --warmup 1 --runs $RUNS -i \
        --export-json "$JSON_FILE" "$CLJW /tmp/cw_bench_${name}.clj" >/dev/null 2>&1
    cw_scalar_ms=$(extract_mean_ms)

    # --- ClojureWasm (SIMD wasm) ---
    cat > /tmp/cw_bench_${name}_simd.clj << CLJEOF
(require '[cljw.wasm :as wasm])
(let [mod (wasm/load "$SCRIPT_DIR/${name}_simd.wasm")]
  $(if [ -n "$init_fn" ]; then echo "((wasm/fn mod \"$init_fn\"))"; fi)
  ((wasm/fn mod "$name")))
CLJEOF

    hyperfine --warmup 1 --runs $RUNS -i \
        --export-json "$JSON_FILE" "$CLJW /tmp/cw_bench_${name}_simd.clj" >/dev/null 2>&1
    cw_simd_ms=$(extract_mean_ms)

    # Ratios
    scalar_ratio=$(python3 -c "print(f'{$cw_scalar_ms / $native_ms:.1f}x')")
    simd_ratio=$(python3 -c "print(f'{$cw_simd_ms / $native_ms:.1f}x')")

    printf "%-14s  %8sms  %8sms  %8sms  %8sms  %10s  %10s\n" \
        "$name" "$native_ms" "$wasmtime_ms" "$cw_scalar_ms" "$cw_simd_ms" "$scalar_ratio" "$simd_ratio"
done

rm -f "$JSON_FILE"

echo ""
echo "Environment:"
echo "  CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "  Native: cc -O2 (Apple Silicon)"
echo "  Wasmtime: v$(wasmtime --version 2>/dev/null | awk '{print $2}')"
echo "  ClojureWasm: switch-based interpreter (SIMD Phase 36)"
echo "  Scalar wasm: zig cc -O2 (no SIMD)"
echo "  SIMD wasm: zig cc -O2 -msimd128"
echo "  Runs: $RUNS (warmup: $WARMUP native/wasmtime, 1 cljw)"
