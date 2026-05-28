#!/usr/bin/env bash
# test/e2e/phase14_sort.sh
#
# Phase 14 §9.16 row 14.13 — D-134 sort cluster, unblocked by D-137
# (general compare). sort / sort-by via a STABLE merge sort in .clj
# (ADR-0053 D3 mandates stability — Clojure sort is stable). Uses the
# now-general `compare`, so strings/keywords sort too.
#
# Layer 2 (e2e CLI) per ADR-0021.

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

assert_eq 'sort_int'    "$("$BIN" -e '(into [] (sort [3 1 2]))')"                 '[1 2 3]'
assert_eq 'sort_str'    "$("$BIN" -e '(into [] (sort ["c" "a" "b"]))')"           '["a" "b" "c"]'
assert_eq 'sort_kw'     "$("$BIN" -e '(into [] (sort [:c :a :b]))')"              '[:a :b :c]'
assert_eq 'sort_empty'  "$("$BIN" -e '(into [] (sort []))')"                      '[]'
assert_eq 'sort_dup'    "$("$BIN" -e '(into [] (sort [2 1 2 1]))')"               '[1 1 2 2]'
assert_eq 'sort_by_len' "$("$BIN" -e '(into [] (sort-by count ["aa" "b" "ccc"]))')" '["b" "aa" "ccc"]'
# stability: a constant key must preserve original order
assert_eq 'sort_stable' "$("$BIN" -e '(into [] (sort-by (fn* [x] 0) [3 1 2]))')"  '[3 1 2]'

echo "ALL phase14_sort PASS"
