#!/usr/bin/env bash
# record.sh — Record benchmark results to bench/history.yaml
#
# Usage:
#   bash bench/record.sh --id="24A.3" --reason="Fused reduce"
#   bash bench/record.sh --id="24A.3" --reason="Fused reduce" --overwrite
#   bash bench/record.sh --id="24A.3" --reason="Fused reduce" --bench=fib_recursive
#   bash bench/record.sh --id="24A.3" --reason="Fused reduce" --runs=10
#   bash bench/record.sh --id="24A.3" --reason="Fused reduce" --warmup=3
#   bash bench/record.sh --delete="24A.3"
#
# All measurements use: hyperfine (ReleaseSafe, VM backend)
# Results appended to bench/history.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HISTORY_FILE="$SCRIPT_DIR/history.yaml"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"

# --- Defaults ---
ID=""
REASON=""
OVERWRITE=false
DELETE_ID=""
BENCH_FILTER=""
RUNS=5
WARMUP=2

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --id=*)       ID="${arg#--id=}" ;;
    --reason=*)   REASON="${arg#--reason=}" ;;
    --overwrite)  OVERWRITE=true ;;
    --delete=*)   DELETE_ID="${arg#--delete=}" ;;
    --bench=*)    BENCH_FILTER="${arg#--bench=}" ;;
    --runs=*)     RUNS="${arg#--runs=}" ;;
    --warmup=*)   WARMUP="${arg#--warmup=}" ;;
    -h|--help)
      echo "Usage: bash bench/record.sh --id=ID --reason=REASON [OPTIONS]"
      echo ""
      echo "Required:"
      echo "  --id=ID           Entry identifier (e.g. '24A.3', 'pre-24')"
      echo "  --reason=REASON   Why this measurement was taken"
      echo ""
      echo "Options:"
      echo "  --overwrite       Replace existing entry with same id"
      echo "  --delete=ID       Delete entry by id (no benchmark run)"
      echo "  --bench=NAME      Run specific benchmark only (e.g. fib_recursive)"
      echo "  --runs=N          Number of hyperfine runs (default: 5)"
      echo "  --warmup=N        Number of warmup runs (default: 2)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Delete mode ---
if [[ -n "$DELETE_ID" ]]; then
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "No history file found" >&2
    exit 1
  fi
  # Count entries before
  before=$(yq '.entries | length' "$HISTORY_FILE")
  # Delete matching entry
  yq -i "del(.entries[] | select(.id == \"$DELETE_ID\"))" "$HISTORY_FILE"
  after=$(yq '.entries | length' "$HISTORY_FILE")
  if [[ "$before" == "$after" ]]; then
    echo "Entry '$DELETE_ID' not found" >&2
    exit 1
  fi
  echo "Deleted entry '$DELETE_ID' ($before -> $after entries)"
  exit 0
fi

# --- Validate arguments ---
if [[ -z "$ID" || -z "$REASON" ]]; then
  echo "Error: --id and --reason are required" >&2
  echo "Run with --help for usage" >&2
  exit 1
fi

# --- Check for duplicate id ---
if [[ -f "$HISTORY_FILE" ]] && ! $OVERWRITE; then
  existing=$(yq ".entries[] | select(.id == \"$ID\") | .id" "$HISTORY_FILE" 2>/dev/null || echo "")
  if [[ -n "$existing" ]]; then
    echo "Error: Entry '$ID' already exists. Use --overwrite to replace." >&2
    exit 1
  fi
fi

# --- Build ReleaseSafe ---
echo "Building ReleaseSafe..."
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe) || {
  echo "Build failed" >&2
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
  echo "No benchmarks found" >&2
  exit 1
fi

echo "Recording: id=$ID reason=\"$REASON\""
echo "Benchmarks: ${#BENCH_DIRS[@]}, runs=$RUNS, warmup=$WARMUP"
echo ""

# --- Run benchmarks with hyperfine ---
TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

declare -A BENCH_RESULTS  # bench_name -> "time_ms:mem_mb"

for bench_dir in "${BENCH_DIRS[@]}"; do
  bench_name=$(basename "$bench_dir" | sed 's/^[0-9]*_//')
  json_file="$TMPDIR_BENCH/${bench_name}.json"

  expected=$(yq '.expected_output' "$bench_dir/meta.yaml")

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
import json, sys
with open('$json_file') as f:
    data = json.load(f)
r = data['results'][0]
time_ms = round(r['mean'] * 1000)
mem_bytes = r.get('memory_usage_byte', [])
if mem_bytes:
    mem_mb = round(max(mem_bytes) / 1048576, 1)
else:
    mem_mb = 0.0
print(f'{time_ms}:{mem_mb}')
")

  IFS=':' read -r time_ms mem_mb <<< "$result"
  printf "%6s ms  %6s MB\n" "$time_ms" "$mem_mb"

  # Verify output
  actual=$($CLJW "$bench_dir/bench.clj" 2>&1 | head -1 | tr -d '[:space:]')
  expected_clean=$(echo "$expected" | tr -d '[:space:]')
  if [[ "$actual" != "$expected_clean" ]]; then
    echo "    WARNING: output mismatch (expected=$expected_clean actual=$actual)"
  fi

  BENCH_RESULTS["$bench_name"]="${time_ms}:${mem_mb}"
done

echo ""

# --- Build entry and write to history.yaml ---
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)

# Initialize history file if needed
if [[ ! -f "$HISTORY_FILE" ]]; then
  cat > "$HISTORY_FILE" << 'INITEOF'
env:
  cpu: Apple M4 Pro
  ram: 48 GB
  os: Darwin 25.2.0
  tool: hyperfine
entries: []
INITEOF
fi

# Remove existing entry if overwriting
if $OVERWRITE; then
  yq -i "del(.entries[] | select(.id == \"$ID\"))" "$HISTORY_FILE"
fi

# Build the entry as a YAML fragment, then append
ENTRY_FILE=$(mktemp)
cat > "$ENTRY_FILE" << ENTRYEOF
id: "$ID"
date: "$DATE"
reason: "$REASON"
commit: "$COMMIT"
build: ReleaseSafe
backend: vm
results:
ENTRYEOF

# Canonical order for consistent history.yaml output
BENCH_ORDER=(
  fib_recursive fib_loop tak arith_loop map_filter_reduce
  vector_ops map_ops list_build sieve nqueens
  atom_swap gc_stress lazy_chain transduce keyword_lookup
  protocol_dispatch nested_update string_ops multimethod_dispatch real_workload
)
for key in "${BENCH_ORDER[@]}"; do
  if [[ -v "BENCH_RESULTS[$key]" ]]; then
    IFS=':' read -r t m <<< "${BENCH_RESULTS[$key]}"
    echo "  $key: {time_ms: $t, mem_mb: $m}" >> "$ENTRY_FILE"
  fi
done

# Append entry to history
yq -i ".entries += [load(\"$ENTRY_FILE\")]" "$HISTORY_FILE"
rm -f "$ENTRY_FILE"

echo "Recorded entry '$ID' (${#BENCH_RESULTS[@]} benchmarks)"
echo "Done. Results in $HISTORY_FILE"
