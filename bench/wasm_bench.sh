#!/usr/bin/env bash
# wasm_bench.sh: Wasm runtime benchmark, ClojureWasm's embedded zwasm vs wasmtime
#
# Uses TinyGo-compiled .wasm modules with built-in iteration loops.
# Both CW and wasmtime execute the SAME wasm function with the SAME
# loop count, making the comparison fair (apples-to-apples).
#
# The cljw side goes through the ordinary FFI surface, `(wasm/load path opts)`
# + `(wasm/call m "fn" args)` (ADR-0192). `:fuel 0` is unmetered: these loops
# run past the finite default fuel budget, and metering is not what is being
# measured. `:engine` selects zwasm's execution tier, the cljw default is
# `.auto` (JIT-first with interp fallback, .dev/zwasm_capabilities.md D-488),
# so the default column is JIT-vs-JIT against wasmtime, NOT interpreter-vs-JIT.
# `--engine=interp` measures the fallback tier instead.
#
# Usage:
#   bash bench/wasm_bench.sh                 # All wasm benchmarks
#   bash bench/wasm_bench.sh --quick         # Single run, no warmup
#   bash bench/wasm_bench.sh --bench=fib     # Specific benchmark
#   bash bench/wasm_bench.sh --engine=interp # zwasm interp tier (default: auto)
#   bash bench/wasm_bench.sh --yaml=FILE     # Write measurements as YAML
#   bash bench/wasm_bench.sh --rebuild       # Rebuild .wasm files from .go sources
#   bash bench/wasm_bench.sh --no-wasm       # Early exit (binary built with -Dwasm=false)

set -euo pipefail

# --- Early exit if wasm disabled ---
for arg in "$@"; do
  if [[ "$arg" == "--no-wasm" ]]; then
    echo "wasm_bench.sh: --no-wasm specified, skipping wasm benchmarks."
    exit 0
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib_build_lock.sh"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"
WASM_DIR="$SCRIPT_DIR/wasm"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Defaults
RUNS=5
WARMUP=2
BENCH_FILTER=""
REBUILD=false
SKIP_BUILD=false
ENGINE="auto"
YAML_FILE=""

for arg in "$@"; do
  case "$arg" in
    --quick)      RUNS=1; WARMUP=0 ;;
    --bench=*)    BENCH_FILTER="${arg#--bench=}" ;;
    --engine=*)   ENGINE="${arg#--engine=}" ;;
    --yaml=*)     YAML_FILE="${arg#--yaml=}" ;;
    --rebuild)    REBUILD=true ;;
    --runs=*)     RUNS="${arg#--runs=}" ;;
    --warmup=*)   WARMUP="${arg#--warmup=}" ;;
    --skip-build) SKIP_BUILD=true ;;
    -h|--help)
      echo "Usage: bash bench/wasm_bench.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --quick          Single run, no warmup"
      echo "  --bench=NAME     Run specific benchmark (fib, tak, arith, sieve)"
      echo "  --engine=E       zwasm engine tier: auto (default) | jit | interp"
      echo "  --yaml=FILE      Write measurements as YAML"
      echo "  --rebuild        Rebuild .wasm files from .go sources"
      echo "  --runs=N         Hyperfine runs (default: 5)"
      echo "  --warmup=N       Hyperfine warmup (default: 2)"
      echo "  --skip-build     Skip CW build step"
      echo "  -h, --help       Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Benchmark definitions ---
# Each entry: name:wasm_file:bench_fn:bench_args:expected
# bench_fn is a wasm-exported function that includes the iteration loop.
# bench_args includes both the problem parameters and iteration count.
BENCHMARKS=(
  "fib:fib_bench.wasm:fib_bench:20 10000:10946"
  "tak:tak_bench.wasm:tak_bench:18 12 6 10000:12"
  "arith:arith_bench.wasm:arith_bench:1000000 10:499999500000"
  "sieve:sieve_bench.wasm:sieve_bench:65536 100:6542"
  "fib_loop:fib_loop_bench.wasm:fib_loop_bench:25 1000000:121393"
  "gcd:gcd_bench.wasm:gcd_bench:1000000 700000 1000000:29152780"
)

# --- Rebuild wasm if requested ---
if $REBUILD; then
  echo -e "${CYAN}Rebuilding .wasm files from TinyGo sources...${RESET}"
  for gofile in "$WASM_DIR"/*.go; do
    base=$(basename "$gofile" .go)
    echo -n "  $base.go -> $base.wasm ... "
    tinygo build -target=wasm -no-debug -gc=leaking -opt=2 -o "$WASM_DIR/$base.wasm" "$gofile" 2>&1
    echo "ok ($(wc -c < "$WASM_DIR/$base.wasm") bytes)"
  done
  echo ""
fi

# --- Build CW ---
if ! $SKIP_BUILD; then
  echo -e "${CYAN}Building ClojureWasm (ReleaseSafe)...${RESET}"
  (cd "$PROJECT_ROOT" && with_build_lock zig build -Dwasm -Doptimize=ReleaseSafe) || {
    echo -e "${RED}Build failed${RESET}" >&2
    exit 1
  }
fi

# --- Verify wasm files exist ---
for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm_file _ _ _ <<< "$entry"
  if [[ ! -f "$WASM_DIR/$wasm_file" ]]; then
    echo -e "${RED}Missing: $WASM_DIR/$wasm_file. Run with --rebuild${RESET}" >&2
    exit 1
  fi
done

# --- Temp directory ---
TMPDIR_WASM=$(mktemp -d)
trap "rm -rf $TMPDIR_WASM" EXIT

# --- Helper: run hyperfine and get mean time in ms ---
hf_mean_ms() {
  local cmd="$1"
  local json_file="$TMPDIR_WASM/hf_${RANDOM}_$$.json"
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$json_file" \
    "$cmd" \
    >/dev/null 2>&1
  python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
mean_s = data['results'][0]['mean']
print(f'{mean_s * 1000:.1f}')
"
  rm -f "$json_file"
}

# --- Measure startup overhead ---
echo -e "${CYAN}Measuring startup overhead...${RESET}"

# CW startup: load a wasm module and call a trivial function. This is the
# subtrahend for "warm", so it must carry the SAME engine as the timed runs,
# JIT compilation happens at load, and charging it to compute would flatter the
# interp column by exactly the JIT's compile time.
cat > "$TMPDIR_WASM/noop.clj" << CEOF
(def m (wasm/load "$WASM_DIR/fib_bench.wasm" {:engine :$ENGINE :fuel 0}))
(println (wasm/call m "fib" 1))
CEOF
CW_STARTUP_MS=$(hf_mean_ms "$CLJW $TMPDIR_WASM/noop.clj")
echo -e "  CW startup+load:   ${CW_STARTUP_MS} ms"

# wasmtime startup
WT_STARTUP_MS=$(hf_mean_ms "wasmtime run --invoke fib $WASM_DIR/fib_bench.wasm 1")
echo -e "  wasmtime startup:  ${WT_STARTUP_MS} ms"
echo ""

# --- Run benchmarks ---
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Wasm Runtime Benchmark: ClojureWasm (zwasm, :engine ${ENGINE}) vs wasmtime${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${RESET}"
echo ""
printf "  ${DIM}%-10s %10s %10s %10s %10s %10s${RESET}\n" \
  "Benchmark" "CW (ms)" "wt (ms)" "CW warm" "wt warm" "ratio"
echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${RESET}"

YAML_ROWS=()

for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm_file bench_fn bench_args expected <<< "$entry"

  # Filter
  if [[ -n "$BENCH_FILTER" && "$name" != "$BENCH_FILTER" ]]; then
    continue
  fi

  wasm_path="$WASM_DIR/$wasm_file"

  # Verify wasmtime output
  wt_output=$(wasmtime run --invoke "$bench_fn" "$wasm_path" $bench_args 2>/dev/null)
  wt_clean=$(echo "$wt_output" | tr -d '[:space:]')
  expected_clean=$(echo "$expected" | tr -d '[:space:]')
  if [[ "$wt_clean" != "$expected_clean" ]]; then
    echo -e "  ${RED}SKIP${RESET} $name: wasmtime output mismatch (got=$wt_clean expected=$expected_clean)"
    continue
  fi

  # Create CW bench script (single wasm call with loop inside wasm)
  cw_clj="$TMPDIR_WASM/cw_${name}.clj"
  cat > "$cw_clj" << CEOF
(def m (wasm/load "$wasm_path" {:engine :$ENGINE :fuel 0}))
(println (wasm/call m "$bench_fn" $bench_args))
CEOF

  # Verify CW output
  cw_output=$($CLJW "$cw_clj" 2>&1 | sed -n 1p | tr -d '[:space:]')
  if [[ "$cw_output" != "$expected_clean" ]]; then
    echo -e "  ${RED}SKIP${RESET} $name: CW output mismatch (got=$cw_output expected=$expected_clean)"
    continue
  fi

  # --- Measure ---
  cw_ms=$(hf_mean_ms "$CLJW $cw_clj")
  wt_ms=$(hf_mean_ms "wasmtime run --invoke $bench_fn $wasm_path $bench_args")

  # Warm times (subtract startup)
  cw_warm=$(python3 -c "print(f'{max(0.1, $cw_ms - $CW_STARTUP_MS):.1f}')")
  wt_warm=$(python3 -c "print(f'{max(0.1, $wt_ms - $WT_STARTUP_MS):.1f}')")

  # Ratio (warm CW / warm wasmtime)
  ratio=$(python3 -c "
cw=$cw_warm; wt=$wt_warm
if wt > 0.01: print(f'{cw/wt:.1f}x')
else: print('N/A')
")

  # Color
  color="$YELLOW"
  ratio_num=$(python3 -c "print($cw_warm / max(0.01, $wt_warm))")
  if python3 -c "exit(0 if $ratio_num < 3.0 else 1)" 2>/dev/null; then
    color="$GREEN"
  elif python3 -c "exit(0 if $ratio_num > 50.0 else 1)" 2>/dev/null; then
    color="$RED"
  fi

  printf "  ${color}%-10s %10s %10s %10s %10s %10s${RESET}\n" \
    "$name" "$cw_ms" "$wt_ms" "$cw_warm" "$wt_warm" "$ratio"

  YAML_ROWS+=("$name:$cw_ms:$wt_ms:$cw_warm:$wt_warm")
done

# --- YAML export ---
# Scrollback is not data. A run that is only printed cannot be diffed against
# the next one, so the table in the docs is generated from this file, never
# transcribed by hand (bench/README.md's standing rule).
if [[ -n "$YAML_FILE" ]]; then
  {
    echo "# Wasm FFI benchmark: cljw (embedded zwasm) vs wasmtime"
    echo "# Generated: $(date -Iseconds) by bench/wasm_bench.sh"
    echo ""
    echo "date: \"$(date +%F)\""
    echo ""
    echo "env:"
    echo "  machine: $(uname -srm)"
    echo "  cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1 || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    echo "  cljw: $("$CLJW" --version 2>&1 | head -1)"
    echo "  wasmtime: $(wasmtime --version 2>&1 | head -1)"
    echo "  engine: $ENGINE"
    echo "  tool: hyperfine"
    echo "  runs: $RUNS"
    echo "  warmup: $WARMUP"
    echo ""
    echo "startup_ms:"
    echo "  cw: $CW_STARTUP_MS"
    echo "  wasmtime: $WT_STARTUP_MS"
    echo ""
    echo "benchmarks:"
    for row in "${YAML_ROWS[@]}"; do
      IFS=: read -r n cwm wtm cww wtw <<< "$row"
      echo "  $n:"
      echo "    cold_ms: {cw: $cwm, wasmtime: $wtm}"
      echo "    warm_ms: {cw: $cww, wasmtime: $wtw}"
    done
  } > "$YAML_FILE"
  echo ""
  echo -e "  ${CYAN}YAML written: $YAML_FILE${RESET}"
fi

echo ""
echo -e "  ${DIM}CW startup+load: ${CW_STARTUP_MS}ms  |  wasmtime startup: ${WT_STARTUP_MS}ms${RESET}"
echo -e "  ${DIM}\"warm\" = total - startup (pure wasm execution time)${RESET}"
echo -e "  ${DIM}ratio = CW warm / wasmtime warm (lower is better for CW)${RESET}"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}Done.${RESET}"
