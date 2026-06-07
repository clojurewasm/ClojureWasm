#!/usr/bin/env bash
# compare_langs.sh — Cross-language benchmark comparison
#
# Usage:
#   bash bench/compare_langs.sh                          # All benchmarks, cold only
#   bash bench/compare_langs.sh --bench=fib_recursive    # Single benchmark
#   bash bench/compare_langs.sh --lang=cw,c,zig          # Specific languages
#   bash bench/compare_langs.sh --cold                   # Wall clock (default)
#   bash bench/compare_langs.sh --warm                   # Startup-subtracted
#   bash bench/compare_langs.sh --both                   # Cold + Warm
#   bash bench/compare_langs.sh --runs=10 --warmup=3     # Custom hyperfine settings
#   bash bench/compare_langs.sh --yaml=results.yaml      # YAML output file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Defaults ---
BENCH_FILTER=""
LANG_FILTER=""
MODE="cold"  # cold, warm, both
RUNS=5
WARMUP=2
YAML_FILE=""
SKIP_BUILD=false

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --bench=*)    BENCH_FILTER="${arg#--bench=}" ;;
    --lang=*)     LANG_FILTER="${arg#--lang=}" ;;
    --cold)       MODE="cold" ;;
    --warm)       MODE="warm" ;;
    --both)       MODE="both" ;;
    --runs=*)     RUNS="${arg#--runs=}" ;;
    --warmup=*)   WARMUP="${arg#--warmup=}" ;;
    --yaml=*)     YAML_FILE="${arg#--yaml=}" ;;
    --skip-build) SKIP_BUILD=true ;;
    -h|--help)
      echo "Usage: bash bench/compare_langs.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --bench=NAME     Run specific benchmark (e.g. fib_recursive)"
      echo "  --lang=LANGS     Comma-separated languages (cw,c,zig,java,tgo,py,rb,js,bb)"
      echo "  --cold           Wall clock only (default)"
      echo "  --warm           Startup-subtracted only"
      echo "  --both           Cold + Warm"
      echo "  --runs=N         Hyperfine runs (default: 5)"
      echo "  --warmup=N       Hyperfine warmup (default: 2)"
      echo "  --yaml=FILE      YAML output file"
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

# --- Determine languages ---
ALL_LANGS=(cw c zig java tgo py rb js bb)
LANGS=()
if [[ -n "$LANG_FILTER" ]]; then
  IFS=',' read -ra LANGS <<< "$LANG_FILTER"
else
  LANGS=("${ALL_LANGS[@]}")
fi

# --- Full names for display ---
lang_display_name() {
  case "$1" in
    cw)   echo "clojurewasm" ;;
    c)    echo "c" ;;
    zig)  echo "zig" ;;
    java) echo "java" ;;
    py)   echo "python" ;;
    rb)   echo "ruby" ;;
    js)   echo "node" ;;
    bb)   echo "babashka" ;;
    tgo)  echo "tinygo" ;;
    *)    echo "$1" ;;
  esac
}

# --- Discover benchmarks ---
BENCH_DIRS=()
for dir in "$SCRIPT_DIR/benchmarks"/*/; do
  [[ -f "$dir/meta.yaml" ]] || continue
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

# --- Build CW if needed ---
if ! $SKIP_BUILD; then
  echo -e "${CYAN}Building ClojureWasm (ReleaseSafe)...${RESET}"
  (cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe) || {
    echo -e "${RED}Build failed${RESET}" >&2
    exit 1
  }
fi

# --- Temp directory ---
TMPDIR_CMP=$(mktemp -d)
trap "rm -rf $TMPDIR_CMP" EXIT

# --- Helper: run hyperfine and get mean time in ms (float) ---
hf_mean_ms() {
  local cmd="$1"
  local json_file="$TMPDIR_CMP/hf_${RANDOM}_$$.json"
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

# --- Helper: compile and get command for a language ---
lang_command() {
  local lang="$1" bench_dir="$2"
  case "$lang" in
    cw)
      [[ -f "$bench_dir/bench.clj" ]] || return 1
      echo "$CLJW $bench_dir/bench.clj"
      ;;
    c)
      [[ -f "$bench_dir/bench.c" ]] || return 1
      local bin="$TMPDIR_CMP/c_$(basename "$bench_dir")"
      cc -O3 -o "$bin" "$bench_dir/bench.c" -lm 2>/dev/null
      echo "$bin"
      ;;
    zig)
      [[ -f "$bench_dir/bench.zig" ]] || return 1
      local bin="$TMPDIR_CMP/zig_$(basename "$bench_dir")"
      zig build-exe -OReleaseFast -femit-bin="$bin" "$bench_dir/bench.zig" 2>/dev/null
      echo "$bin"
      ;;
    java)
      [[ -f "$bench_dir/Bench.java" ]] || return 1
      local dir="$TMPDIR_CMP/java_$(basename "$bench_dir")"
      mkdir -p "$dir"
      javac -d "$dir" "$bench_dir/Bench.java" 2>/dev/null
      echo "java -cp $dir Bench"
      ;;
    py)
      [[ -f "$bench_dir/bench.py" ]] || return 1
      echo "python3 $bench_dir/bench.py"
      ;;
    rb)
      [[ -f "$bench_dir/bench.rb" ]] || return 1
      echo "ruby $bench_dir/bench.rb"
      ;;
    js)
      [[ -f "$bench_dir/bench.js" ]] || return 1
      command -v node >/dev/null 2>&1 || return 1
      echo "node $bench_dir/bench.js"
      ;;
    bb)
      [[ -f "$bench_dir/bench.clj" ]] || return 1
      command -v bb >/dev/null 2>&1 || return 1
      echo "bb $bench_dir/bench.clj"
      ;;
    tgo)
      [[ -f "$bench_dir/bench.go" ]] || return 1
      command -v tinygo >/dev/null 2>&1 || return 1
      local bin="$TMPDIR_CMP/tgo_$(basename "$bench_dir")"
      tinygo build -opt=2 -o "$bin" "$bench_dir/bench.go" 2>/dev/null || return 1
      echo "$bin"
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Measure startup times if warm mode ---
declare -A STARTUP_MS
if [[ "$MODE" == "warm" || "$MODE" == "both" ]]; then
  echo -e "\n${BOLD}Measuring startup times...${RESET}"

  for lang in "${LANGS[@]}"; do
    case "$lang" in
      cw)   noop_cmd="$CLJW -e nil" ;;
      c)
        cat > "$TMPDIR_CMP/noop.c" << 'CEOF'
int main(void) { return 0; }
CEOF
        cc -O3 -o "$TMPDIR_CMP/noop_c" "$TMPDIR_CMP/noop.c"
        noop_cmd="$TMPDIR_CMP/noop_c"
        ;;
      zig)
        cat > "$TMPDIR_CMP/noop.zig" << 'ZEOF'
pub fn main() void {}
ZEOF
        zig build-exe -OReleaseFast -femit-bin="$TMPDIR_CMP/noop_zig" "$TMPDIR_CMP/noop.zig" 2>/dev/null
        noop_cmd="$TMPDIR_CMP/noop_zig"
        ;;
      java)
        cat > "$TMPDIR_CMP/Noop.java" << 'JEOF'
public class Noop { public static void main(String[] a) {} }
JEOF
        mkdir -p "$TMPDIR_CMP/noop_java"
        javac -d "$TMPDIR_CMP/noop_java" "$TMPDIR_CMP/Noop.java" 2>/dev/null
        noop_cmd="java -cp $TMPDIR_CMP/noop_java Noop"
        ;;
      py)   noop_cmd="python3 -c pass" ;;
      rb)   noop_cmd="ruby -e nil" ;;
      js)
        command -v node >/dev/null 2>&1 || continue
        noop_cmd="node -e 0"
        ;;
      bb)
        command -v bb >/dev/null 2>&1 || continue
        noop_cmd="bb -e nil"
        ;;
      tgo)
        command -v tinygo >/dev/null 2>&1 || continue
        cat > "$TMPDIR_CMP/noop.go" << 'GOEOF'
package main
func main() {}
GOEOF
        tinygo build -opt=2 -o "$TMPDIR_CMP/noop_tgo" "$TMPDIR_CMP/noop.go" 2>/dev/null
        noop_cmd="$TMPDIR_CMP/noop_tgo"
        ;;
      *)    continue ;;
    esac

    ms=$(hf_mean_ms "$noop_cmd")
    STARTUP_MS["$lang"]="$ms"
    printf "  %-12s %8s ms\n" "$(lang_display_name "$lang")" "$ms"
  done
  echo ""
fi

# --- Collect results ---
# Associative arrays: COLD_MS[bench:lang]=value, WARM_MS[bench:lang]=value
declare -A COLD_MS
declare -A WARM_MS

echo -e "${BOLD}Running benchmarks...${RESET}\n"

for bench_dir in "${BENCH_DIRS[@]}"; do
  bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
  meta_name=$(yq '.name' "$bench_dir/meta.yaml")
  expected=$(yq '.expected_output' "$bench_dir/meta.yaml")

  echo -e "${BOLD}=== $meta_name ($bench_name) ===${RESET}"

  for lang in "${LANGS[@]}"; do
    cmd=$(lang_command "$lang" "$bench_dir" 2>/dev/null) || continue

    # Verify output first (|| true to handle BB/runtime errors with pipefail)
    actual=$(eval "$cmd" 2>&1 || true)
    actual=$(echo "$actual" | head -1 | tr -d '[:space:]')
    expected_clean=$(echo "$expected" | tr -d '[:space:]')
    if [[ "$actual" != "$expected_clean" ]]; then
      echo -e "  ${RED}SKIP${RESET} $(lang_display_name "$lang"): output mismatch (got=$actual expected=$expected_clean)"
      continue
    fi

    # Measure
    cold=$(hf_mean_ms "$cmd")
    COLD_MS["${bench_name}:${lang}"]="$cold"

    if [[ "$MODE" == "warm" || "$MODE" == "both" ]]; then
      startup="${STARTUP_MS[$lang]:-0}"
      warm=$(python3 -c "print(f'{max(0, $cold - $startup):.1f}')")
      WARM_MS["${bench_name}:${lang}"]="$warm"
    fi

    # Progress indicator
    printf "  %-12s %8s ms" "$(lang_display_name "$lang")" "$cold"
    if [[ "$MODE" == "warm" || "$MODE" == "both" ]]; then
      printf "  (warm: %s ms)" "${WARM_MS[${bench_name}:${lang}]}"
    fi
    echo ""
  done
  echo ""
done

# --- Display results table ---
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Cross-Language Benchmark Comparison${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"

# Sort order: c, zig, java, cw, bb, rb, py (fast to slow typical order)
DISPLAY_ORDER=(c zig java tgo cw js bb rb py)

for bench_dir in "${BENCH_DIRS[@]}"; do
  bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
  meta_name=$(yq '.name' "$bench_dir/meta.yaml")

  echo ""
  echo -e "${BOLD}  $meta_name ($bench_name)${RESET}"

  # Header
  if [[ "$MODE" == "both" ]]; then
    printf "  ${DIM}%-14s %10s %10s %12s${RESET}\n" "Lang" "Cold (ms)" "Warm (ms)" "vs CW (cold)"
    echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"
  elif [[ "$MODE" == "warm" ]]; then
    printf "  ${DIM}%-14s %10s %12s${RESET}\n" "Lang" "Warm (ms)" "vs CW (warm)"
    echo -e "  ${DIM}──────────────────────────────────────────────${RESET}"
  else
    printf "  ${DIM}%-14s %10s %12s${RESET}\n" "Lang" "Cold (ms)" "vs CW (cold)"
    echo -e "  ${DIM}──────────────────────────────────────────────${RESET}"
  fi

  cw_cold="${COLD_MS[${bench_name}:cw]:-}"
  cw_warm="${WARM_MS[${bench_name}:cw]:-}"

  for lang in "${DISPLAY_ORDER[@]}"; do
    cold_val="${COLD_MS[${bench_name}:${lang}]:-}"
    warm_val="${WARM_MS[${bench_name}:${lang}]:-}"
    [[ -z "$cold_val" && -z "$warm_val" ]] && continue

    display=$(lang_display_name "$lang")

    # Calculate ratio vs CW
    ratio_cold=""
    ratio_warm=""
    if [[ -n "$cw_cold" && -n "$cold_val" ]]; then
      ratio_cold=$(python3 -c "
cw=$cw_cold; v=$cold_val
if cw > 0: print(f'{v/cw:.1f}x')
else: print('N/A')
")
    fi
    if [[ -n "$cw_warm" && -n "$warm_val" ]]; then
      ratio_warm=$(python3 -c "
cw=$cw_warm; v=$warm_val
if cw > 0: print(f'{v/cw:.1f}x')
else: print('N/A')
")
    fi

    # Color: green if faster than CW, red if slower
    color="$RESET"
    if [[ "$lang" == "cw" ]]; then
      color="$CYAN"
      ratio_cold="1.0x (base)"
      ratio_warm="1.0x (base)"
    elif [[ -n "$ratio_cold" ]]; then
      faster=$(python3 -c "print('y' if ${cold_val:-0} < ${cw_cold:-0} else 'n')")
      [[ "$faster" == "y" ]] && color="$GREEN" || color="$YELLOW"
    fi

    if [[ "$MODE" == "both" ]]; then
      printf "  ${color}%-14s %10s %10s %12s${RESET}\n" "$display" "${cold_val:-N/A}" "${warm_val:-N/A}" "${ratio_cold:-N/A}"
    elif [[ "$MODE" == "warm" ]]; then
      printf "  ${color}%-14s %10s %12s${RESET}\n" "$display" "${warm_val:-N/A}" "${ratio_warm:-N/A}"
    else
      printf "  ${color}%-14s %10s %12s${RESET}\n" "$display" "${cold_val:-N/A}" "${ratio_cold:-N/A}"
    fi
  done
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"

# --- YAML output ---
if [[ -n "$YAML_FILE" ]]; then
  echo -e "\n${CYAN}Writing YAML to $YAML_FILE...${RESET}"

  {
    echo "# Cross-language benchmark comparison"
    echo "# Generated: $(date -Iseconds)"
    echo ""
    echo "env:"
    echo "  cpu: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
    echo "  ram: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
    echo "  os: $(uname -s) $(uname -r)"
    echo "  tool: hyperfine"
    echo "  runs: $RUNS"
    echo "  warmup: $WARMUP"
    echo ""
    echo "date: \"$(date +%Y-%m-%d)\""
    echo ""

    # Startup times
    if [[ "$MODE" == "warm" || "$MODE" == "both" ]]; then
      echo "startup_ms:"
      for lang in "${ALL_LANGS[@]}"; do
        val="${STARTUP_MS[$lang]:-}"
        [[ -n "$val" ]] && echo "  $lang: $val"
      done
      echo ""
    fi

    echo "benchmarks:"
    for bench_dir in "${BENCH_DIRS[@]}"; do
      bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
      echo "  $bench_name:"
      if [[ "$MODE" == "cold" || "$MODE" == "both" ]]; then
        echo "    cold:"
        for lang in "${ALL_LANGS[@]}"; do
          val="${COLD_MS[${bench_name}:${lang}]:-}"
          [[ -n "$val" ]] && echo "      $lang: $val"
        done
      fi
      if [[ "$MODE" == "warm" || "$MODE" == "both" ]]; then
        echo "    warm:"
        for lang in "${ALL_LANGS[@]}"; do
          val="${WARM_MS[${bench_name}:${lang}]:-}"
          [[ -n "$val" ]] && echo "      $lang: $val"
        done
      fi
    done
  } > "$YAML_FILE"

  echo -e "${GREEN}YAML written to $YAML_FILE${RESET}"
fi

echo -e "\n${GREEN}Done.${RESET}"
