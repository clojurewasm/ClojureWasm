#!/usr/bin/env bash
# test/e2e/phase14_not_eq_run.sh
#
# D-134 — not= / fnext / nnext / run! (Pattern A .clj, ride the AOT blob).
# run!'s side effect is observed via a def-accumulator (atoms are Phase-15).

set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'noteq_diff'  "$("$BIN" -e '(not= 1 2)')"     'true'
assert_eq 'noteq_same'  "$("$BIN" -e '(not= 1 1)')"     'false'
assert_eq 'noteq_3mix'  "$("$BIN" -e '(not= 1 1 2)')"   'true'
assert_eq 'noteq_3same' "$("$BIN" -e '(not= 1 1 1)')"   'false'
assert_eq 'fnext_mid'   "$("$BIN" -e '(fnext [1 2 3])')" '2'
assert_eq 'fnext_short' "$("$BIN" -e '(fnext [1])')"     'nil'
assert_eq 'nnext_rest'  "$("$BIN" -e '(nnext [1 2 3 4])')" '(3 4)'
assert_eq 'nnext_short' "$("$BIN" -e '(nnext [1 2])')"   'nil'
assert_eq 'run_effect'  "$("$BIN" -e '(do (def s 0) (run! (fn* [x] (def s (+ s x))) [1 2 3 4]) s)')" '10'
assert_eq 'run_nil'     "$("$BIN" -e '(run! identity [1 2 3])')" 'nil'

echo "OK — phase14_not_eq_run smoke (10 cases) green"
