#!/usr/bin/env bash
# test/e2e/phase14_math_exact.sh — Math/*Exact family (§A26 / D-172): i64
# arithmetic that throws ArithmeticException on overflow instead of wrapping
# (a distinct mechanism from floorDiv/floorMod). Grounded vs JVM Clojure:
# Math/addExact uses the long overload, so 2^31-1 + 1 does NOT overflow; only
# i64 overflow throws. toIntExact range-checks against i32.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

# --- in-range results (i64 arithmetic, no overflow) ---
assert_eq 'addExact'       "$("$BIN" -e '(Math/addExact 2 3)')"              '5'
assert_eq 'addExact_i32ok' "$("$BIN" -e '(Math/addExact 2147483647 1)')"     '2147483648'
assert_eq 'subExact'       "$("$BIN" -e '(Math/subtractExact 10 4)')"        '6'
assert_eq 'mulExact'       "$("$BIN" -e '(Math/multiplyExact 100 200)')"     '20000'
assert_eq 'negExact'       "$("$BIN" -e '(Math/negateExact 5)')"             '-5'
assert_eq 'incExact'       "$("$BIN" -e '(Math/incrementExact 9)')"          '10'
assert_eq 'decExact'       "$("$BIN" -e '(Math/decrementExact 9)')"          '8'
assert_eq 'toIntExact'     "$("$BIN" -e '(Math/toIntExact 5)')"              '5'
assert_eq 'toIntExact_min' "$("$BIN" -e '(Math/toIntExact -2147483648)')"    '-2147483648'

# --- overflow throws ArithmeticException (catalog: "integer overflow") ---
assert_has 'add_ovf'  "$("$BIN" -e '(Math/addExact 9223372036854775807 1)' 2>&1)"        'integer overflow'
assert_has 'mul_ovf'  "$("$BIN" -e '(Math/multiplyExact 3000000000 4000000000)' 2>&1)"   'integer overflow'
assert_has 'sub_ovf'  "$("$BIN" -e '(Math/subtractExact -9223372036854775808 1)' 2>&1)"  'integer overflow'
assert_has 'neg_ovf'  "$("$BIN" -e '(Math/negateExact -9223372036854775808)' 2>&1)"      'integer overflow'
assert_has 'inc_ovf'  "$("$BIN" -e '(Math/incrementExact 9223372036854775807)' 2>&1)"    'integer overflow'
assert_has 'dec_ovf'  "$("$BIN" -e '(Math/decrementExact -9223372036854775808)' 2>&1)"   'integer overflow'
assert_has 'toint_ovf' "$("$BIN" -e '(Math/toIntExact 2147483648)' 2>&1)"                'integer overflow'

# --- overflow is catchable as ArithmeticException (ADR-0060 bridge, F-011) ---
assert_eq 'catch_arith' "$("$BIN" -e '(try (Math/addExact 9223372036854775807 1) (catch ArithmeticException e :caught))')" ':caught'

echo "OK — phase14_math_exact (18 cases) green"
