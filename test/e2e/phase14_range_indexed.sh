#!/usr/bin/env bash
# test/e2e/phase14_range_indexed.sh
#
# Phase 14 §9.16 row 14.13 — D-134 range + index fns:
# range (0/1/2/3-arg) / map-indexed / keep-indexed. 1/2-arg are eager
# vectors (DIVERGENCE: JVM returns lazy seqs); 0-arg infinite + 3-arg
# step are lazy seqs (lazy-seq Layer-2 landed via ADR-0054). 3-arg step
# is a lazy take-while over iterate, matching JVM step semantics incl.
# negative step + the step-0/start=end edge (not= continuation). Pattern
# A over a recursive helper / mapv / nth / count for the eager arities.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'range_n'      "$("$BIN" -e '(into [] (range 4))')"        '[0 1 2 3]'
assert_eq 'range_se'     "$("$BIN" -e '(into [] (range 2 5))')"      '[2 3 4]'
assert_eq 'range_zero'   "$("$BIN" -e '(into [] (range 0))')"        '[]'
# 3-arg step (lazy): positive step, negative step, non-divisor end,
# start=end empty, and the step-0 infinite edge (matches JVM not=).
assert_eq 'range_step_pos'  "$("$BIN" -e '(into [] (range 0 10 2))')"    '[0 2 4 6 8]'
assert_eq 'range_step_neg'  "$("$BIN" -e '(into [] (range 10 0 -2))')"   '[10 8 6 4 2]'
assert_eq 'range_step_ndiv' "$("$BIN" -e '(into [] (range 1 10 3))')"    '[1 4 7]'
assert_eq 'range_step_empty' "$("$BIN" -e '(into [] (range 5 5 2))')"    '[]'
assert_eq 'range_step_zero' "$("$BIN" -e '(into [] (take 3 (range 0 10 0)))')" '[0 0 0]'
assert_eq 'map_indexed'  "$("$BIN" -e '(into [] (map-indexed (fn* [i x] [i x]) [:a :b]))')" '[[0 :a] [1 :b]]'
assert_eq 'keep_indexed' "$("$BIN" -e '(into [] (keep-indexed (fn* [i x] (if (= 0 (rem i 2)) x nil)) [:a :b :c]))')" '[:a :c]'
# large range must not blow the stack (-range-acc uses loop/recur, not fn-deep
# recursion — (range 100000) segfaulted before)
assert_eq 'range_large'  "$("$BIN" -e '(count (range 100000))')"        '100000'
assert_eq 'range_large_sum' "$("$BIN" -e '(reduce + 0 (range 1000))')"  '499500'
assert_eq 'range_large_last' "$("$BIN" -e '(last (range 50000))')"      '49999'

echo "ALL phase14_range_indexed PASS"
