#!/usr/bin/env bash
# test/e2e/phase14_coll_helpers.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 1. High-frequency clojure.core
# collection helpers that a 2026-05-29 probe found missing: update / vec /
# mapv / filterv / reverse / last. Pure Pattern A eager defns over
# reduce / conj / assoc / get / into / apply (no lazy-seq dependency).
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

assert_eq 'vec_coerce'    "$("$BIN" -e '(vec (keys {:a 1}))')"                          '[:a]'
assert_eq 'mapv_inc'      "$("$BIN" -e '(mapv inc [1 2 3])')"                           '[2 3 4]'
assert_eq 'mapv_2coll'    "$("$BIN" -e '(mapv + [1 2 3] [10 20 30])')"                  '[11 22 33]'
assert_eq 'mapv_3coll'    "$("$BIN" -e '(mapv vector [1 2] [:a :b] [true false])')"     '[[1 :a true] [2 :b false]]'
assert_eq 'filterv_even'  "$("$BIN" -e '(filterv (fn* [x] (= 0 (rem x 2))) [1 2 3 4])')" '[2 4]'
assert_eq 'update_inc'    "$("$BIN" -e '(get (update {:a 1} :a inc) :a)')"              '2'
assert_eq 'update_args'   "$("$BIN" -e '(get (update {:a 1} :a + 10) :a)')"             '11'
assert_eq 'reverse_vec'   "$("$BIN" -e '(into [] (reverse [1 2 3]))')"                  '[3 2 1]'
assert_eq 'last_vec'      "$("$BIN" -e '(last [1 2 3])')"                               '3'
assert_eq 'last_empty'    "$("$BIN" -e '(last [])')"                                    'nil'

echo "ALL phase14_coll_helpers PASS"
