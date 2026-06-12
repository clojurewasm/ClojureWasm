#!/usr/bin/env bash
# test/e2e/phase14_lazy_cat.sh — D-134 lazy-cat macro: (concat (lazy-seq c0)
# (lazy-seq c1) …) — lazily concatenates, deferring each coll until consumed.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'lc_two'   "$("$BIN" -e '(vec (lazy-cat [1 2] [3 4]))')"  '[1 2 3 4]'
assert_eq 'lc_three' "$("$BIN" -e '(vec (lazy-cat [1] [2] [3]))')"  '[1 2 3]'
assert_eq 'lc_empty' "$("$BIN" -e '(vec (lazy-cat))')"             '[]'
assert_eq 'lc_mixed' "$("$BIN" -e '(vec (lazy-cat [:a] (list :b :c)))')" '[:a :b :c]'
assert_eq 'lc_lazy'  "$("$BIN" -e '(vec (take 5 (lazy-cat [1 2] (range))))')" '[1 2 0 1 2]'
echo "OK — phase14_lazy_cat smoke (5 cases) green"
