#!/usr/bin/env bash
# test/e2e/phase14_quot_rem_mod_tower.sh — quot / rem / mod across the full
# numeric tower (Long / BigInt / Ratio / Float) + int / long coercion of
# BigInt / Ratio / BigDecimal. Grounded against JVM Clojure (clj oracle):
# quot of a ratio/bigint operand is a BigInt (prints N); rem / mod of a ratio
# stay a Ratio; divide-by-zero throws for every category incl. float (unlike
# `/`, which yields IEEE Inf on the float path). Closes D-169 / D-170.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

# --- quot across the tower ---
assert_eq 'quot_long'      "$("$BIN" -e '(quot 10 3)')"     '3'
assert_eq 'quot_bigint'    "$("$BIN" -e '(quot 10N 3N)')"   '3N'
assert_eq 'quot_mixed'     "$("$BIN" -e '(quot 10 3N)')"    '3N'
assert_eq 'quot_float'     "$("$BIN" -e '(quot 10.0 3)')"   '3.0'
assert_eq 'quot_ratio'     "$("$BIN" -e '(quot 17/2 2)')"   '4N'
assert_eq 'quot_neg'       "$("$BIN" -e '(quot -7 3)')"     '-2'
assert_eq 'quot_neg_div'   "$("$BIN" -e '(quot 7 -3)')"     '-2'
assert_eq 'quot_floor'     "$("$BIN" -e '(quot 10.5 3)')"   '3.0'

# --- rem across the tower (sign of dividend) ---
assert_eq 'rem_long'       "$("$BIN" -e '(rem 10 3)')"      '1'
assert_eq 'rem_bigint'     "$("$BIN" -e '(rem 10N 3N)')"    '1N'
assert_eq 'rem_float'      "$("$BIN" -e '(rem 10.0 3)')"    '1.0'
assert_eq 'rem_ratio'      "$("$BIN" -e '(rem 17/2 2)')"    '1/2'
assert_eq 'rem_neg'        "$("$BIN" -e '(rem -7 3)')"      '-1'
assert_eq 'rem_neg_div'    "$("$BIN" -e '(rem 7 -3)')"      '1'
assert_eq 'rem_float_frac' "$("$BIN" -e '(rem 10.5 3)')"    '1.5'

# --- mod across the tower (sign of divisor) ---
assert_eq 'mod_long'       "$("$BIN" -e '(mod 10 3)')"      '1'
assert_eq 'mod_bigint'     "$("$BIN" -e '(mod 10N 3N)')"    '1N'
assert_eq 'mod_float'      "$("$BIN" -e '(mod 10.0 3)')"    '1.0'
assert_eq 'mod_ratio'      "$("$BIN" -e '(mod 17/2 2)')"    '1/2'
assert_eq 'mod_neg'        "$("$BIN" -e '(mod -7 3)')"      '2'
assert_eq 'mod_neg_div'    "$("$BIN" -e '(mod 7 -3)')"      '-2'
assert_eq 'mod_float_frac' "$("$BIN" -e '(mod 10.5 3)')"    '1.5'

# --- divide-by-zero throws for every category (incl. float — unlike `/`) ---
assert_has 'quot_zero'     "$("$BIN" -e '(quot 3N 0)' 2>&1)"   'Divide by zero'
assert_has 'rem_zero'      "$("$BIN" -e '(rem 10 0)' 2>&1)"    'Divide by zero'
assert_has 'mod_zero'      "$("$BIN" -e '(mod 10 0)' 2>&1)"    'Divide by zero'
assert_has 'quot_fzero'    "$("$BIN" -e '(quot 10.0 0)' 2>&1)" 'Divide by zero'

# --- int / long coercion across the tower ---
assert_eq 'int_bigint'     "$("$BIN" -e '(int 5N)')"        '5'
assert_eq 'int_ratio'      "$("$BIN" -e '(int 7/2)')"       '3'
assert_eq 'int_ratio_neg'  "$("$BIN" -e '(int -7/2)')"      '-3'
assert_eq 'int_float'      "$("$BIN" -e '(int 3.9)')"       '3'
assert_eq 'int_bigdec'     "$("$BIN" -e '(int 10.5M)')"     '10'
assert_eq 'long_bigint'    "$("$BIN" -e '(long 5N)')"       '5'
assert_eq 'long_ratio'     "$("$BIN" -e '(long 7/2)')"      '3'

echo "OK — phase14_quot_rem_mod_tower (32 cases) green"
