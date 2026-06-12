#!/usr/bin/env bash
# test/e2e/phase14_shuffle.sh — D-134 shuffle (Fisher-Yates random permutation
# -> vector). Non-deterministic, so assertions are permutation invariants.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# sort returns a SEQ (JVM parity), so the sorted permutation prints (..) not [..]
assert_eq 'sh_perm'    "$("$BIN" -e '(sort (shuffle [3 1 2 5 4]))')" '(1 2 3 4 5)'
assert_eq 'sh_set'     "$("$BIN" -e '(= (set (shuffle [:a :b :c])) #{:a :b :c})')" 'true'
assert_eq 'sh_count'   "$("$BIN" -e '(count (shuffle [1 2 3 4 5 6 7]))')" '7'
assert_eq 'sh_single'  "$("$BIN" -e '(shuffle [42])')" '[42]'
assert_eq 'sh_empty'   "$("$BIN" -e '(shuffle [])')"   '[]'
assert_eq 'sh_vector'  "$("$BIN" -e '(vector? (shuffle (list 1 2 3)))')" 'true'
echo "OK — phase14_shuffle smoke (6 cases) green"
