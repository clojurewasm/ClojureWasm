#!/usr/bin/env bash
# test/e2e/phase14_core_cluster.sh
#
# Phase 14 §9.16 row 14.13 — D-126 discharge. clojure.core daily-driver
# cluster that was missing from the bootstrap surface: get-in / assoc-in
# / update-in / concat / mapcat. Pattern A `.clj` defns over existing
# primitives (reduce / get / assoc / first / next / conj / into / apply).
#
# JVM Clojure: get-in/assoc-in/update-in walk a key path; concat/mapcat
# return lazy seqs — cw v1 now matches (concat/mapcat are lazy via
# `-concat2`/`-concat-seqs`; mapcat is variadic over N colls, JVM shape).
# Coverage tested via `(into [] ...)` so the assertion is order+content,
# not print-form.
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

# --- get-in ---
assert_eq 'get_in_nested'  "$("$BIN" -e '(get-in {:a {:b 1}} [:a :b])')"      '1'
assert_eq 'get_in_missing' "$("$BIN" -e '(get-in {:a 1} [:x :y])')"           'nil'
assert_eq 'get_in_single'  "$("$BIN" -e '(get-in {:a 7} [:a])')"              '7'
# 3-arity not-found — sentinel distinguishes absent from a present nil (§A26).
assert_eq 'get_in_nf'      "$("$BIN" -e '(get-in {:a 1} [:x] :none)')"        ':none'
assert_eq 'get_in_nf_pnil' "$("$BIN" -e '(get-in {:a nil} [:a] :none)')"      'nil'

# --- assoc-in ---
assert_eq 'assoc_in_add'   "$("$BIN" -e '(get-in (assoc-in {:a {:b 1}} [:a :c] 2) [:a :c])')" '2'
assert_eq 'assoc_in_keep'  "$("$BIN" -e '(get-in (assoc-in {:a {:b 1}} [:a :c] 2) [:a :b])')" '1'

# --- update-in ---
assert_eq 'update_in_inc'  "$("$BIN" -e '(get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b])')" '2'
assert_eq 'update_in_args' "$("$BIN" -e '(get-in (update-in {:a {:b 1}} [:a :b] + 10) [:a :b])')" '11'

# --- concat (eager; tested as a realised vector) ---
assert_eq 'concat_two'   "$("$BIN" -e '(into [] (concat [1 2] [3 4]))')" '[1 2 3 4]'
assert_eq 'concat_three' "$("$BIN" -e '(into [] (concat [1] [2] [3]))')" '[1 2 3]'

# --- mapcat: single-coll + variadic over N colls (JVM shape, lazy) ---
assert_eq 'mapcat_pairs'  "$("$BIN" -e '(into [] (mapcat (fn* [x] [x x]) [1 2 3]))')" '[1 1 2 2 3 3]'
assert_eq 'mapcat_2coll'  "$("$BIN" -e '(into [] (mapcat list [1 2] [3 4]))')"          '[1 3 2 4]'
assert_eq 'mapcat_3coll'  "$("$BIN" -e '(into [] (mapcat vector [1 2] [3 4] [5 6]))')"  '[1 3 5 2 4 6]'
# lazy over an infinite outer coll (must not hang)
assert_eq 'mapcat_lazy'   "$("$BIN" -e '(into [] (take 5 (mapcat (fn* [x] [x x]) (range))))')" '[0 0 1 1 2]'

echo "ALL phase14_core_cluster PASS"
