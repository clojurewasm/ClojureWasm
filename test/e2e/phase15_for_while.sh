#!/usr/bin/env bash
# test/e2e/phase15_for_while.sh — `for` with `:while` in every modifier
# position (D-234 letfn+lazy-seq rewrite). The old mapcat lowering only
# handled `:while` immediately after a binding; the rewrite mirrors
# clojure.core/for's emit-bind, so `:while` after `:when`/`:let` works and is
# evaluated post-`:when` per element (clj-exact). All values clj-grounded.
# Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# :while right after binding (regression — must still work)
assert_eq 'while-bind'  "$("$BIN" -e '(for [x (range 10) :while (< x 5)] x)' 2>&1 | tail -1)" '(0 1 2 3 4)'
# :while AFTER :when — evaluated only on :when-passing elements (clj-exact)
assert_eq 'when-while'  "$("$BIN" -e '(for [a (range 5) :when (> a 0) :while (odd? a)] a)' 2>&1 | tail -1)" '(1)'
assert_eq 'when-while2' "$("$BIN" -e '(for [a (range 5) :when (odd? a) :while (< a 4)] a)' 2>&1 | tail -1)" '(1 3)'
# :while reading a same-group :let binding
assert_eq 'let-while'   "$("$BIN" -e '(for [x (range 5) :let [a (* x 2)] :while (< a 4)] [x a])' 2>&1 | tail -1)" '([0 0] [1 2])'
# nested binding with inner :while + outer :when
assert_eq 'nested'      "$("$BIN" -e '(for [x (range 4) :when (odd? x) y (range 2) :while (odd? (+ x y))] [x y])' 2>&1 | tail -1)" '([1 0] [3 0])'
# basic nested product (regression)
assert_eq 'product'     "$("$BIN" -e '(for [x (range 3) y (range 2)] [x y])' 2>&1 | tail -1)" '([0 0] [0 1] [1 0] [1 1] [2 0] [2 1])'
# lazy + infinite (regression)
assert_eq 'lazy-inf'    "$("$BIN" -e '(take 4 (for [x (range) :when (even? x)] x))' 2>&1 | tail -1)" '(0 2 4 6)'

echo "OK — phase15_for_while (7 cases) green"
