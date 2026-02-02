#!/usr/bin/env bash
# run_bench.sh — ClojureWasm benchmark runner
#
# Usage:
#   bash bench/run_bench.sh              # ClojureWasm only, all benchmarks
#   bash bench/run_bench.sh --all        # All languages
#   bash bench/run_bench.sh --lang=c     # Specific language
#   bash bench/run_bench.sh --bench=fib_recursive  # Specific benchmark
#   bash bench/run_bench.sh --record --version="Phase 5"  # Record to bench.yaml
#   bash bench/run_bench.sh --hyperfine  # Use hyperfine for precision
#   bash bench/run_bench.sh --backend=vm # Use VM backend
#   bash bench/run_bench.sh --release    # Build with ReleaseFast

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Parse arguments ---
RUN_ALL=false
LANG_FILTER=""
BENCH_FILTER=""
RECORD=false
VERSION_LABEL=""
USE_HYPERFINE=false
BACKEND=""
RELEASE=false

for arg in "$@"; do
  case "$arg" in
    --all)           RUN_ALL=true ;;
    --lang=*)        LANG_FILTER="${arg#--lang=}" ;;
    --bench=*)       BENCH_FILTER="${arg#--bench=}" ;;
    --record)        RECORD=true ;;
    --version=*)     VERSION_LABEL="${arg#--version=}" ;;
    --hyperfine)     USE_HYPERFINE=true ;;
    --backend=vm)    BACKEND="--backend=vm" ;;
    --release)       RELEASE=true ;;
    -h|--help)
      echo "Usage: bash bench/run_bench.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --all             Run all languages (default: ClojureWasm only)"
      echo "  --lang=LANG       Run specific language (clojurewasm,c,zig,java,python,ruby,clojure,bb)"
      echo "  --bench=NAME      Run specific benchmark (e.g. fib_recursive)"
      echo "  --record          Append results to .dev/status/bench.yaml"
      echo "  --version=NAME    Version label for --record"
      echo "  --hyperfine       Use hyperfine for high-precision measurement"
      echo "  --backend=vm      Use VM backend (default: TreeWalk)"
      echo "  --release         Build with ReleaseFast optimization"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# --- Build ClojureWasm ---
if $RELEASE; then
  build_clojurewasm --release
else
  build_clojurewasm
fi

# --- Determine which languages to run ---
ALL_LANGS=(clojurewasm c zig java python ruby clojure bb)
LANGS=()

if [[ -n "$LANG_FILTER" ]]; then
  LANGS=("$LANG_FILTER")
elif $RUN_ALL; then
  LANGS=("${ALL_LANGS[@]}")
else
  LANGS=(clojurewasm)
fi

# --- Determine which benchmarks to run ---
BENCH_DIRS=()
for dir in "$BENCH_ROOT/benchmarks"/*/; do
  [[ -f "$dir/meta.yaml" ]] || continue
  if [[ -n "$BENCH_FILTER" ]]; then
    local_name=$(basename "$dir" | sed 's/^[0-9]*_//')
    [[ "$local_name" == "$BENCH_FILTER" ]] || continue
  fi
  BENCH_DIRS+=("$dir")
done

if [[ ${#BENCH_DIRS[@]} -eq 0 ]]; then
  echo -e "${RED}No benchmarks found${RESET}"
  exit 1
fi

echo -e "${BOLD}ClojureWasm Benchmark Suite${RESET}"
echo -e "Languages: ${CYAN}${LANGS[*]}${RESET}"
echo -e "Benchmarks: ${#BENCH_DIRS[@]}"
echo ""

# --- Results storage for --record ---
declare -A RESULTS  # key: "bench:lang" -> "time_ms:mem_mb"

# --- Run benchmarks ---
for bench_dir in "${BENCH_DIRS[@]}"; do
  load_meta "$bench_dir"
  bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
  format_header "$META_NAME ($META_CATEGORY)"

  for lang in "${LANGS[@]}"; do
    case "$lang" in
      clojurewasm)
        [[ -f "$bench_dir/bench.clj" ]] || continue
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}clojurewasm${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 \
            "$CLOJUREWASM $BACKEND $bench_dir/bench.clj" \
            2>&1 | sed 's/^/    /'
        else
          measure_time run_clojurewasm "$bench_dir/bench.clj" $BACKEND
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "clojurewasm" || true
          measure_mem run_clojurewasm "$bench_dir/bench.clj" $BACKEND
          format_result "clojurewasm" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:clojurewasm"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        ;;
      c)
        [[ -f "$bench_dir/bench.c" ]] || continue
        local_bin=$(mktemp)
        compile_c "$bench_dir/bench.c" "$local_bin"
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}c${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "$local_bin" 2>&1 | sed 's/^/    /'
        else
          measure_time "$local_bin"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "c" || true
          measure_mem "$local_bin"
          format_result "c" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:c"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        rm -f "$local_bin"
        ;;
      zig)
        [[ -f "$bench_dir/bench.zig" ]] || continue
        local_bin=$(mktemp)
        compile_zig "$bench_dir/bench.zig" "$local_bin"
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}zig${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "$local_bin" 2>&1 | sed 's/^/    /'
        else
          measure_time "$local_bin"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "zig" || true
          measure_mem "$local_bin"
          format_result "zig" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:zig"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        rm -f "$local_bin"
        ;;
      java)
        [[ -f "$bench_dir/Bench.java" ]] || continue
        local_dir=$(mktemp -d)
        compile_java "$bench_dir/Bench.java" "$local_dir"
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}java${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "java -cp $local_dir Bench" 2>&1 | sed 's/^/    /'
        else
          measure_time java -cp "$local_dir" Bench
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "java" || true
          measure_mem java -cp "$local_dir" Bench
          format_result "java" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:java"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        rm -rf "$local_dir"
        ;;
      python)
        [[ -f "$bench_dir/bench.py" ]] || continue
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}python${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "python3 $bench_dir/bench.py" 2>&1 | sed 's/^/    /'
        else
          measure_time python3 "$bench_dir/bench.py"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "python" || true
          measure_mem python3 "$bench_dir/bench.py"
          format_result "python" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:python"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        ;;
      ruby)
        [[ -f "$bench_dir/bench.rb" ]] || continue
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}ruby${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "ruby $bench_dir/bench.rb" 2>&1 | sed 's/^/    /'
        else
          measure_time ruby "$bench_dir/bench.rb"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "ruby" || true
          measure_mem ruby "$bench_dir/bench.rb"
          format_result "ruby" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:ruby"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        ;;
      clojure)
        [[ -f "$bench_dir/bench.clj" ]] || continue
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}clojure${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 3 \
            "clojure -M -e '(load-file \"$bench_dir/bench.clj\")'" \
            2>&1 | sed 's/^/    /'
        else
          measure_time clojure -M -e "(load-file \"$bench_dir/bench.clj\")"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "clojure" || true
          measure_mem clojure -M -e "(load-file \"$bench_dir/bench.clj\")"
          format_result "clojure" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:clojure"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        ;;
      bb)
        [[ -f "$bench_dir/bench.clj" ]] || continue
        if $USE_HYPERFINE; then
          echo -e "  ${CYAN}bb${RESET} (hyperfine):"
          hyperfine --warmup 1 --min-runs 5 "bb $bench_dir/bench.clj" 2>&1 | sed 's/^/    /'
        else
          measure_time bb "$bench_dir/bench.clj"
          check_output "$META_EXPECTED" "$MEASURE_OUTPUT" "bb" || true
          measure_mem bb "$bench_dir/bench.clj"
          format_result "bb" "$MEASURE_TIME_MS" "$MEASURE_MEM_MB"
          RESULTS["${bench_name}:bb"]="${MEASURE_TIME_MS}:${MEASURE_MEM_MB}"
        fi
        ;;
    esac
  done
done

# --- Record results ---
if $RECORD; then
  BENCH_YAML="$PROJECT_ROOT/.dev/status/bench.yaml"
  DATE=$(date +%Y-%m-%d)
  LABEL="${VERSION_LABEL:-$DATE}"

  echo ""
  echo -e "${BOLD}Recording results to bench.yaml${RESET}"
  echo -e "  Version: $LABEL"
  echo -e "  Date: $DATE"

  # Update latest section
  yq -i ".latest.date = \"$DATE\"" "$BENCH_YAML"
  yq -i ".latest.version = \"$LABEL\"" "$BENCH_YAML"

  for key in "${!RESULTS[@]}"; do
    IFS=':' read -r bench lang <<< "$key"
    IFS=':' read -r time_ms mem_mb <<< "${RESULTS[$key]}"
    yq -i ".latest.results.${bench}.${lang}.time_ms = ${time_ms}" "$BENCH_YAML"
    yq -i ".latest.results.${bench}.${lang}.mem_mb = ${mem_mb}" "$BENCH_YAML"
  done

  # Append to history
  yq -i ".history += [{\"date\": \"$DATE\", \"version\": \"$LABEL\"}]" "$BENCH_YAML"

  echo -e "${GREEN}Results recorded${RESET}"
fi

echo ""
echo -e "${GREEN}Done.${RESET}"
