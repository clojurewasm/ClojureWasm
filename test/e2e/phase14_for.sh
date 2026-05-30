#!/usr/bin/env bash
# test/e2e/phase14_for.sh — for (D-134 / phaseA26). Lazy list comprehension
# via nested mapcat-of-singletons; :let / :when + multi-binding. Lazy
# (infinite-safe). :while raises (not yet supported). fn carries destructure.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
assert_eq 'sq'      "$("$BIN" -e '(for [x [1 2 3]] (* x x))')"                  '(1 4 9)'
assert_eq 'when'    "$("$BIN" -e '(for [x [1 2 3 4] :when (odd? x)] x)')"       '(1 3)'
assert_eq 'let'     "$("$BIN" -e '(for [x [1 2 3] :let [y (* x 10)]] y)')"      '(10 20 30)'
assert_eq 'let_whn' "$("$BIN" -e '(for [x [1 2 3] :let [y (* x 10)] :when (> y 15)] y)')" '(20 30)'
assert_eq 'multi'   "$("$BIN" -e '(for [x [1 2] y [:a :b]] [x y])')"            '([1 :a] [1 :b] [2 :a] [2 :b])'
assert_eq 'combo'   "$("$BIN" -e '(for [x [1 2 3] :when (odd? x) y [0 1]] (+ x y))')" '(1 2 3 4)'
assert_eq 'destr'   "$("$BIN" -e '(for [[a b] [[1 2] [3 4]]] (+ a b))')"        '(3 7)'
assert_eq 'lazy'    "$("$BIN" -e '(take 4 (for [x (range)] (* x x)))')"         '(0 1 4 9)'
assert_eq 'range'   "$("$BIN" -e '(vec (for [x (range 5) :when (even? x)] x))')" '[0 2 4]'
assert_eq 'empty'   "$("$BIN" -e '(for [x []] x)')"                             'nil'
# :while after a binding → take-while on the coll
assert_eq 'while'   "$("$BIN" -e '(for [x [1 2 3 4 5] :while (< x 3)] x)')"     '(1 2)'
assert_eq 'while_lz' "$("$BIN" -e '(take 4 (for [x (range) :while (< x 100)] (* x x)))')" '(0 1 4 9)'
assert_eq 'while_wn' "$("$BIN" -e '(for [x (range 10) :while (< x 4) :when (odd? x)] x)')" '(1 3)'
# :while after a :let in the same group is the deferred edge → raises
assert_has 'while_let' "$("$BIN" -e '(for [x [1 2] :let [y x] :while (< y 2)] y)' 2>&1)" ':while is not yet supported'
echo "OK — phase14_for smoke (14 cases) green"
