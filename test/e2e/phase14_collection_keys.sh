#!/usr/bin/env bash
# test/e2e/phase14_collection_keys.sh — map / set / list keys (and
# cross-type vector≡list) compared/hashed BY VALUE (D-092). Extends the
# vector-key fix to every persistent collection: `(get {{:a 1} :x} {:a 1})`
# → :x, set dedup of maps, clojure.set/index merging map keys, cross-type
# `(get {[1 2] :v} '(1 2))` → :v. The user-facing `(hash coll)` is now
# content-based too (core.hashFn delegates to equal.valueHash).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# map keys by value
assert_eq 'map_get'      "$("$BIN" -e '(get {{:a 1} :found} {:a 1})')"      ':found'
assert_eq 'map_contains' "$("$BIN" -e '(contains? {{:a 1} 0} {:a 1})')"     'true'
assert_eq 'map_assoc'    "$("$BIN" -e '(count (assoc {} {:k 1} :x {:k 1} :y))')" '1'
assert_eq 'map_assoc_v'  "$("$BIN" -e '(get (assoc {} {:k 1} :x {:k 1} :y) {:k 1})')" ':y'
# set keys / set as element by value (order-independent)
assert_eq 'set_get'      "$("$BIN" -e '(get {#{1 2} :s} #{2 1})')"          ':s'
assert_eq 'set_dedup'    "$("$BIN" -e '(count (set [#{1 2} #{2 1}]))')"      '1'
# list keys + cross-type vector≡list (same ordered hash + element eq)
assert_eq 'list_get'     "$("$BIN" -e "(get {'(1 2) :l} '(1 2))")"          ':l'
assert_eq 'cross_vl'     "$("$BIN" -e "(get {[1 2] :v} '(1 2))")"           ':v'
assert_eq 'cross_lv'     "$("$BIN" -e "(get {'(1 2) :l} [1 2])")"           ':l'
# headline collection-keyed map ops
assert_eq 'freq'         "$("$BIN" -e '(get (frequencies [{:a 1} {:a 1} {:b 2}]) {:a 1})')" '2'
assert_eq 'set_of_maps'  "$("$BIN" -e '(count (set [{:a 1} {:a 1} {:a 2}]))')" '2'
assert_eq 'distinct'     "$("$BIN" -e '(count (distinct [{:a 1} {:a 1} {:b 2}]))')" '2'
assert_eq 'zipmap'       "$("$BIN" -e '(get (zipmap [{:a 1} {:b 2}] [10 20]) {:a 1})')" '10'
# clojure.set/index merges equal map keys; join finds matches
assert_eq 'index'        "$("$BIN" -e '(count (clojure.set/index #{{:a 1 :b 1} {:a 1 :b 2} {:a 2 :b 3}} [:a]))')" '2'
assert_eq 'join'         "$("$BIN" -e '(count (clojure.set/join #{{:a 1 :b 2}} #{{:a 1 :c 3}}))')" '1'
# user-facing (hash coll) is content-based + order-independent for maps/sets
assert_eq 'hash_map'     "$("$BIN" -e '(= (hash {:a 1 :b 2}) (hash {:b 2 :a 1}))')" 'true'
assert_eq 'hash_set'     "$("$BIN" -e '(= (hash #{1 2}) (hash #{2 1}))')"   'true'
assert_eq 'hash_vl'      "$("$BIN" -e "(= (hash [1 2]) (hash '(1 2)))")"    'true'
# nested + HAMT path (>8 keys)
assert_eq 'nested'       "$("$BIN" -e '(get {{:m {:k 1}} :deep} {:m {:k 1}})')" ':deep'
assert_eq 'hamt'         "$("$BIN" -e '(get (into {} (map (fn [i] [{:i i} i]) (range 20))) {:i 7})')" '7'
echo "OK — phase14_collection_keys smoke (20 cases) green"
