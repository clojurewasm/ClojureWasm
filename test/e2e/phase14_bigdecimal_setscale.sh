#!/usr/bin/env bash
# test/e2e/phase14_bigdecimal_setscale.sh — D-097 / D-420.
# BigDecimal instance-method surface: `(.setScale bd newScale roundingMode)`
# with the JVM `ROUND_*` int constants. cljw's BigDecimal was a method-less
# TypeDescriptor reservation (D-097); this wires setScale + the rounding modes
# (the math.numeric-tower floor/ceil path, D-420). Expected values are the
# `clj` oracle (java.math.BigDecimal.setScale) ground truth.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
sc() { "$BIN" -e "(str (.setScale (bigdec \"$1\") $2 BigDecimal/ROUND_$3))" 2>&1 | awk 'END{print}'; }

# ROUND constants resolve as static fields (BigDecimal/ROUND_HALF_UP == 4).
assert_eq 'round_const' "$("$BIN" -e '[BigDecimal/ROUND_UP BigDecimal/ROUND_DOWN BigDecimal/ROUND_CEILING BigDecimal/ROUND_FLOOR BigDecimal/ROUND_HALF_UP BigDecimal/ROUND_HALF_DOWN BigDecimal/ROUND_HALF_EVEN BigDecimal/ROUND_UNNECESSARY]' 2>&1 | awk 'END{print}')" '[0 1 2 3 4 5 6 7]'

# setScale to 0 — rounding-mode matrix (clj oracle). `sc` wraps in `(str …)`
# (drops the `M` suffix), which `cljw -e` echoes pr-quoted, so the want is "N".
assert_eq 'half_up_2.5'    "$(sc 2.5  0 HALF_UP)"    '"3"'
assert_eq 'half_down_2.5'  "$(sc 2.5  0 HALF_DOWN)"  '"2"'
assert_eq 'half_even_2.5'  "$(sc 2.5  0 HALF_EVEN)"  '"2"'
assert_eq 'half_even_3.5'  "$(sc 3.5  0 HALF_EVEN)"  '"4"'
assert_eq 'floor_2.5'      "$(sc 2.5  0 FLOOR)"      '"2"'
assert_eq 'ceiling_2.5'    "$(sc 2.5  0 CEILING)"    '"3"'
assert_eq 'down_2.5'       "$(sc 2.5  0 DOWN)"       '"2"'
assert_eq 'up_2.5'         "$(sc 2.5  0 UP)"         '"3"'
assert_eq 'half_up_2.4'    "$(sc 2.4  0 HALF_UP)"    '"2"'
# negative values: FLOOR toward -inf, CEILING toward +inf, UP away from zero.
assert_eq 'floor_neg2.5'   "$(sc -2.5 0 FLOOR)"      '"-3"'
assert_eq 'ceiling_neg2.5' "$(sc -2.5 0 CEILING)"    '"-2"'
assert_eq 'up_neg2.5'      "$(sc -2.5 0 UP)"         '"-3"'
assert_eq 'down_neg2.5'    "$(sc -2.5 0 DOWN)"       '"-2"'
assert_eq 'half_up_neg2.5' "$(sc -2.5 0 HALF_UP)"    '"-3"'
# newScale >= scale: exact pad (no rounding), trailing zeros kept.
assert_eq 'pad_1.5_to_3'   "$(sc 1.5  3 FLOOR)"      '"1.500"'
assert_eq 'exact_2.50_to_0' "$(sc 2.00 0 UNNECESSARY)" '"2"'

# UNNECESSARY with a non-zero dropped remainder throws (no silent rounding).
if "$BIN" -e '(.setScale (bigdec "2.5") 0 BigDecimal/ROUND_UNNECESSARY)' >/dev/null 2>&1; then
    fail "unnecessary_throws: expected an error for a rounding-needed UNNECESSARY"
fi
echo "PASS unnecessary_throws"

# 2-arg setScale (no rounding mode) = JVM setScale(int) = ROUND_UNNECESSARY:
# rescales exactly, throws ArithmeticException if rounding would be needed.
assert_eq '2arg_pad'   "$("$BIN" -e '(str (.setScale (bigdec "1.5") 3))' 2>&1 | awk 'END{print}')"   '"1.500"'
assert_eq '2arg_exact' "$("$BIN" -e '(str (.setScale (bigdec "1.500") 1))' 2>&1 | awk 'END{print}')" '"1.5"'
if "$BIN" -e '(.setScale (bigdec "1.55") 1)' >/dev/null 2>&1; then
    fail "2arg_unnecessary_throws: expected an error for a rounding-needed 2-arg setScale"
fi
echo "PASS 2arg_unnecessary_throws"

# BigDecimal read accessors: scale / signum / unscaledValue / precision (clj oracle).
assert_eq 'scale'        "$("$BIN" -e '(.scale (bigdec "1.23"))' 2>&1 | awk 'END{print}')"               '2'
assert_eq 'signum_neg'   "$("$BIN" -e '(.signum (bigdec "-1.5"))' 2>&1 | awk 'END{print}')"              '-1'
assert_eq 'signum_zero'  "$("$BIN" -e '(.signum (bigdec "0.00"))' 2>&1 | awk 'END{print}')"              '0'
assert_eq 'unscaled'     "$("$BIN" -e '(str (.unscaledValue (bigdec "1.23")))' 2>&1 | awk 'END{print}')" '"123"'
assert_eq 'precision'    "$("$BIN" -e '(.precision (bigdec "123.45"))' 2>&1 | awk 'END{print}')"         '5'
assert_eq 'precision_zero' "$("$BIN" -e '(.precision (bigdec "0.00"))' 2>&1 | awk 'END{print}')"         '1'

# BigDecimal value transformers: negate / abs / toBigInteger / stripTrailingZeros.
assert_eq 'negate'      "$("$BIN" -e '(str (.negate (bigdec "1.5")))' 2>&1 | awk 'END{print}')"               '"-1.5"'
assert_eq 'abs_neg'     "$("$BIN" -e '(str (.abs (bigdec "-1.5")))' 2>&1 | awk 'END{print}')"                 '"1.5"'
assert_eq 'abs_pos'     "$("$BIN" -e '(str (.abs (bigdec "1.5")))' 2>&1 | awk 'END{print}')"                  '"1.5"'
assert_eq 'tobigint'    "$("$BIN" -e '(str (.toBigInteger (bigdec "1.99")))' 2>&1 | awk 'END{print}')"        '"1"'
assert_eq 'tobigint_neg' "$("$BIN" -e '(str (.toBigInteger (bigdec "-1.99")))' 2>&1 | awk 'END{print}')"      '"-1"'
assert_eq 'strip'       "$("$BIN" -e '(str (.stripTrailingZeros (bigdec "1.500")))' 2>&1 | awk 'END{print}')" '"1.5"'
assert_eq 'strip_e'     "$("$BIN" -e '(str (.stripTrailingZeros (bigdec "100")))' 2>&1 | awk 'END{print}')"   '"1E+2"'

# BigDecimal instance arithmetic + point shift (D-322 completion). clj-grounded.
assert_eq 'bd_add'      "$("$BIN" -e '(str (.add (bigdec "1.1") (bigdec "2.2")))' 2>&1 | awk 'END{print}')"        '"3.3"'
assert_eq 'bd_subtract' "$("$BIN" -e '(str (.subtract (bigdec "5.5") (bigdec "1.1")))' 2>&1 | awk 'END{print}')"   '"4.4"'
assert_eq 'bd_multiply' "$("$BIN" -e '(str (.multiply (bigdec "2.0") (bigdec "3.0")))' 2>&1 | awk 'END{print}')"   '"6.00"'
assert_eq 'bd_divide'   "$("$BIN" -e '(str (.divide (bigdec "10") (bigdec "4")))' 2>&1 | awk 'END{print}')"        '"2.5"'
assert_eq 'bd_mpl'      "$("$BIN" -e '(str (.movePointLeft (bigdec "150") 2))' 2>&1 | awk 'END{print}')"           '"1.50"'
assert_eq 'bd_mpr'      "$("$BIN" -e '(str (.movePointRight (bigdec "1.5") 2))' 2>&1 | awk 'END{print}')"          '"150"'
assert_eq 'bd_mpr_big'  "$("$BIN" -e '(str (.movePointRight (bigdec "12.34") 3))' 2>&1 | awk 'END{print}')"        '"12340"'
assert_eq 'bd_div_nonterm' "$("$BIN" -e '(try (.divide (bigdec "1") (bigdec "3")) (catch Throwable e :caught))' 2>&1 | awk 'END{print}')" ':caught'

# java.math.RoundingMode enum constants (ADR-0160) — host-enum singletons, NOT
# the deprecated ROUND_* ints. `str`/`class`/`=` match clj; only the opaque
# print form diverges (AD-002). `rm` drives setScale via the FQCN enum constant.
rm() { "$BIN" -e "(str (.setScale (bigdec \"$1\") $2 java.math.RoundingMode/$3))" 2>&1 | awk 'END{print}'; }

# All 8 constants resolve; (str e) = the bare JVM enum name (clj parity).
assert_eq 'rm_names' "$("$BIN" -e '(mapv str [java.math.RoundingMode/UP java.math.RoundingMode/DOWN java.math.RoundingMode/CEILING java.math.RoundingMode/FLOOR java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_DOWN java.math.RoundingMode/HALF_EVEN java.math.RoundingMode/UNNECESSARY])' 2>&1 | awk 'END{print}')" '["UP" "DOWN" "CEILING" "FLOOR" "HALF_UP" "HALF_DOWN" "HALF_EVEN" "UNNECESSARY"]'
# (class e) = the enum class (NOT Long — the int-ordinal anti-pattern); = is by
# identity (cached singleton), and an enum is NEVER `=` to its int ordinal (clj).
assert_eq 'rm_class'  "$("$BIN" -e '(class java.math.RoundingMode/HALF_UP)' 2>&1 | awk 'END{print}')" 'java.math.RoundingMode'
assert_eq 'rm_eq'     "$("$BIN" -e '(= java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_UP)' 2>&1 | awk 'END{print}')" 'true'
assert_eq 'rm_eq_int' "$("$BIN" -e '(= java.math.RoundingMode/HALF_UP 4)' 2>&1 | awk 'END{print}')" 'false'
# setScale accepts a RoundingMode enum constant (the clj-modern API). The bug
# this fixes: (.setScale (bigdec "3.14159") 2 java.math.RoundingMode/HALF_UP).
assert_eq 'rm_setscale'  "$(rm 3.14159 2 HALF_UP)" '"3.14"'
assert_eq 'rm_floor'     "$(rm 2.5 0 FLOOR)"       '"2"'
assert_eq 'rm_ceiling'   "$(rm 2.5 0 CEILING)"     '"3"'
assert_eq 'rm_half_even' "$(rm 2.5 0 HALF_EVEN)"   '"2"'
assert_eq 'rm_up_neg'    "$(rm -2.5 0 UP)"         '"-3"'

# BigDecimal method-surface gap-fill (ADR-0160 follow-up). clj-oracle-grounded.
# divide(divisor, scale, RoundingMode) + divide(divisor, RoundingMode) = the
# clj-modern rounding-division API; the no-mode (.divide a b) stays exact.
sm() { "$BIN" -e "$1" 2>&1 | awk 'END{print}'; }
assert_eq 'div_scale_mode' "$(sm '(str (.divide (bigdec "10") (bigdec "3") 2 java.math.RoundingMode/HALF_UP))')" '"3.33"'
assert_eq 'div_mode'       "$(sm '(str (.divide (bigdec "10") (bigdec "4") java.math.RoundingMode/HALF_UP))')"   '"3"'
assert_eq 'div_mode_int'   "$(sm '(str (.divide (bigdec "10") (bigdec "3") 2 BigDecimal/ROUND_HALF_UP))')"       '"3.33"'
assert_eq 'bd_pow'         "$(sm '(str (.pow (bigdec "2") 10))')"                       '"1024"'
assert_eq 'bd_pow0'        "$(sm '(str (.pow (bigdec "5") 0))')"                        '"1"'
assert_eq 'bd_remainder'   "$(sm '(str (.remainder (bigdec "10") (bigdec "3")))')"      '"1"'
assert_eq 'bd_rem_scale'   "$(sm '(str (.remainder (bigdec "10.5") (bigdec "3")))')"    '"1.5"'
assert_eq 'bd_rem_neg'     "$(sm '(str (.remainder (bigdec "-10") (bigdec "3")))')"     '"-1"'
assert_eq 'bd_rem_zero'    "$(sm '(str (.remainder (bigdec "7.5") (bigdec "2.5")))')"   '"0.0"'
assert_eq 'bd_divint'      "$(sm '(str (.divideToIntegralValue (bigdec "10") (bigdec "3")))')"   '"3"'
assert_eq 'bd_divint_sc'   "$(sm '(str (.divideToIntegralValue (bigdec "10.5") (bigdec "3")))')" '"3.0"'
assert_eq 'bd_max'         "$(sm '(str (.max (bigdec "1") (bigdec "2")))')"             '"2"'
assert_eq 'bd_min'         "$(sm '(str (.min (bigdec "1") (bigdec "2")))')"             '"1"'
assert_eq 'bd_compareto_eq' "$(sm '(.compareTo (bigdec "1.0") (bigdec "1.00"))')"       '0'
assert_eq 'bd_compareto_gt' "$(sm '(.compareTo (bigdec "2") (bigdec "1"))')"            '1'
assert_eq 'bd_compareto_lt' "$(sm '(.compareTo (bigdec "1") (bigdec "2"))')"            '-1'
# .equals is scale-SENSITIVE (JVM BigDecimal.equals): 1.0 != 1.00 (differ in scale),
# even though they are `=` by value and compareTo 0. This is the clj-parity fix.
assert_eq 'bd_equals_scale' "$(sm '(.equals (bigdec "1.0") (bigdec "1.00"))')"          'false'
assert_eq 'bd_equals_same'  "$(sm '(.equals (bigdec "1.0") (bigdec "1.0"))')"           'true'
assert_eq 'bd_intvalue'    "$(sm '(.intValue (bigdec "42.9"))')"                        '42'
assert_eq 'bd_longvalue'   "$(sm '(.longValue (bigdec "42.9"))')"                       '42'
assert_eq 'bd_doublevalue' "$(sm '(.doubleValue (bigdec "1.5"))')"                      '1.5'

# java.math.MathContext (D-511) — precision+rounding host object. clj-grounded.
assert_eq 'mc_round'      "$(sm '(str (.round (bigdec "123.456") (java.math.MathContext. 4)))')"                              '"123.5"'
assert_eq 'mc_round_mode' "$(sm '(str (.round (bigdec "123.456") (java.math.MathContext. 4 java.math.RoundingMode/FLOOR)))')" '"123.4"'
assert_eq 'mc_round_carry' "$(sm '(str (.round (bigdec "9.95") (java.math.MathContext. 2)))')"                               '"10"'
assert_eq 'mc_divide'     "$(sm '(str (.divide (bigdec "1") (bigdec "3") (java.math.MathContext. 5)))')"                      '"0.33333"'
assert_eq 'mc_div_mode'   "$(sm '(str (.divide (bigdec "10") (bigdec "3") (java.math.MathContext. 2 java.math.RoundingMode/FLOOR)))')" '"3.3"'
assert_eq 'mc_precision'  "$(sm '(.getPrecision (java.math.MathContext. 7))')"                                                '7'
assert_eq 'mc_mode'       "$(sm '(str (.getRoundingMode (java.math.MathContext. 7)))')"                                       '"HALF_UP"'
assert_eq 'mc_tostr'      "$(sm '(str (java.math.MathContext. 4))')"                                                          '"precision=4 roundingMode=HALF_UP"'
assert_eq 'mc_tostr_mode' "$(sm '(str (java.math.MathContext. 4 java.math.RoundingMode/FLOOR))')"                            '"precision=4 roundingMode=FLOOR"'
# DECIMAL32/64/128/UNLIMITED standard constants (D-511) — clj-grounded.
assert_eq 'mc_decimal64'  "$(sm '(str java.math.MathContext/DECIMAL64)')"                                                     '"precision=16 roundingMode=HALF_EVEN"'
assert_eq 'mc_decimal32'  "$(sm '(.getPrecision java.math.MathContext/DECIMAL32)')"                                           '7'
assert_eq 'mc_decimal128' "$(sm '(.getPrecision java.math.MathContext/DECIMAL128)')"                                          '34'
assert_eq 'mc_unlimited'  "$(sm '(str java.math.MathContext/UNLIMITED)')"                                                     '"precision=0 roundingMode=HALF_UP"'
# DECIMAL64 used in a real round (16 sig figs, HALF_EVEN)
assert_eq 'mc_dec_round'  "$(sm '(str (.divide (bigdec "1") (bigdec "3") java.math.MathContext/DECIMAL32))')"                 '"0.3333333"'

# BigDecimal string/int constructor (D-511) — JVM (BigDecimal. x). clj-grounded.
assert_eq 'ctor_str'  "$(sm '(str (java.math.BigDecimal. "1.5"))')"   '"1.5"'
assert_eq 'ctor_str2' "$(sm '(str (java.math.BigDecimal. "3.14159"))')" '"3.14159"'
assert_eq 'ctor_int'  "$(sm '(str (java.math.BigDecimal. 5))')"        '"5"'
# the ctor result is a real BigDecimal (scale-bearing, usable in .setScale)
assert_eq 'ctor_use'  "$(sm '(str (.setScale (java.math.BigDecimal. "2.5") 0 java.math.RoundingMode/HALF_UP))')" '"3"'

echo "OK — phase14_bigdecimal_setscale (91 cases) green"
