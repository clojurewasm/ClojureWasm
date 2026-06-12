#!/usr/bin/env bash
# test/e2e/phase14_comparator.sh — comparator (3-way compare fn from a
# 2-arg boolean pred). Corpus gap sweep P0. core.clj defn.
# NOTE: `(sort comparator-fn coll)` is a separate gap (cljw sort's 2-arg
# form treats the fn as a 1-arg key-fn, not a 2-arg comparator) — D-159.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'cmp_lt'  "$("$BIN" -e '((comparator <) 1 2)')"  '-1'
assert_eq 'cmp_gt'  "$("$BIN" -e '((comparator <) 2 1)')"  '1'
assert_eq 'cmp_eq'  "$("$BIN" -e '((comparator <) 1 1)')"  '0'
assert_eq 'cmp_str' "$("$BIN" -e '((comparator (fn [a b] (< (count a) (count b)))) "aa" "b")')" '1'
echo "OK — phase14_comparator smoke (4 cases) green"
