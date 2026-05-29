#!/usr/bin/env bash
# test/e2e/phase14_float_print.sh
#
# D-149 — whole-valued doubles print with a trailing `.0` (Clojure /
# JVM `Double.toString` shape) so they read back as a double, not a
# long. Zig's `{d}` drops the `.0` (`5.0` → "5"); printFloat
# (runtime/print.zig) + formatFloat (eval/form.zig) append it when the
# formatted text has no `.`/`e`/`E`. (Exact JVM E-notation thresholds
# are a cosmetic follow-up; this is the round-trip-fidelity fix.)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

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

echo "OK — phase14_float_print smoke (8 cases) green"
