#!/usr/bin/env bash
# E2E test runner for ClojureWasm
# Runs all .clj test files in test/e2e/ subdirectories
# Usage: bash test/e2e/run_e2e.sh [--tree-walk] [--dir=wasm]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLJW="$ROOT_DIR/zig-out/bin/cljw"

# Parse args
TREE_WALK=""
TEST_DIR=""
for arg in "$@"; do
  case "$arg" in
    --tree-walk) TREE_WALK="--tree-walk" ;;
    --dir=*) TEST_DIR="${arg#--dir=}" ;;
  esac
done

# Build if needed
if [ ! -f "$CLJW" ]; then
  echo "Building cljw..."
  (cd "$ROOT_DIR" && zig build)
fi

# Collect test files
if [ -n "$TEST_DIR" ]; then
  TEST_FILES=$(find "$SCRIPT_DIR/$TEST_DIR" -name '*_test.clj' -type f | sort)
else
  TEST_FILES=$(find "$SCRIPT_DIR" -name '*_test.clj' -type f | sort)
fi

if [ -z "$TEST_FILES" ]; then
  echo "No test files found."
  exit 1
fi

PASS=0
FAIL=0
ERRORS=""
BACKEND="${TREE_WALK:-VM}"
[ -z "$TREE_WALK" ] && BACKEND="VM"
[ -n "$TREE_WALK" ] && BACKEND="TreeWalk"

echo "=== E2E Tests ($BACKEND) ==="
echo ""

while IFS= read -r test_file; do
  rel_path="${test_file#$SCRIPT_DIR/}"
  printf "  %-40s " "$rel_path"

  # Run test, capture output and exit code
  if output=$("$CLJW" $TREE_WALK "$test_file" 2>&1); then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n--- $rel_path ---\n$output\n"
  fi
done <<< "$TEST_FILES"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "=== Failures ==="
  printf "$ERRORS"
  exit 1
fi
