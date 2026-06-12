#!/usr/bin/env bash
# test/e2e/phase14_rationalize.sh — rationalize (clojure.core, D-134). Exact
# rational from a number: integer/bigint/ratio pass through; a float converts
# via its DECIMAL representation (0.1 → 1/10, JVM-faithful — not the binary
# fraction). Composes with numerator/denominator.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'half'    "$("$BIN" -e '(rationalize 1.5)')"   '3/2'
assert_eq 'tenth'   "$("$BIN" -e '(rationalize 0.1)')"   '1/10'
assert_eq 'pi2'     "$("$BIN" -e '(rationalize 3.14)')"  '157/50'
assert_eq 'neg'     "$("$BIN" -e '(rationalize -1.5)')"  '-3/2'
assert_eq 'whole'   "$("$BIN" -e '(rationalize 3.0)')"   '3'
assert_eq 'zero'    "$("$BIN" -e '(rationalize 0.0)')"   '0'
assert_eq 'quarter' "$("$BIN" -e '(rationalize 0.25)')"  '1/4'
assert_eq 'int_pt'  "$("$BIN" -e '(rationalize 5)')"     '5'
assert_eq 'ratio_pt' "$("$BIN" -e '(rationalize 1/3)')"  '1/3'
assert_eq 'eq'      "$("$BIN" -e '(= 1/10 (rationalize 0.1))')" 'true'
# composes with the ratio accessors
assert_eq 'num'     "$("$BIN" -e '(numerator (rationalize 3.14))')"   '157'
assert_eq 'den'     "$("$BIN" -e '(denominator (rationalize 3.14))')" '50'
assert_has 'badtype' "$("$BIN" -e '(rationalize "x")' 2>&1)"          'expected number'
echo "OK — phase14_rationalize smoke (13 cases) green"
