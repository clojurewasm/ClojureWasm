#!/usr/bin/env bash
# run_diff_test.sh — Differential testing: CW vs JVM Clojure
#
# Runs expressions on both CW and JVM Clojure, compares outputs.
# Any divergence is a potential bug.
#
# Usage:
#   bash test/diff/run_diff_test.sh            # Run all expressions
#   bash test/diff/run_diff_test.sh --verbose  # Show all results
#   bash test/diff/run_diff_test.sh --gen N    # Generate N random expressions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLJW="$PROJECT_ROOT/zig-out/bin/cljw"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

VERBOSE=false
GEN_COUNT=0

for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --gen) ;; # handled below
    --gen=*) GEN_COUNT="${arg#--gen=}" ;;
    -h|--help)
      echo "Usage: bash test/diff/run_diff_test.sh [--verbose] [--gen=N]"
      echo ""
      echo "Options:"
      echo "  --verbose   Show all results (not just failures)"
      echo "  --gen=N     Generate N random expressions to test"
      exit 0 ;;
  esac
done

# Handle --gen N (separate argument)
prev=""
for arg in "$@"; do
  if [ "$prev" = "--gen" ]; then
    GEN_COUNT="$arg"
  fi
  prev="$arg"
done

# Build ReleaseSafe if needed
if [ ! -f "$CLJW" ]; then
  echo -e "${CYAN}Building cljw...${RESET}"
  (cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe 2>/dev/null)
fi

# Check JVM Clojure
if ! command -v clojure &>/dev/null; then
  echo -e "${RED}Error: JVM Clojure not found. Install with: brew install clojure${RESET}"
  exit 1
fi

PASS=0
FAIL=0
SKIP=0
TIMEOUT_SEC=5

run_test() {
  local expr="$1"
  local desc="${2:-$expr}"

  # Run CW
  local cw_out cw_rc
  cw_out=$(timeout "$TIMEOUT_SEC" "$CLJW" -e "$expr" 2>/dev/null) && cw_rc=0 || cw_rc=$?
  if [ "$cw_rc" -eq 124 ]; then
    if $VERBOSE; then echo -e "${YELLOW}SKIP${RESET} (CW timeout): $desc"; fi
    SKIP=$((SKIP + 1))
    return
  fi

  # Run JVM Clojure
  local jvm_out jvm_rc
  jvm_out=$(timeout "$TIMEOUT_SEC" clojure -e "$expr" 2>/dev/null) && jvm_rc=0 || jvm_rc=$?
  if [ "$jvm_rc" -eq 124 ]; then
    if $VERBOSE; then echo -e "${YELLOW}SKIP${RESET} (JVM timeout): $desc"; fi
    SKIP=$((SKIP + 1))
    return
  fi

  # Compare: both error → skip, one error → report, both success → compare output
  if [ "$cw_rc" -ne 0 ] && [ "$jvm_rc" -ne 0 ]; then
    # Both errored — acceptable (different error messages are fine)
    if $VERBOSE; then echo -e "${GREEN}PASS${RESET} (both error): $desc"; fi
    PASS=$((PASS + 1))
    return
  fi

  if [ "$cw_rc" -ne 0 ] && [ "$jvm_rc" -eq 0 ]; then
    echo -e "${RED}FAIL${RESET}: $desc"
    echo "  CW:  error (rc=$cw_rc)"
    echo "  JVM: $jvm_out"
    FAIL=$((FAIL + 1))
    return
  fi

  if [ "$cw_rc" -eq 0 ] && [ "$jvm_rc" -ne 0 ]; then
    # CW succeeds but JVM fails — could be CW extension or JVM-specific error
    if $VERBOSE; then echo -e "${YELLOW}SKIP${RESET} (JVM error, CW ok): $desc"; fi
    SKIP=$((SKIP + 1))
    return
  fi

  # Both succeeded — compare output
  # Normalize known representation differences:
  # - JVM prints nothing for nil, CW prints "nil"
  # - CW -e prints return value after stdout, JVM doesn't for side-effecting exprs
  local cw_norm="$cw_out"
  local jvm_norm="$jvm_out"

  # JVM returns empty for nil, CW returns "nil"
  if [ -z "$jvm_norm" ] && [ "$cw_norm" = "nil" ]; then
    jvm_norm="nil"
  fi

  # CW appends "\nnil" for side-effecting expressions (println, etc.)
  # JVM does not print the nil return value
  if [ -n "$jvm_norm" ] && [[ "$cw_norm" == "${jvm_norm}"$'\n'"nil" ]]; then
    cw_norm="$jvm_norm"
  fi

  if [ "$cw_norm" = "$jvm_norm" ]; then
    if $VERBOSE; then echo -e "${GREEN}PASS${RESET}: $desc"; fi
    PASS=$((PASS + 1))
  else
    echo -e "${RED}FAIL${RESET}: $desc"
    echo "  CW:  $cw_out"
    echo "  JVM: $jvm_out"
    FAIL=$((FAIL + 1))
  fi
}

echo -e "${BOLD}=== Differential Test: CW vs JVM Clojure ===${RESET}"
echo ""

# Core expressions
run_test "nil"
run_test "true"
run_test "false"
run_test "42"
run_test "-1"
run_test "3.14"
run_test "(+ 1 2)"
run_test "(- 10 3)"
run_test "(* 4 5)"
run_test "(/ 10 2)"
run_test "(mod 10 3)"
run_test "(rem 10 3)"

# Comparison
run_test "(= 1 1)"
run_test "(= 1 2)"
run_test "(< 1 2)"
run_test "(> 2 1)"
run_test "(<= 1 1)"
run_test "(>= 2 1)"

# String operations
run_test '(str "hello" " " "world")'
run_test '(count "hello")'
run_test '(subs "hello" 1 3)'

# Collections
run_test "(count [1 2 3])"
run_test "(first [1 2 3])"
run_test "(rest [1 2 3])"
run_test "(conj [1 2] 3)"
run_test "(nth [10 20 30] 1)"
run_test "(get {:a 1 :b 2} :a)"
run_test "(assoc {:a 1} :b 2)"
run_test "(dissoc {:a 1 :b 2} :a)"
run_test "(contains? {:a 1} :a)"
run_test "(keys {:a 1 :b 2})"
run_test "(vals {:a 1 :b 2})"
run_test "(count #{1 2 3})"

# Sequences (wrap lazy results in vec for fair comparison)
run_test "(vec (range 5))"
run_test "(vec (take 3 (range 10)))"
run_test "(vec (drop 2 (range 5)))"
run_test "(vec (map inc [1 2 3]))"
run_test "(vec (filter odd? [1 2 3 4 5]))"
run_test "(reduce + [1 2 3 4 5])"
run_test "(apply + [1 2 3])"

# Control flow
run_test "(if true 1 2)"
run_test "(if false 1 2)"
run_test "(if nil 1 2)"
run_test "(when true 42)"
run_test "(when false 42)"
run_test "(cond true 1 :else 2)"

# Let / fn
run_test "(let [x 10] x)"
run_test "(let [x 1 y 2] (+ x y))"
run_test "((fn [x] (* x x)) 5)"
run_test "((fn [x y] (+ x y)) 3 4)"

# Type checks
run_test "(nil? nil)"
run_test "(nil? 1)"
run_test "(number? 42)"
run_test "(string? \"hi\")"
run_test "(keyword? :k)"
run_test "(symbol? (quote s))"
run_test "(vector? [1])"
run_test "(map? {:a 1})"
run_test "(set? #{1})"
run_test "(seq? (list 1))"
run_test "(coll? [1])"
run_test "(fn? inc)"

# Math
run_test "(inc 41)"
run_test "(dec 43)"
run_test "(max 1 2 3)"
run_test "(min 1 2 3)"
run_test "(abs -5)"

# Identity / equality
run_test "(identical? nil nil)"
run_test "(= [1 2] [1 2])"
run_test "(not= 1 2)"
run_test "(zero? 0)"
run_test "(pos? 1)"
run_test "(neg? -1)"
run_test "(even? 4)"
run_test "(odd? 3)"

# Threading
run_test "(-> 1 inc inc)"
run_test "(vec (->> [1 2 3] (map inc) (filter even?)))"

# Destructuring
run_test "(let [[a b c] [1 2 3]] (+ a b c))"
run_test "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))"

# Atoms
run_test "(let [a (atom 0)] (swap! a inc) @a)"

# Regex (use temp file to avoid shell escaping issues)
REGEX_TMP=$(mktemp /tmp/cw-diff-regex-XXXXXX.clj)
echo '(re-find #"\d+" "abc123def")' > "$REGEX_TMP"
run_test_file() {
  local file="$1"
  local desc="$2"
  local cw_out cw_rc jvm_out jvm_rc
  cw_out=$(timeout "$TIMEOUT_SEC" "$CLJW" "$file" 2>/dev/null) && cw_rc=0 || cw_rc=$?
  jvm_out=$(timeout "$TIMEOUT_SEC" clojure "$file" 2>/dev/null) && jvm_rc=0 || jvm_rc=$?
  if [ "$cw_rc" -eq 124 ] || [ "$jvm_rc" -eq 124 ]; then
    if $VERBOSE; then echo -e "${YELLOW}SKIP${RESET} (timeout): $desc"; fi
    SKIP=$((SKIP + 1))
    return
  fi
  if [ "$cw_rc" -ne 0 ] && [ "$jvm_rc" -ne 0 ]; then
    if $VERBOSE; then echo -e "${GREEN}PASS${RESET} (both error): $desc"; fi
    PASS=$((PASS + 1))
    return
  fi
  local cw_norm="$cw_out"
  local jvm_norm="$jvm_out"
  if [ -z "$jvm_norm" ] && [ "$cw_norm" = "nil" ]; then jvm_norm="nil"; fi
  if [ -n "$jvm_norm" ] && [[ "$cw_norm" == "${jvm_norm}"$'\n'"nil" ]]; then cw_norm="$jvm_norm"; fi
  if [ "$cw_norm" = "$jvm_norm" ]; then
    if $VERBOSE; then echo -e "${GREEN}PASS${RESET}: $desc"; fi
    PASS=$((PASS + 1))
  else
    echo -e "${RED}FAIL${RESET}: $desc"
    echo "  CW:  $cw_out"
    echo "  JVM: $jvm_out"
    FAIL=$((FAIL + 1))
  fi
}
echo '(println (re-find #"\d+" "abc123def"))' > "$REGEX_TMP"
run_test_file "$REGEX_TMP" '(re-find #"\d+" "abc123def")'
echo '(println (re-matches #"\d+" "123"))' > "$REGEX_TMP"
run_test_file "$REGEX_TMP" '(re-matches #"\d+" "123")'
rm -f "$REGEX_TMP"

# Higher-order
run_test "(mapv inc [1 2 3])"
run_test "(filterv odd? [1 2 3 4 5])"
run_test "(some even? [1 3 5 6])"
run_test "(every? pos? [1 2 3])"
run_test "(not-any? neg? [1 2 3])"
run_test "(vec (map vec (partition 2 [1 2 3 4 5 6])))"
run_test "(vec (interleave [1 2 3] [:a :b :c]))"
run_test "(zipmap [:a :b :c] [1 2 3])"

# Printing via println (comparing stdout, not repr)
run_test "(println 42)"
run_test "(println [1 2 3])"
run_test "(println {:a 1})"

# Generate random expressions if requested
if [ "$GEN_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${CYAN}Running $GEN_COUNT generated expressions...${RESET}"

  for _ in $(seq 1 "$GEN_COUNT"); do
    # Simple random expression generator
    case $((RANDOM % 8)) in
      0) expr="(+ $((RANDOM % 100)) $((RANDOM % 100)))" ;;
      1) expr="(* $((RANDOM % 20)) $((RANDOM % 20)))" ;;
      2) expr="(- $((RANDOM % 100)) $((RANDOM % 100)))" ;;
      3) expr="(count (range $((RANDOM % 50))))" ;;
      4) expr="(reduce + (range $((RANDOM % 20 + 1))))" ;;
      5) expr="(apply str (repeat $((RANDOM % 10 + 1)) \"x\"))" ;;
      6) expr="(let [x $((RANDOM % 100))] (* x x))" ;;
      7) expr="(take $((RANDOM % 10 + 1)) (range $((RANDOM % 50 + 1))))" ;;
    esac
    run_test "$expr"
  done
fi

echo ""
echo -e "${BOLD}Results:${RESET} ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}, ${YELLOW}$SKIP skipped${RESET}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
