#!/usr/bin/env bash
# test/e2e/phase14_case.sh
#
# D-134 missing-core batch — case. Expands to a (let* [g e] (if … (if … )))
# cascade with (= g (quote const)) tests (constants unevaluated/quoted) and
# (or …) groups for list clauses. An odd trailing form is the default;
# without one, a non-match throws (ex-info "No matching clause"). Divergence
# from JVM: linear = cascade, not a constant-time jump table.

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

# integer constants + default
assert_eq 'int_match'  "$("$BIN" -e '(case 2 1 :one 2 :two 3 :three :other)')" ':two'
assert_eq 'int_default' "$("$BIN" -e '(case 5 1 :one 2 :two :default)')"        ':default'
# keyword / string / symbol constants (unevaluated)
assert_eq 'kw_match'   "$("$BIN" -e '(case :b :a 1 :b 2 :c 3)')"                '2'
assert_eq 'str_match'  "$("$BIN" -e '(case "x" "x" :str-x "y" :str-y)')"        ':str-x'
assert_eq 'sym_match'  "$("$BIN" -e '(case (quote foo) foo :got bar :nope :none)')" ':got'
# list-group clauses (any element matches)
assert_eq 'group_hi'   "$("$BIN" -e '(case 7 (1 2 3) :low (7 8 9) :high :mid)')" ':high'
assert_eq 'group_low'  "$("$BIN" -e '(case 2 (1 2 3) :low :hi)')"               ':low'
# default-only
assert_eq 'default_only' "$("$BIN" -e '(case 5 :always)')"                      ':always'

# no-default + no-match → throws "No matching clause"
out="$("$BIN" -e '(case 99 1 :one 2 :two)' 2>&1 || true)"
[[ "$out" == *"No matching clause"* ]] || fail "no_match_throw: got '$out'"
echo "PASS no_match_throw -> No matching clause"

echo "OK — phase14_case smoke (10 cases) green"
