#!/usr/bin/env bash
# test/e2e/phase14_range_indexed.sh
#
# Phase 14 §9.16 row 14.13 — D-134 range + index fns:
# range (0/1/2/3-arg) / map-indexed / keep-indexed. ALL finite arities
# are lazy seqs (D-168): the 1/2-arg arms delegate to the 3-arg lazy-seq
# form, so `(seq? (range n))` is true and `(take 5 (range 1e9))` returns
# without realizing the whole range. 3-arg step matches JVM step
# semantics incl. negative step + the step-0/start=end edge (not=
# continuation). The F-004 chunked LongRange is the eventual finished
# form; this lazy-seq unification is the interim shared shape (F-011).
#
# conj on any ISeq prepends (D-168 prerequisite): `(conj (range 3) 99)`
# → `(99 0 1 2)`, same for `(conj (map …) x)` / `(conj (filter …) x)`.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'range_n'      "$("$BIN" -e '(into [] (range 4))')"        '[0 1 2 3]'
assert_eq 'range_se'     "$("$BIN" -e '(into [] (range 2 5))')"      '[2 3 4]'
assert_eq 'range_zero'   "$("$BIN" -e '(into [] (range 0))')"        '[]'
# D-168: finite-arity range is a lazy SEQ (was an eager vector). seq?
# true, prints as a list, and conj prepends (vs the old vector append).
assert_eq 'range_n_is_seq'  "$("$BIN" -e '(seq? (range 3))')"        'true'
assert_eq 'range_se_is_seq' "$("$BIN" -e '(seq? (range 2 5))')"      'true'
assert_eq 'range_n_render'  "$("$BIN" -e '(range 3)')"               '(0 1 2)'
assert_eq 'range_n_conj'    "$("$BIN" -e '(conj (range 3) 99)')"     '(99 0 1 2)'
# Laziness is observable: take over a huge range must NOT realize it all.
assert_eq 'range_lazy_take' "$("$BIN" -e '(into [] (take 5 (range 1000000000)))')" '[0 1 2 3 4]'
# conj on any ISeq prepends (the D-168 prerequisite fix, commonised via
# the cons primitive). Covers lazy_seq producers: range / map / filter.
assert_eq 'conj_range_step' "$("$BIN" -e '(conj (range 0 6 2) 99)')" '(99 0 2 4)'
assert_eq 'conj_lazy_map'   "$("$BIN" -e '(conj (map inc [1 2 3]) 0)')"     '(0 2 3 4)'
assert_eq 'conj_lazy_filter' "$("$BIN" -e '(conj (filter odd? [1 2 3]) 0)')" '(0 1 3)'
# nth walks a lazy seq (range became lazy under D-168 — `(rand-nth (range n))`
# / `(nth (range n) i)` previously threw "no -nth on lazy_seq").
assert_eq 'nth_range'      "$("$BIN" -e '(nth (range 50) 3)')"               '3'
assert_eq 'nth_lazy_map'   "$("$BIN" -e '(nth (map inc [10 20 30]) 1)')"     '21'
assert_eq 'nth_range_dflt' "$("$BIN" -e '(nth (range 5) 10 :none)')"         ':none'
# ADR-0063 / O-001: finite integer range is a compact `.range` value. It is
# `=` to the list / vector of the same elements, and count / nth are O(1)
# (a million-element count / nth returns instantly, no per-element walk).
assert_eq 'range_eq_list'   "$("$BIN" -e "(= (range 5) '(0 1 2 3 4))")"       'true'
assert_eq 'range_eq_vec'    "$("$BIN" -e '(= (range 5) [0 1 2 3 4])')"        'true'
assert_eq 'range_count_1m'  "$("$BIN" -e '(count (range 1000000))')"          '1000000'
assert_eq 'range_nth_1m'    "$("$BIN" -e '(nth (range 1000000) 999999)')"     '999999'
assert_eq 'range_reduce'    "$("$BIN" -e '(reduce + (range 101))')"           '5050'
assert_eq 'range_neg_step'  "$("$BIN" -e '(range 10 0 -2)')"                   '(10 8 6 4 2)'
assert_eq 'range_step0_inf' "$("$BIN" -e '(into [] (take 3 (range 0 10 0)))')" '[0 0 0]'
# 3-arg step (lazy): positive step, negative step, non-divisor end,
# start=end empty, and the step-0 infinite edge (matches JVM not=).
assert_eq 'range_step_pos'  "$("$BIN" -e '(into [] (range 0 10 2))')"    '[0 2 4 6 8]'
assert_eq 'range_step_neg'  "$("$BIN" -e '(into [] (range 10 0 -2))')"   '[10 8 6 4 2]'
assert_eq 'range_step_ndiv' "$("$BIN" -e '(into [] (range 1 10 3))')"    '[1 4 7]'
assert_eq 'range_step_empty' "$("$BIN" -e '(into [] (range 5 5 2))')"    '[]'
assert_eq 'range_step_zero' "$("$BIN" -e '(into [] (take 3 (range 0 10 0)))')" '[0 0 0]'
assert_eq 'map_indexed'  "$("$BIN" -e '(into [] (map-indexed (fn* [i x] [i x]) [:a :b]))')" '[[0 :a] [1 :b]]'
assert_eq 'keep_indexed' "$("$BIN" -e '(into [] (keep-indexed (fn* [i x] (if (= 0 (rem i 2)) x nil)) [:a :b :c]))')" '[:a :c]'
# large range must realize without blowing the stack: the lazy-seq body
# is walked iteratively by count/reduce/last (one thunk per step, not
# fn-deep recursion).
assert_eq 'range_large'  "$("$BIN" -e '(count (range 100000))')"        '100000'
assert_eq 'range_large_sum' "$("$BIN" -e '(reduce + 0 (range 1000))')"  '499500'
assert_eq 'range_large_last' "$("$BIN" -e '(last (range 50000))')"      '49999'

echo "ALL phase14_range_indexed PASS"
