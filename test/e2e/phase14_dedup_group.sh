#!/usr/bin/env bash
# test/e2e/phase14_dedup_group.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 3 (unblocked by D-136 universal
# `=`). dedupe / distinct / frequencies / group-by. Pattern A over reduce
# / conj / assoc / get(3-arg) / some / =. distinct uses `=` linear scan
# (structural, so strings dedupe); frequencies/group-by key via map
# assoc/get (bit-pattern keyEq → number/keyword keys; structural keys
# await D-092).
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

assert_eq 'dedupe_runs'    "$("$BIN" -e '(into [] (dedupe [1 1 2 2 3 1]))')"            '[1 2 3 1]'
assert_eq 'distinct_int'   "$("$BIN" -e '(into [] (distinct [1 2 1 3 2]))')"            '[1 2 3]'
# dedupe/distinct coll arities are O(n) (delegate to the transducer) — the
# old (last acc) / linear-some scans were O(n²) and timed out at ~5000
assert_eq 'dedupe_large'   "$("$BIN" -e '(count (dedupe (range 5000)))')"               '5000'
assert_eq 'distinct_large' "$("$BIN" -e '(count (distinct (concat (range 2000) (range 2000))))')" '2000'
assert_eq 'distinct_str'   "$("$BIN" -e '(into [] (distinct ["a" "b" "a"]))')"          '["a" "b"]'
assert_eq 'frequencies_int' "$("$BIN" -e '(get (frequencies [1 1 2]) 1)')"             '2'
assert_eq 'frequencies_kw'  "$("$BIN" -e '(get (frequencies [:a :a :b]) :a)')"         '2'
assert_eq 'group_by_even'   "$("$BIN" -e '(into [] (get (group-by (fn* [x] (rem x 2)) [1 2 3 4]) 0))')" '[2 4]'
# dedupe / distinct return a SEQ, not a vector (JVM parity, clj-verified)
assert_eq 'dedupe_seq'   "$("$BIN" -e '(dedupe [1 1 2 2 1])')"     '(1 2 1)'
assert_eq 'distinct_seq' "$("$BIN" -e '(distinct [1 1 2 3 3])')"   '(1 2 3)'
assert_eq 'distinct_isseq' "$("$BIN" -e '(seq? (distinct [1 2]))')" 'true'

echo "ALL phase14_dedup_group PASS"
