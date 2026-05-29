#!/usr/bin/env bash
# test/e2e/phase14_when_if_not.sh
#
# D-134 trivial control macros — if-not / when-not / comment (Form
# transforms in macro_transforms.zig). if-not swaps the if branches;
# when-not is (if test nil (do body…)); comment reads its body (well-
# formed s-exprs) but discards it, so it may name undefined symbols.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# if-not (branches swapped vs if)
assert_eq 'ifnot_false'  "$("$BIN" -e '(if-not false :yes :no)')" ':yes'
assert_eq 'ifnot_true'   "$("$BIN" -e '(if-not true :yes :no)')"  ':no'
assert_eq 'ifnot_noelse' "$("$BIN" -e '(if-not true :yes)')"      'nil'
# when-not (body runs when test is falsey; last body wins)
assert_eq 'whennot_run'  "$("$BIN" -e '(when-not false :a :b)')"  ':b'
assert_eq 'whennot_skip' "$("$BIN" -e '(when-not true :a)')"      'nil'
assert_eq 'whennot_calc' "$("$BIN" -e '(when-not (= 1 2) (* 6 7))')" '42'
# comment → nil; body unevaluated (may name undefined symbols)
assert_eq 'comment_nil'  "$("$BIN" -e '(comment this is ignored)')" 'nil'
assert_eq 'comment_undef' "$("$BIN" -e '(comment (totally-undefined 99))')" 'nil'
assert_eq 'comment_indo' "$("$BIN" -e '(do (comment x) (+ 40 2))')" '42'

echo "OK — phase14_when_if_not smoke (9 cases) green"
