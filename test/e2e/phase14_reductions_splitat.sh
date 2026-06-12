#!/usr/bin/env bash
# test/e2e/phase14_reductions_splitat.sh — reductions 2-arg (multi-arity;
# the common `(reductions f coll)` form, previously a wrong-arity error) +
# split-at (D-134). reductions stays eager (vector); split-at's pair holds
# lazy seqs (tested via realized/destructured values, since the pair itself
# prints #<lazy_seq> per the tracked nested-lazy printer limit).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# reductions — 2-arg (was broken) + 3-arg (unchanged)
assert_eq 'red2_sum'  "$("$BIN" -e '(reductions + [1 2 3])')"    '(1 3 6)'
assert_eq 'red2_mul'  "$("$BIN" -e '(reductions * [1 2 3 4])')"  '(1 2 6 24)'
assert_eq 'red2_empt' "$("$BIN" -e '(reductions + [])')"        '(0)'
assert_eq 'red3_init' "$("$BIN" -e '(reductions + 10 [1 2 3])')" '(10 11 13 16)'
# split-at — values via realize/destructure
assert_eq 'sa_first'  "$("$BIN" -e '(first (split-at 2 [1 2 3 4]))')"  '(1 2)'
assert_eq 'sa_second' "$("$BIN" -e '(second (split-at 2 [1 2 3 4]))')" '(3 4)'
assert_eq 'sa_destr'  "$("$BIN" -e '(let [[a b] (split-at 2 [1 2 3 4])] [(vec a) (vec b)])')" '[[1 2] [3 4]]'
assert_eq 'sa_zero'   "$("$BIN" -e '(let [[a b] (split-at 0 [1 2])] [(vec a) (vec b)])')" '[[] [1 2]]'
assert_eq 'sa_over'   "$("$BIN" -e '(let [[a b] (split-at 9 [1 2])] [(vec a) (vec b)])')" '[[1 2] []]'
echo "OK — phase14_reductions_splitat smoke (9 cases) green"
