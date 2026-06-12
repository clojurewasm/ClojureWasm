#!/usr/bin/env bash
# test/e2e/phase14_vector_keys.sh — vector keys compared/hashed BY VALUE
# (D-092). Fixes `(frequencies [[1] [1] [2]])` → was {[1] 1, [1] 1, [2] 1}
# (identity-keyed bug), now {[1] 2, [2] 1}. Unblocks vector-keyed maps,
# group-by / distinct / set over vectors. (Lists / cross-type vec≡list
# keys are a residual.)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# vector key lookup by value
assert_eq 'get'       "$("$BIN" -e '(get {[1 2] :a} [1 2])')"        ':a'
assert_eq 'contains'  "$("$BIN" -e '(contains? {[1 2] :a} [1 2])')"  'true'
assert_eq 'get_miss'  "$("$BIN" -e '(get {[1 2] :a} [1 3])')"        'nil'
assert_eq 'assoc_rep' "$("$BIN" -e '(count (assoc {[1] :a} [1] :b))')" '1'
# frequencies / distinct / set over vectors (the headline bug)
assert_eq 'freq'      "$("$BIN" -e '(get (frequencies [[1] [1] [2]]) [1])')" '2'
assert_eq 'freq_cnt'  "$("$BIN" -e '(count (frequencies [[1] [1] [2]]))')"   '2'
assert_eq 'distinct'  "$("$BIN" -e '(count (distinct [[1] [1] [2] [2] [2]]))')" '2'
assert_eq 'set'       "$("$BIN" -e '(count (set [[1] [1] [2]]))')"    '2'
assert_eq 'set_in'    "$("$BIN" -e '(contains? (set [[1] [2]]) [1])')" 'true'
# nested vector keys (recursive)
assert_eq 'nested'    "$("$BIN" -e '(get {[[1] 2] :x} [[1] 2])')"     ':x'
# > 8 keys (HAMT path) with vector keys
assert_eq 'hamt'      "$("$BIN" -e '(get (into {} (map (fn [i] [[i] i]) (range 20))) [7])')" '7'
# distinct elements stay distinct
assert_eq 'distinct2' "$("$BIN" -e '(= (set [[1 2] [3 4]]) (set [[3 4] [1 2]]))')" 'true'
echo "OK — phase14_vector_keys smoke (12 cases) green"
