#!/usr/bin/env bash
# test/e2e/phase14_num_predicates.sh — int? / double? / NaN? / infinite?
# (D-134). int? ≡ integer?, double? ≡ float? (cw v1 has one integer + one
# float tag). NaN?/infinite? take the JVM coercion contract (integer →
# false, non-number → type error). NaN/Inf values come from IEEE float
# division (see phase14_float_div.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

# int? / double?
assert_eq 'int_y'    "$("$BIN" -e '(int? 5)')"      'true'
assert_eq 'int_n'    "$("$BIN" -e '(int? 1.5)')"    'false'
assert_eq 'int_str'  "$("$BIN" -e '(int? "x")')"    'false'
assert_eq 'dbl_y'    "$("$BIN" -e '(double? 1.5)')" 'true'
assert_eq 'dbl_n'    "$("$BIN" -e '(double? 5)')"   'false'
# NaN?
assert_eq 'nan_y'    "$("$BIN" -e '(NaN? (/ 0.0 0.0))')" 'true'
assert_eq 'nan_inf'  "$("$BIN" -e '(NaN? (/ 1.0 0.0))')" 'false'
assert_eq 'nan_flt'  "$("$BIN" -e '(NaN? 1.5)')"   'false'
assert_eq 'nan_int'  "$("$BIN" -e '(NaN? 5)')"     'false'
assert_has 'nan_str' "$("$BIN" -e '(NaN? "x")' 2>&1)" 'expected number'
# infinite?
assert_eq 'inf_pos'  "$("$BIN" -e '(infinite? (/ 1.0 0.0))')"  'true'
assert_eq 'inf_neg'  "$("$BIN" -e '(infinite? (/ -1.0 0.0))')" 'true'
assert_eq 'inf_nan'  "$("$BIN" -e '(infinite? (/ 0.0 0.0))')"  'false'
assert_eq 'inf_flt'  "$("$BIN" -e '(infinite? 1.5)')" 'false'
assert_eq 'inf_int'  "$("$BIN" -e '(infinite? 5)')"   'false'
echo "OK — phase14_num_predicates smoke (15 cases) green"
