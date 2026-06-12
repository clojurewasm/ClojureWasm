#!/usr/bin/env bash
# test/e2e/phase14_bounded_count.sh — bounded-count: FULL count for a counted?
# coll (clj parity — a vector/range is O(1) counted, n is ignored); else walk at
# most n (terminates on infinite seqs). Pattern A .clj loop, AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# A counted? coll returns its FULL count, ignoring n (clj parity; vector is O(1)).
assert_eq 'bc_counted' "$("$BIN" -e '(bounded-count 3 [1 2 3 4 5])')" '5'
assert_eq 'bc_full'  "$("$BIN" -e '(bounded-count 10 [1 2 3])')"    '3'
assert_eq 'bc_zero_n' "$("$BIN" -e '(bounded-count 0 [1 2 3])')"     '3'
assert_eq 'bc_empty' "$("$BIN" -e '(bounded-count 5 [])')"         '0'
# An uncounted (lazy) seq is walked at most n; an infinite range (no args) is
# NOT counted, so it caps at n (no hang).
assert_eq 'bc_lazy'  "$("$BIN" -e '(bounded-count 3 (map inc (range 100)))')" '3'
assert_eq 'bc_inf'   "$("$BIN" -e '(bounded-count 4 (range))')"    '4'
echo "OK — phase14_bounded_count smoke (6 cases) green"
