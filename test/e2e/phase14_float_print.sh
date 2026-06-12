#!/usr/bin/env bash
# test/e2e/phase14_float_print.sh
#
# D-149 — whole-valued doubles print with a trailing `.0` (Clojure /
# JVM `Double.toString` shape) so they read back as a double, not a
# long.
#
# D-166 — JVM `Double.toString` switches to computerized scientific
# notation `<d>.<dd>E<exp>` outside the decimal window `1e-3 ≤ |x| < 1e7`
# (i.e. decimal exponent in `[-3, 6]`). The single shared formatter
# `runtime/print.zig::printFloat` (which `eval/form.zig` now delegates to,
# F-011 commonisation) renders Zig's shortest-scientific `render` output
# and re-lays it: the shortest DIGITS are already correct (Ryū == JVM for
# all but the smallest-subnormal tie, recorded as an acceptable
# divergence — `5e-324`/`Double/MIN_VALUE` print `5.0E-324` vs clj's
# `4.9E-324`, same double). All cases below are clj-grounded.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'whole_double'   "$("$BIN" -e '5.0')"            '5.0'
assert_eq 'frac_double'    "$("$BIN" -e '3.14')"           '3.14'
assert_eq 'pr_str_whole'   "$("$BIN" -e '(pr-str 100.0)')" '"100.0"'
assert_eq 'str_whole'      "$("$BIN" -e '(str 5.0)')"      '"5.0"'
assert_eq 'arith_whole'    "$("$BIN" -e '(* 2.0 3)')"      '6.0'
assert_eq 'div_frac'       "$("$BIN" -e '(/ 1.0 4)')"      '0.25'
assert_eq 'neg_zero'       "$("$BIN" -e '-0.0')"           '-0.0'
# Type fidelity: the printed value still reads back as a float.
assert_eq 'still_float'    "$("$BIN" -e '(float? (* 2.0 3))')" 'true'

# --- D-166: scientific-notation threshold (decimal window exp10 ∈ [-3, 6]) ---
# Decimal side (|x| in [1e-3, 1e7)) — unchanged, no exponent:
assert_eq 'dec_001'        "$("$BIN" -e '0.001')"        '0.001'
assert_eq 'dec_max_under'  "$("$BIN" -e '9999999.0')"    '9999999.0'
assert_eq 'dec_100k'       "$("$BIN" -e '100000.0')"     '100000.0'
assert_eq 'dec_frac'       "$("$BIN" -e '123456.789')"   '123456.789'
assert_eq 'dec_one_third'  "$("$BIN" -e '(/ 1.0 3.0)')"  '0.3333333333333333'
# Scientific side (|x| ≥ 1e7 or < 1e-3) — E-notation, mantissa always has `.`:
assert_eq 'sci_1e7'        "$("$BIN" -e '1e7')"          '1.0E7'
assert_eq 'sci_12345678'   "$("$BIN" -e '12345678.0')"   '1.2345678E7'
assert_eq 'sci_1e-4'       "$("$BIN" -e '0.0001')"       '1.0E-4'
assert_eq 'sci_avogadro'   "$("$BIN" -e '6.022e23')"     '6.022E23'
assert_eq 'sci_1e20'       "$("$BIN" -e '1e20')"         '1.0E20'
assert_eq 'sci_neg'        "$("$BIN" -e '-1.5e8')"       '-1.5E8'
assert_eq 'sci_small'      "$("$BIN" -e '1e-10')"        '1.0E-10'
# pr-str path (print.zig) and str path agree with the value-display path:
assert_eq 'sci_pr_str'     "$("$BIN" -e '(pr-str 1e7)')" '"1.0E7"'
assert_eq 'sci_str'        "$("$BIN" -e '(str 6.022e23)')" '"6.022E23"'
# RECORDED DIVERGENCE (acceptable): smallest subnormal — Ryū `5.0E-324` vs
# clj/JVM `4.9E-324`; same double, value-exact. Pinned to cljw's form.
assert_eq 'sci_min_subnormal' "$("$BIN" -e '5e-324')"    '5.0E-324'

echo "OK — phase14_float_print smoke (D-149 + D-166) green"
