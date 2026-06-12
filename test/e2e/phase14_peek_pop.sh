#!/usr/bin/env bash
# test/e2e/phase14_peek_pop.sh — D-134 stack ops peek/pop (Pattern A .clj,
# polymorphic vector/list; peek empty = nil, pop empty throws). AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
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

# D-218: peek/pop are stack-only (nil/list/vector). nil → nil; a non-stack
# seqable (string, lazy seq, range) throws (clj ClassCastException) — NOT a
# silent first/rest fall-through.
assert_eq 'peek_nil'  "$("$BIN" -e '(peek nil)')" 'nil'
assert_eq 'pop_nil'   "$("$BIN" -e '(pop nil)')"  'nil'
for x in '(peek "abc")' '(peek (map inc [1 2]))' '(peek (range 3))' '(pop "abc")' '(pop (range 3))'; do
  "$BIN" -e "$x" >/dev/null 2>&1 && fail "nonstack: '$x' should throw" || true
done
echo 'PASS nonstack_peek_pop -> throws (string/lazy/range)'

echo "OK — phase14_peek_pop smoke (11 cases) green"
