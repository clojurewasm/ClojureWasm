#!/usr/bin/env bash
# test/e2e/phase14_partition_all.sh
#
# D-134 — partition-all (lazy, keeps the final short partition; unlike
# partition which drops it) + splitv-at (vector split-at). Pattern A
# .clj over take/drop/lazy-seq (ride the AOT blob). Runs are realized
# via mapv vec (nested lazy-seqs print as #<lazy_seq>, ADR-0054).

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

assert_eq 'pa_partial' "$("$BIN" -e '(mapv vec (partition-all 2 [1 2 3 4 5]))')"   '[[1 2] [3 4] [5]]'
assert_eq 'pa_even'    "$("$BIN" -e '(mapv vec (partition-all 3 [1 2 3 4 5 6]))')" '[[1 2 3] [4 5 6]]'
assert_eq 'pa_count'   "$("$BIN" -e '(count (partition-all 2 [1 2 3 4 5]))')"      '3'
assert_eq 'pa_step'    "$("$BIN" -e '(mapv vec (partition-all 2 4 [1 2 3 4 5 6 7]))')" '[[1 2] [5 6]]'
assert_eq 'pa_empty'   "$("$BIN" -e '(count (partition-all 2 []))')"               '0'
assert_eq 'sv_at'      "$("$BIN" -e '(splitv-at 2 [1 2 3 4 5])')"                  '[[1 2] [3 4 5]]'
assert_eq 'sv_zero'    "$("$BIN" -e '(splitv-at 0 [1 2 3])')"                      '[[] [1 2 3]]'
assert_eq 'sv_over'    "$("$BIN" -e '(splitv-at 9 [1 2])')"                        '[[1 2] []]'

echo "OK — phase14_partition_all smoke (8 cases) green"
