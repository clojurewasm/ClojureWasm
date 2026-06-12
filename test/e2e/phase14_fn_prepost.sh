#!/usr/bin/env bash
# test/e2e/phase14_fn_prepost.sh — defn/fn :pre/:post condition maps.
# A leading map literal in a fn body (when MORE body follows) is a condition
# map: :pre vector asserts before the body, :post vector asserts after with `%`
# bound to the return value. A LONE map body is a return value, not conditions
# (clj parity). Applies to fn/defn uniformly (lowered at the fn arity level).
# Found driving clojure.core.cache (cache.clj:602 `:post [(== … (count … %))]`).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
last() { printf '%s' "$1" | tail -1; }
# :pre passes / fails
assert_eq  'pre_ok'   "$(last "$("$BIN" -e '(defn f [x] {:pre [(pos? x)]} (* x 2)) (f 3)' 2>&1)")" '6'
assert_has 'pre_fail' "$("$BIN" -e '(defn f [x] {:pre [(pos? x)]} (* x 2)) (f -1)' 2>&1)" 'ssert'
# :post with % (return-value binding) passes / fails
assert_eq  'post_ok'   "$(last "$("$BIN" -e '(defn g [x] {:post [(pos? %)]} x) (g 5)' 2>&1)")" '5'
assert_has 'post_fail' "$("$BIN" -e '(defn g [x] {:post [(pos? %)]} x) (g -3)' 2>&1)" 'ssert'
# multiple conditions in one vector
assert_eq  'pre_multi' "$(last "$("$BIN" -e '(defn h [x] {:pre [(number? x) (pos? x)]} x) (h 4)' 2>&1)")" '4'
# combined :pre + :post
assert_eq  'both'      "$(last "$("$BIN" -e '(defn k [x] {:pre [(pos? x)] :post [(> % 0)]} (inc x)) (k 1)' 2>&1)")" '2'
# LONE map body is a RETURN value, NOT a condition map (clj parity)
assert_eq  'lone_map'  "$(last "$("$BIN" -e '(defn m [] {:pre [false]}) (m)' 2>&1)")" '{:pre [false]}'
# anonymous fn carries conditions too (lowered at the arity level, not defn-only)
assert_eq  'fn_pre'    "$(last "$("$BIN" -e '((fn [x] {:pre [(pos? x)]} x) 7)' 2>&1)")" '7'
# multi-arity: each arity has its own conditions
assert_eq  'multi'     "$(last "$("$BIN" -e '(defn p ([x] {:pre [(pos? x)]} x) ([x y] {:pre [(pos? y)]} (+ x y))) (p 2 3)' 2>&1)")" '5'
echo "OK — phase14_fn_prepost (9 cases) green"
