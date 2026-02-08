#!/usr/bin/env bash
# SIMD benchmark runner — compares native, wasmtime, and ClojureWasm
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
echo "  Native + Wasm builds: OK"

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
printf "%-14s  %12s  %12s  %12s  %10s  %10s\n" \
    "Benchmark" "Native(ms)" "Wasmtime(ms)" "CljWasm(ms)" "WT/Native" "CW/Native"
printf "%-14s  %12s  %12s  %12s  %10s  %10s\n" \
    "---------" "----------" "------------" "-----------" "---------" "---------"

for i in "${!BENCHMARKS[@]}"; do
    name="${BENCHMARKS[$i]}"
    init_fn="${INIT_FNS[$i]}"

    # --- Native ---
    hyperfine --warmup $WARMUP --runs $RUNS \
        --export-json "$JSON_FILE" "./${name}_native" >/dev/null 2>&1
    native_ms=$(extract_mean_ms)

    # --- Wasmtime ---
    # wasmtime --invoke outputs to stdout, redirect to suppress
    if [ -n "$init_fn" ]; then
        cmd="wasmtime run --invoke $init_fn $SCRIPT_DIR/${name}.wasm >/dev/null 2>&1; wasmtime run --invoke ${name} $SCRIPT_DIR/${name}.wasm >/dev/null 2>&1"
    else
        cmd="wasmtime run --invoke ${name} $SCRIPT_DIR/${name}.wasm >/dev/null 2>&1"
    fi
    hyperfine --warmup $WARMUP --runs $RUNS -i \
        --export-json "$JSON_FILE" "$cmd" >/dev/null 2>&1
    wasmtime_ms=$(extract_mean_ms)

    # --- ClojureWasm ---
    cat > /tmp/cw_bench_${name}.clj << CLJEOF
(require '[cljw.wasm :as wasm])
(let [mod (wasm/load "$SCRIPT_DIR/${name}.wasm")]
  $(if [ -n "$init_fn" ]; then echo "((wasm/fn mod \"$init_fn\"))"; fi)
  ((wasm/fn mod "$name")))
CLJEOF

    hyperfine --warmup 1 --runs $RUNS -i \
        --export-json "$JSON_FILE" "$CLJW /tmp/cw_bench_${name}.clj" >/dev/null 2>&1
    cw_ms=$(extract_mean_ms)

    # Ratios
    wt_ratio=$(python3 -c "print(f'{$wasmtime_ms / $native_ms:.1f}x')")
    cw_ratio=$(python3 -c "print(f'{$cw_ms / $native_ms:.1f}x')")

    printf "%-14s  %12s  %12s  %12s  %10s  %10s\n" \
        "$name" "$native_ms" "$wasmtime_ms" "$cw_ms" "$wt_ratio" "$cw_ratio"
done

rm -f "$JSON_FILE"

echo ""
echo "Environment:"
echo "  CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "  Native: cc -O2 (Apple Silicon)"
echo "  Wasmtime: v$(wasmtime --version 2>/dev/null | awk '{print $2}')"
echo "  ClojureWasm: interpreter-based Wasm runtime"
echo "  Runs: $RUNS (warmup: $WARMUP native/wasmtime, 1 cljw)"
