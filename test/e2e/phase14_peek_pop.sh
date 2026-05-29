#!/usr/bin/env bash
# test/e2e/phase14_peek_pop.sh — D-134 stack ops peek/pop (Pattern A .clj,
# polymorphic vector/list; peek empty = nil, pop empty throws). AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'peek_vec'   "$("$BIN" -e '(peek [1 2 3])')"      '3'
assert_eq 'peek_vempty' "$("$BIN" -e '(peek [])')"          'nil'
assert_eq 'peek_list'  "$("$BIN" -e '(peek (list 1 2 3))')" '1'
assert_eq 'peek_lempty' "$("$BIN" -e '(peek (list))')"      'nil'
assert_eq 'pop_vec'    "$("$BIN" -e '(pop [1 2 3])')"       '[1 2]'
assert_eq 'pop_vone'   "$("$BIN" -e '(pop [9])')"           '[]'
assert_eq 'pop_list'   "$("$BIN" -e '(pop (list 1 2 3))')"  '(2 3)'
out="$("$BIN" -e '(pop [])' 2>&1 || true)"
[[ "$out" == *"Can't pop empty"* ]] || fail "pop_empty: got '$out'"
echo "PASS pop_empty -> throws"

echo "OK — phase14_peek_pop smoke (8 cases) green"
