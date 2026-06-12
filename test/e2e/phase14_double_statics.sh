#!/usr/bin/env bash
# test/e2e/phase14_double_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Double static methods. Surface runtime/java/lang/Double.zig,
# delegating parsing to the shared runtime/numeric/parse.zig leaf
# (parseFloat: rejects `_`, trims surrounding whitespace like Java
# Double.parseDouble). isNaN / isInfinite wrap std.math.
#
# Bonus regression: routing clojure.core/parse-double through the same
# leaf fixes a divergence where cljw did not trim — `(parse-double
# " 3.14 ")` is 3.14 in real clj but was nil in cljw.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- parseDouble (trims whitespace; accepts Infinity/NaN spelling) ---
check '(Double/parseDouble "3.14")'      '3.14'    double_parseDouble_basic
check '(Double/parseDouble " 3.14 ")'    '3.14'    double_parseDouble_trim
check '(Double/parseDouble "Infinity")'  '##Inf'   double_parseDouble_inf
check '(Double/parseDouble "-Infinity")' '##-Inf'  double_parseDouble_neg_inf
check '(Double/parseDouble "NaN")'       '##NaN'   double_parseDouble_nan

# --- isNaN / isInfinite ---
check '(Double/isNaN (/ 0.0 0.0))'       'true'    double_isNaN_true
check '(Double/isNaN 1.0)'               'false'   double_isNaN_false
check '(Double/isInfinite (/ 1.0 0.0))'  'true'    double_isInfinite_true
check '(Double/isInfinite 1.0)'          'false'   double_isInfinite_false

# --- NumberFormatException via ADR-0060 bridge ---
check '(try (Double/parseDouble "x") (catch NumberFormatException e :caught))'    ':caught' double_parseDouble_nfe
check '(try (Double/parseDouble "1_0.5") (catch NumberFormatException e :caught))' ':caught' double_parseDouble_underscore_nfe

# --- F-011 commonisation regression: parse-double now trims (clj parity) ---
check '(parse-double " 3.14 ")'          '3.14'    parse_double_trim_fixed
check '(parse-double "3.14")'            '3.14'    parse_double_no_regression
check '(parse-double "x")'               'nil'     parse_double_invalid_nil

echo "ALL PASS phase14_double_statics"
