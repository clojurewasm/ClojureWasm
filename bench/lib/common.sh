#!/usr/bin/env bash
# common.sh — Shared functions for benchmark runner

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCH_ROOT/.." && pwd)"
CLOJUREWASM="$PROJECT_ROOT/zig-out/bin/cljw"

# measure_time CMD...
# Runs command, captures wall-clock time in ms, stdout, and exit code.
# Sets: MEASURE_TIME_MS, MEASURE_OUTPUT, MEASURE_EXIT
measure_time() {
  local start end
  start=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
  MEASURE_OUTPUT=$("$@" 2>&1) || true
  MEASURE_EXIT=$?
  end=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
  MEASURE_TIME_MS=$(( (end - start) / 1000000 ))
}

# measure_mem CMD...
# Measures peak RSS in MB (macOS: /usr/bin/time -l, Linux: /usr/bin/time -v)
# Sets: MEASURE_MEM_MB
measure_mem() {
  local tmpfile
  tmpfile=$(mktemp)
  if [[ "$(uname)" == "Darwin" ]]; then
    /usr/bin/time -l "$@" >/dev/null 2>"$tmpfile" || true
    # macOS reports bytes
    local bytes
    bytes=$(grep "maximum resident set size" "$tmpfile" | awk '{print $1}')
    MEASURE_MEM_MB=$(echo "scale=1; ${bytes:-0} / 1048576" | bc)
  else
    /usr/bin/time -v "$@" >/dev/null 2>"$tmpfile" || true
    # Linux reports KB
    local kb
    kb=$(grep "Maximum resident" "$tmpfile" | awk '{print $NF}')
    MEASURE_MEM_MB=$(echo "scale=1; ${kb:-0} / 1024" | bc)
  fi
  rm -f "$tmpfile"
}

# build_clojurewasm [--release|--release-safe]
# Builds ClojureWasm binary
build_clojurewasm() {
  local optimize="" label=""
  if [[ "${1:-}" == "--release" ]]; then
    optimize="-Doptimize=ReleaseFast"
    label="(ReleaseFast)"
  elif [[ "${1:-}" == "--release-safe" ]]; then
    optimize="-Doptimize=ReleaseSafe"
    label="(ReleaseSafe)"
  fi
  echo -e "${CYAN}Building ClojureWasm${RESET} ${label}"
  (cd "$PROJECT_ROOT" && zig build $optimize) || {
    echo -e "${RED}Build failed${RESET}"
    return 1
  }
}

# run_clojurewasm FILE [--backend=vm]
# Runs a .clj file with ClojureWasm (default: TreeWalk)
run_clojurewasm() {
  local file="$1"
  shift
  local backend_flag="--tree-walk"
  if [[ "${1:-}" == "--backend=vm" ]]; then
    backend_flag=""
    shift
  fi
  "$CLOJUREWASM" $backend_flag "$file"
}

# compile_c FILE OUTPUT
compile_c() {
  local src="$1" out="$2"
  cc -O3 -o "$out" "$src" -lm
}

# compile_zig FILE OUTPUT
compile_zig() {
  local src="$1" out="$2"
  zig build-exe -OReleaseFast -femit-bin="$out" "$src"
}

# compile_java FILE DIR
compile_java() {
  local src="$1" dir="$2"
  javac -d "$dir" "$src"
}

# format_result LANG TIME_MS [MEM_MB]
# Prints a formatted result line
format_result() {
  local lang="$1" time_ms="$2" mem_mb="${3:-N/A}"
  printf "  %-16s %8s ms  %8s MB\n" "$lang" "$time_ms" "$mem_mb"
}

# format_header BENCHMARK_NAME
format_header() {
  echo -e "\n${BOLD}=== $1 ===${RESET}"
}

# check_output EXPECTED ACTUAL LANG
# Verifies benchmark output matches expected value
# Takes first line of output (println output), ignores trailing nil/return values
check_output() {
  local expected="$1" actual="$2" lang="$3"
  # Take first line only (println output before nil return)
  actual=$(echo "$actual" | head -1 | tr -d '[:space:]')
  expected=$(echo "$expected" | tr -d '[:space:]')
  if [[ "$actual" != "$expected" ]]; then
    echo -e "  ${RED}FAIL${RESET} ($lang): expected=$expected actual=$actual"
    return 1
  fi
  return 0
}

# load_meta DIR
# Loads meta.yaml from benchmark directory.
# Sets: META_NAME, META_EXPECTED, META_CATEGORY
load_meta() {
  local dir="$1"
  META_NAME=$(yq '.name' "$dir/meta.yaml")
  META_EXPECTED=$(yq '.expected_output' "$dir/meta.yaml")
  META_CATEGORY=$(yq '.category' "$dir/meta.yaml")
}

# yaml_append_result FILE KEY VALUE
# Appends a benchmark result to YAML (used by --record)
yaml_append_result() {
  local file="$1" key="$2" value="$3"
  yq -i "$key = $value" "$file"
}
