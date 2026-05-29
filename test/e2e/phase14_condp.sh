#!/usr/bin/env bash
# test/e2e/phase14_condp.sh
#
# D-134 missing-core batch — condp. (condp pred expr clause*) expands to
# (let* [gp pred ge expr] <emit>): for each clause (pred test-expr expr) is
# evaluated; a binary clause returns its result, a ternary `test :>> fn`
# clause calls (fn <pred-result>). A lone trailing form is the default; no
# match without one throws. Unlike case, test-exprs ARE evaluated.

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

# binary pred (=) + default
assert_eq 'eq_match'   "$("$BIN" -e '(condp = 2 1 :one 2 :two 3 :three :other)')" ':two'
assert_eq 'eq_default' "$("$BIN" -e '(condp = 5 1 :one 2 :two :default)')"        ':default'
# test-exprs are evaluated (vs case constants)
assert_eq 'eval_test'  "$("$BIN" -e '(condp = 2 (+ 1 1) :got :nope)')"            ':got'
# ordering pred (<): (pred test expr) = (< test 10)
assert_eq 'lt_first'   "$("$BIN" -e '(condp < 10 5 :gt5 100 :gt100 :small)')"     ':gt5'
assert_eq 'lt_default' "$("$BIN" -e '(condp < 10 100 :gt100 :small)')"            ':small'
# string test-exprs
assert_eq 'str_match'  "$("$BIN" -e '(condp = "b" "a" 1 "b" 2)')"                 '2'
# :>> result-fn applied to the predicate's truthy value
assert_eq 'arrow_hit'  "$("$BIN" -e '(condp (fn [t e] (when (> e t) (- e t))) 10 3 :>> (fn [d] (* d 2)) :none)')" '14'
assert_eq 'arrow_miss' "$("$BIN" -e '(condp (fn [t e] nil) 10 3 :>> (fn [d] d) :none)')" ':none'

# no-default + no-match → throws
out="$("$BIN" -e '(condp = 9 1 :one 2 :two)' 2>&1 || true)"
[[ "$out" == *"No matching clause"* ]] || fail "no_match_throw: got '$out'"
echo "PASS no_match_throw -> No matching clause"

echo "OK — phase14_condp smoke (9 cases) green"
