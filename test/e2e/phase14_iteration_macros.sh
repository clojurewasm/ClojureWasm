#!/usr/bin/env bash
# test/e2e/phase14_iteration_macros.sh
#
# D-134 missing-core batch — iteration/binding family: dotimes / while /
# when-first. dotimes + while expand to loop/recur (eval to nil); their
# iteration is observed via a `def`-mutated accumulator (atoms are Phase-15,
# println stdout is D-096 — a re-def'd global var is the available
# cross-iteration side effect). when-first re-emits when-let + (first g).

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

# dotimes — count evaluated once, i runs 0..n-1, evaluates to nil
assert_eq 'dotimes_sum'   "$("$BIN" -e '(do (def s 0) (dotimes [i 4] (def s (+ s i))) s)')" '6'
assert_eq 'dotimes_lasti' "$("$BIN" -e '(do (def k -1) (dotimes [i 3] (def k i)) k)')"      '2'
assert_eq 'dotimes_zero'  "$("$BIN" -e '(do (def c 0) (dotimes [i 0] (def c 99)) c)')"      '0'
assert_eq 'dotimes_nil'   "$("$BIN" -e '(dotimes [i 3])')"                                  'nil'
# while — loops until test false, evaluates to nil
assert_eq 'while_count'   "$("$BIN" -e '(do (def w 0) (while (< w 3) (def w (inc w))) w)')" '3'
assert_eq 'while_false'   "$("$BIN" -e '(do (def z 5) (while (< z 0) (def z (inc z))) z)')" '5'
assert_eq 'while_nil'     "$("$BIN" -e '(do (def q 0) (while (< q 1) (def q 1)))')"         'nil'
# when-first
assert_eq 'wf_first'  "$("$BIN" -e '(when-first [x [10 20 30]] (* x 2))')" '20'
assert_eq 'wf_empty'  "$("$BIN" -e '(when-first [x []] :got)')"           'nil'
assert_eq 'wf_nil'    "$("$BIN" -e '(when-first [x nil] :got)')"          'nil'
assert_eq 'wf_multi'  "$("$BIN" -e '(when-first [x [7]] (inc x) (* x x))')" '49'

echo "OK — phase14_iteration_macros smoke (11 cases) green"
