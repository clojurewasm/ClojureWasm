#!/usr/bin/env bash
# test/e2e/phase14_subvec.sh — D-134 subvec (vector slice [start,end); end
# defaults to count). cw builds a fresh vector (O(n)) via take/drop. AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'sv_mid'   "$("$BIN" -e '(subvec [1 2 3 4 5] 1 3)')" '[2 3]'
assert_eq 'sv_tail'  "$("$BIN" -e '(subvec [1 2 3 4 5] 2)')"   '[3 4 5]'
assert_eq 'sv_full'  "$("$BIN" -e '(subvec [1 2 3] 0 3)')"     '[1 2 3]'
assert_eq 'sv_empty' "$("$BIN" -e '(subvec [1 2 3] 3)')"       '[]'
assert_eq 'sv_count' "$("$BIN" -e '(count (subvec [10 20 30 40] 1))')" '3'
# clj bounds-checks (does NOT clamp like take/drop): start/end past count, end <
# start, or negative all throw IndexOutOfBounds.
"$BIN" -e '(subvec [1 2 3] 1 10)' >/dev/null 2>&1 && fail 'sv_end_oob: expected error' || true
echo 'PASS sv_end_oob -> errors'
"$BIN" -e '(subvec [1 2 3] 5)' >/dev/null 2>&1 && fail 'sv_start_oob: expected error' || true
echo 'PASS sv_start_oob -> errors'
"$BIN" -e '(subvec [1 2 3] 2 1)' >/dev/null 2>&1 && fail 'sv_end_lt_start: expected error' || true
echo 'PASS sv_end_lt_start -> errors'
"$BIN" -e '(subvec [1 2 3] -1)' >/dev/null 2>&1 && fail 'sv_neg: expected error' || true
echo 'PASS sv_neg -> errors'
echo "OK — phase14_subvec smoke (9 cases) green"
