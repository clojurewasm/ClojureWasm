#!/usr/bin/env bash
# run_bench.sh — ClojureWasm benchmark runner (hyperfine)
#
# Usage:
#   bash bench/run_bench.sh                        # All benchmarks
#   bash bench/run_bench.sh --bench=fib_recursive  # Single benchmark
#   bash bench/run_bench.sh --quick                # Fast check (1 run, no warmup)
#   bash bench/run_bench.sh --runs=10 --warmup=3   # Custom hyperfine settings
#
# Always: ReleaseSafe, VM backend, hyperfine measurement.
# For multi-language comparison: use bench/compare_langs.sh
# For recording to history.yaml: use bench/record.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Defaults ---
BENCH_FILTER=""
RUNS=3
WARMUP=1

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --bench=*)    BENCH_FILTER="${arg#--bench=}" ;;
    --runs=*)     RUNS="${arg#--runs=}" ;;
    --warmup=*)   WARMUP="${arg#--warmup=}" ;;
    --quick)      RUNS=1; WARMUP=0 ;;
    -h|--help)
      echo "Usage: bash bench/run_bench.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --bench=NAME     Run specific benchmark (e.g. fib_recursive)"
      echo "  --runs=N         Hyperfine runs (default: 3)"
      echo "  --warmup=N       Hyperfine warmup runs (default: 1)"
      echo "  --quick          Fast check: 1 run, no warmup"
      echo "  -h, --help       Show this help"
      echo ""
      echo "Always builds ReleaseSafe, uses VM backend."
      echo "For multi-language comparison: bench/compare_langs.sh"
      echo "For recording to history:      bench/record.sh"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Check hyperfine ---
if ! command -v hyperfine &>/dev/null; then
  echo -e "${RED}Error: hyperfine not found. Install: brew install hyperfine${RESET}" >&2
  exit 1
fi

# --- Build ReleaseSafe ---
echo -e "${CYAN}Building ClojureWasm (ReleaseSafe)...${RESET}"
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe) || {
  echo -e "${RED}Build failed${RESET}" >&2
  exit 1
}

# --- Discover benchmarks ---
BENCH_DIRS=()
for dir in "$SCRIPT_DIR/benchmarks"/*/; do
  [[ -f "$dir/meta.yaml" ]] || continue
  [[ -f "$dir/bench.clj" ]] || continue
  if [[ -n "$BENCH_FILTER" ]]; then
    local_name=$(basename "$dir" | sed 's/^[0-9]*_//')
    [[ "$local_name" == "$BENCH_FILTER" ]] || continue
  fi
  BENCH_DIRS+=("$dir")
done

if [[ ${#BENCH_DIRS[@]} -eq 0 ]]; then
  echo -e "${RED}No benchmarks found${RESET}" >&2
  exit 1
fi

echo -e "${BOLD}ClojureWasm Benchmark Suite${RESET}"
echo -e "Benchmarks: ${#BENCH_DIRS[@]}, runs=$RUNS, warmup=$WARMUP"
echo ""

# --- Temp directory ---
TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

# --- Run benchmarks ---
for bench_dir in "${BENCH_DIRS[@]}"; do
  bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
  expected=$(yq '.expected_output' "$bench_dir/meta.yaml")
  json_file="$TMPDIR_BENCH/${bench_name}.json"

  printf "  %-24s " "$bench_name"

  # Run hyperfine
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$json_file" \
    "$CLJW $bench_dir/bench.clj" \
    >/dev/null 2>&1

  # Parse results
  result=$(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
r = data['results'][0]
time_ms = round(r['mean'] * 1000)
print(time_ms)
")
  printf "%6s ms\n" "$result"

  # Verify output
  actual=$($CLJW "$bench_dir/bench.clj" 2>&1 | head -1 | tr -d '[:space:]')
  expected_clean=$(echo "$expected" | tr -d '[:space:]')
  if [[ "$actual" != "$expected_clean" ]]; then
    echo -e "    ${RED}WARNING: output mismatch (expected=$expected_clean actual=$actual)${RESET}"
  fi
done

echo ""
echo -e "${GREEN}Done.${RESET}"
