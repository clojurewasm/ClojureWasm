#!/usr/bin/env bash
# test/e2e/phase14_memoize.sh — memoize (atom-backed cache keyed by
# (vec args); unblocked by D-092 vector-key value equality).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'basic'   "$("$BIN" -e '((memoize inc) 5)')"                       '6'
assert_eq 'multi'   "$("$BIN" -e '(let [f (memoize +)] [(f 1 2) (f 1 2)])')" '[3 3]'
# caches: same arg computes once
assert_eq 'cached'  "$("$BIN" -e '(let [n (atom 0) f (memoize (fn [x] (swap! n inc) (* x x)))] (f 3) (f 3) [(f 3) @n])')" '[9 1]'
# distinct args compute separately
assert_eq 'distinct' "$("$BIN" -e '(let [n (atom 0) f (memoize (fn [x] (swap! n inc) x))] (f 1) (f 2) (f 1) @n)')" '2'
# zero-arg memoized fn
assert_eq 'zeroarg' "$("$BIN" -e '(let [n (atom 0) f (memoize (fn [] (swap! n inc)))] (f) (f) @n)')" '1'
echo "OK — phase14_memoize smoke (5 cases) green"
