#!/usr/bin/env bash
# test/e2e/phase14_double_float.sh — double / float coercion over the whole
# numeric tower (D-134). cw v1 has one f64 float type, so double ≡ float.
# integer/char exact; big_int/ratio/big_decimal lossy round-to-nearest.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'd_int'    "$("$BIN" -e '(double 3)')"          '3.0'
assert_eq 'f_int'    "$("$BIN" -e '(float 3)')"           '3.0'
assert_eq 'd_float'  "$("$BIN" -e '(double 1.5)')"        '1.5'
assert_eq 'd_char'   "$("$BIN" -e '(double (char 65))')"  '65.0'
assert_eq 'd_ratio'  "$("$BIN" -e '(double 1/2)')"        '0.5'
assert_eq 'd_ratio2' "$("$BIN" -e '(double 3/4)')"        '0.75'
# D-166: 1e19 ≥ 1e7 → scientific notation (was wrongly pinned as full decimal
# before the float-printer fix; clj prints `1.0E19`).
assert_eq 'd_bigint' "$("$BIN" -e '(double 10000000000000000000N)')" '1.0E19'
assert_eq 'd_bigdec' "$("$BIN" -e '(double 1.50M)')"      '1.5'
assert_eq 'd_eq'     "$("$BIN" -e '(= 0.5 (double 1/2))')" 'true'
assert_has 'd_type'  "$("$BIN" -e '(double "x")' 2>&1)"   'expected number'
echo "OK — phase14_double_float smoke (10 cases) green"
