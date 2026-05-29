#!/usr/bin/env bash
# test/e2e/phase14_merge_partition_by.sh
#
# D-134 missing-core batch — merge-with + partition-by. Pattern A `.clj`.
# partition-by runs are realized via `mapv vec` for the assertion (the
# runs are take-while lazy_seqs; nested lazy-seqs print as #<lazy_seq>,
# ADR-0054). partition-by uses a lazy_seq run (NOT a raw cons-onto-lazy,
# which would mis-count — D-153).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# merge-with
assert_eq 'mw_overlap'   "$("$BIN" -e '(merge-with + {:a 1 :b 2} {:b 3 :c 4})')" '{:a 1, :b 5, :c 4}'
assert_eq 'mw_combine3'  "$("$BIN" -e '(merge-with + {:x 10} {:x 5} {:x 1})')"   '{:x 16}'
assert_eq 'mw_no_overlap' "$("$BIN" -e '(merge-with + {:a 1} {:b 2})')"          '{:a 1, :b 2}'
assert_eq 'mw_nil_skip'  "$("$BIN" -e '(merge-with + {:a 1} nil {:a 2})')"       '{:a 3}'
# partition-by
assert_eq 'pb_runs'      "$("$BIN" -e '(mapv vec (partition-by odd? [1 1 2 2 3 3]))')" '[[1 1] [2 2] [3 3]]'
assert_eq 'pb_single'    "$("$BIN" -e '(mapv vec (partition-by identity [1 1 1]))')"   '[[1 1 1]]'
assert_eq 'pb_alt'       "$("$BIN" -e '(mapv vec (partition-by (fn* [x] (> x 2)) [1 2 3 4 1]))')" '[[1 2] [3 4] [1]]'
assert_eq 'pb_count'     "$("$BIN" -e '(count (partition-by odd? [1 1 2 2 3 3]))')"     '3'

echo "OK — phase14_merge_partition_by smoke (8 cases) green"
