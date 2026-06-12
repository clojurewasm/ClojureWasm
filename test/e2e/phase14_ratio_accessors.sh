#!/usr/bin/env bash
# test/e2e/phase14_ratio_accessors.sh — numerator / denominator (D-134).
# Ratio accessors over runtime/numeric/ratio.zig; collapse to a Long when the
# part fits i48 (so a small numerator prints `3`, not `3N` — JVM-faithful).
# A non-ratio arg is a type error (only Ratio carries a numerator on the JVM).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'num'        "$("$BIN" -e '(numerator 3/4)')"   '3'
assert_eq 'den'        "$("$BIN" -e '(denominator 3/4)')" '4'
assert_eq 'num_reduce' "$("$BIN" -e '(numerator 6/8)')"   '3'
assert_eq 'den_reduce' "$("$BIN" -e '(denominator 6/8)')" '4'
assert_eq 'num_neg'    "$("$BIN" -e '(numerator -3/4)')"  '-3'
assert_eq 'den_neg'    "$("$BIN" -e '(denominator -3/4)')" '4'
# round-trip: (/ num den) reconstructs the ratio
assert_eq 'roundtrip'  "$("$BIN" -e '(= 22/7 (/ (numerator 22/7) (denominator 22/7)))')" 'true'
# collapses to Long (so it = a Long literal, prints without N)
assert_eq 'long_eq'    "$("$BIN" -e '(= 3 (numerator 3/4))')" 'true'
# non-ratio is a type error
assert_has 'num_int'   "$("$BIN" -e '(numerator 5)' 2>&1)"   'expected ratio'
assert_has 'den_float' "$("$BIN" -e '(denominator 1.5)' 2>&1)" 'expected ratio'
echo "OK — phase14_ratio_accessors smoke (10 cases) green"
