#!/usr/bin/env bash
# test/e2e/phase14_key_val.sh — (key e) / (val e) over map entries. cw v1
# represents map entries as 2-vectors (`(first {:a 1})` → `[:a 1]`), so
# key/val index positionally. Surfaced by the reduce/reduced clj-diff sweep
# (`(reduce (fn [acc e] (+ acc (val e))) 0 m)` raised name_error).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'key'        "$("$BIN" -e '(key (first {:a 1}))')"   ':a'
assert_eq 'val'        "$("$BIN" -e '(val (first {:a 1}))')"   '1'
assert_eq 'map_key'    "$("$BIN" -e '(map key {:a 1 :b 2})')"  '(:a :b)'
assert_eq 'map_val'    "$("$BIN" -e '(map val {:a 1 :b 2})')"  '(1 2)'
assert_eq 'reduce_val' "$("$BIN" -e '(reduce (fn [acc e] (+ acc (val e))) 0 {:a 1 :b 2})')" '3'
assert_eq 'key_vec'    "$("$BIN" -e '(key [:k :v])')"          ':k'
assert_eq 'val_vec'    "$("$BIN" -e '(val [:k :v])')"          ':v'
echo "OK — phase14_key_val smoke (7 cases) green"
