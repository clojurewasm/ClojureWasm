#!/usr/bin/env bash
# test/e2e/phase14_map_helpers.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 2. Eager map/seq helpers:
# reduce-kv / update-keys / update-vals / not-any? / butlast. Pure
# Pattern A over reduce / keys / get / assoc / some / not / reverse /
# rest / conj (no lazy-seq dependency). (dedupe/distinct/frequencies/
# group-by need a working universal `=` — D-136 — and follow that fix.)
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

assert_eq 'reduce_kv_sum'   "$("$BIN" -e '(reduce-kv (fn* [acc k v] (+ acc v)) 0 {:a 1 :b 2})')" '3'
assert_eq 'update_keys'     "$("$BIN" -e '(get (update-keys {1 :a} inc) 2)')"                    ':a'
assert_eq 'update_vals'     "$("$BIN" -e '(get (update-vals {:a 1} inc) :a)')"                   '2'
assert_eq 'not_any_true'    "$("$BIN" -e '(not-any? (fn* [x] (= x 9)) [1 2 3])')"                'true'
assert_eq 'not_any_false'   "$("$BIN" -e '(not-any? (fn* [x] (= x 2)) [1 2 3])')"                'false'
assert_eq 'butlast_vec'     "$("$BIN" -e '(into [] (butlast [1 2 3]))')"                         '[1 2]'

echo "ALL phase14_map_helpers PASS"
