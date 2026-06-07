#!/usr/bin/env bash
# build_bench.sh — Benchmark `cljw build` artifacts
#
# Measures:
#   1. cljw build command time (hyperfine)
#   2. Built binary size
#   3. Built binary startup time (hyperfine)
#   4. Built binary benchmark vs direct execution
#
# Usage:
#   bash bench/build_bench.sh           # Full measurement
#   bash bench/build_bench.sh --quick   # Fast check (1 run each)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

RUNS=3
WARMUP=1

for arg in "$@"; do
  case "$arg" in
    --quick)  RUNS=1; WARMUP=0 ;;
    -h|--help)
      echo "Usage: bash bench/build_bench.sh [--quick]"
      exit 0 ;;
  esac
done

# Build ReleaseSafe if not already
echo -e "${CYAN}Building ReleaseSafe...${RESET}"
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe 2>/dev/null)

# Test program: fibonacci
BENCH_SRC="$SCRIPT_DIR/benchmarks/01_fib_recursive/bench.clj"
BUILD_OUT="/tmp/cljw-bench-built-app"

echo ""
echo -e "${BOLD}=== cljw build Benchmarks ===${RESET}"
echo ""

# 1. Build time
echo -e "${CYAN}1. Build command time${RESET}"
rm -f "$BUILD_OUT"
hyperfine -N --warmup "$WARMUP" --runs "$RUNS" \
  --prepare "rm -f $BUILD_OUT" \
  "$CLJW build $BENCH_SRC -o $BUILD_OUT"
echo ""

# 2. Built binary size
echo -e "${CYAN}2. Built binary size${RESET}"
if [ ! -f "$BUILD_OUT" ]; then
  "$CLJW" build "$BENCH_SRC" -o "$BUILD_OUT" 2>/dev/null
fi
SIZE=$(stat -f%z "$BUILD_OUT" 2>/dev/null || stat -c%s "$BUILD_OUT" 2>/dev/null)
echo "  Built binary: $SIZE bytes ($(echo "scale=2; $SIZE / 1048576" | bc)MB)"
echo ""

# 3. Built binary startup
echo -e "${CYAN}3. Built binary startup time${RESET}"
hyperfine -N --warmup "$WARMUP" --runs "$RUNS" "$BUILD_OUT"
echo ""

# 4. Direct execution comparison
echo -e "${CYAN}4. Direct execution vs built binary${RESET}"
hyperfine -N --warmup "$WARMUP" --runs "$RUNS" \
  "$CLJW $BENCH_SRC" \
  "$BUILD_OUT"
echo ""

# 5. Simple app (require + pprint)
REQUIRE_SRC="/tmp/cljw-bench-require.clj"
REQUIRE_OUT="/tmp/cljw-bench-require-app"
cat > "$REQUIRE_SRC" << 'CLOJURE'
(require '[clojure.pprint :as pp])
(pp/pprint {:result (vec (map inc (range 10)))})
CLOJURE

echo -e "${CYAN}5. Built binary with require (pprint)${RESET}"
rm -f "$REQUIRE_OUT"
"$CLJW" build "$REQUIRE_SRC" -o "$REQUIRE_OUT" 2>/dev/null
RSIZE=$(stat -f%z "$REQUIRE_OUT" 2>/dev/null || stat -c%s "$REQUIRE_OUT" 2>/dev/null)
echo "  Built binary: $RSIZE bytes ($(echo "scale=2; $RSIZE / 1048576" | bc)MB)"
hyperfine -N --warmup "$WARMUP" --runs "$RUNS" "$REQUIRE_OUT"

rm -f "$BUILD_OUT" "$REQUIRE_OUT" "$REQUIRE_SRC"

echo ""
echo -e "${GREEN}Done.${RESET}"
