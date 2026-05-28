#!/usr/bin/env bash
# test/e2e/phase14_core_cluster.sh
#
# Phase 14 §9.16 row 14.13 — D-126 discharge. clojure.core daily-driver
# cluster that was missing from the bootstrap surface: get-in / assoc-in
# / update-in / concat / mapcat. Pattern A `.clj` defns over existing
# primitives (reduce / get / assoc / first / next / conj / into / apply).
#
# JVM Clojure: get-in/assoc-in/update-in walk a key path; concat/mapcat
# return lazy seqs. cw v1 ships eager concat/mapcat (DIVERGENCE: returns
# a vector, consistent with the file's eager map/filter surface — true
# lazy lands with the lazy-seq Layer-2 gap). Coverage tested via
# `(into [] ...)` so the assertion is order+content, not print-form.
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

# --- get-in ---
assert_eq 'get_in_nested'  "$("$BIN" -e '(get-in {:a {:b 1}} [:a :b])')"      '1'
assert_eq 'get_in_missing' "$("$BIN" -e '(get-in {:a 1} [:x :y])')"           'nil'
assert_eq 'get_in_single'  "$("$BIN" -e '(get-in {:a 7} [:a])')"              '7'

# --- assoc-in ---
assert_eq 'assoc_in_add'   "$("$BIN" -e '(get-in (assoc-in {:a {:b 1}} [:a :c] 2) [:a :c])')" '2'
assert_eq 'assoc_in_keep'  "$("$BIN" -e '(get-in (assoc-in {:a {:b 1}} [:a :c] 2) [:a :b])')" '1'

# --- update-in ---
assert_eq 'update_in_inc'  "$("$BIN" -e '(get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b])')" '2'
assert_eq 'update_in_args' "$("$BIN" -e '(get-in (update-in {:a {:b 1}} [:a :b] + 10) [:a :b])')" '11'

# --- concat (eager; tested as a realised vector) ---
assert_eq 'concat_two'   "$("$BIN" -e '(into [] (concat [1 2] [3 4]))')" '[1 2 3 4]'
assert_eq 'concat_three' "$("$BIN" -e '(into [] (concat [1] [2] [3]))')" '[1 2 3]'

# --- mapcat (eager single-coll) ---
assert_eq 'mapcat_pairs' "$("$BIN" -e '(into [] (mapcat (fn* [x] [x x]) [1 2 3]))')" '[1 1 2 2 3 3]'

echo "ALL phase14_core_cluster PASS"
