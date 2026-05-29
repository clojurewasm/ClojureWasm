#!/usr/bin/env bash
# test/e2e/phase14_some_doto.sh
#
# D-134 missing-core batch — conditional family: if-some / when-some / doto.
# if-some/when-some are the nil-checking siblings of if-let/when-let (a
# FALSE binding takes the then/body branch — the key distinction). doto
# threads the first form-position with the value, evaluates to that value.
# Side-effect observation is value-based only (println stdout is D-096;
# atoms are Phase-15) — doto correctness is checked via return-value + that
# threading evaluates without error (structurally identical to ->).

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

# if-some
assert_eq 'ifsome_then'  "$("$BIN" -e '(if-some [x 5] (* x 2) :none)')"          '10'
assert_eq 'ifsome_nil'   "$("$BIN" -e '(if-some [x nil] (* x 2) :none)')"        ':none'
assert_eq 'ifsome_false' "$("$BIN" -e '(if-some [x false] :got-false :none)')"   ':got-false'
assert_eq 'ifsome_miss'  "$("$BIN" -e '(if-some [x (get {:a 1} :b)] x :missing)')" ':missing'
assert_eq 'ifsome_noelse' "$("$BIN" -e '(if-some [x nil] x)')"                   'nil'
# Distinction from if-let: a FALSE binding diverges (if-let=falsey→else; if-some=some→then)
assert_eq 'iflet_false'  "$("$BIN" -e '(if-let [x false] :t :e)')"               ':e'
assert_eq 'ifsome_false2' "$("$BIN" -e '(if-some [x false] :t :e)')"             ':t'
# when-some
assert_eq 'whensome_body'  "$("$BIN" -e '(when-some [x 5] (+ x 1))')"            '6'
assert_eq 'whensome_nil'   "$("$BIN" -e '(when-some [x nil] (+ x 1))')"          'nil'
assert_eq 'whensome_multi' "$("$BIN" -e '(when-some [x 3] (inc x) (* x x))')"    '9'
assert_eq 'whensome_false' "$("$BIN" -e '(when-some [x false] :got)')"           ':got'
# doto (return-value = the threaded subject)
assert_eq 'doto_num'  "$("$BIN" -e '(doto 5 (+ 1) (* 2))')"                      '5'
assert_eq 'doto_map'  "$("$BIN" -e '(doto {:a 1} (assoc :b 2) (assoc :c 3))')"   '{:a 1}'
assert_eq 'doto_noforms' "$("$BIN" -e '(doto 7)')"                               '7'

echo "OK — phase14_some_doto smoke (14 cases) green"
