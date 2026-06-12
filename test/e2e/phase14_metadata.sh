#!/usr/bin/env bash
# test/e2e/phase14_metadata.sh — runtime metadata: meta / with-meta /
# vary-meta over collections (vector / map / set / list). Value model
# already carries a `meta: Value` field per type (ArrayMap gains one).
# Reader `^meta` + alter-meta!/reset-meta! + symbol meta are deferred.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# meta read: nil when absent, the map when present
assert_eq 'meta_nil'   "$("$BIN" -e '(meta [1 2])')"                       'nil'
assert_eq 'meta_int'   "$("$BIN" -e '(meta 5)')"                           'nil'
assert_eq 'wm_vec'     "$("$BIN" -e '(meta (with-meta [1 2] {:a 1}))')"    '{:a 1}'
assert_eq 'wm_map'     "$("$BIN" -e '(meta (with-meta {:x 1} {:m 1}))')"   '{:m 1}'
assert_eq 'wm_set'     "$("$BIN" -e '(meta (with-meta #{1} {:m 1}))')"     '{:m 1}'
assert_eq 'wm_list'    "$("$BIN" -e "(meta (with-meta '(1 2) {:m 1}))")"   '{:m 1}'
assert_eq 'wm_hashmap' "$("$BIN" -e '(meta (with-meta (into {} (map (fn [i] [i i]) (range 20))) {:m 1}))')" '{:m 1}'
# value is preserved (with-meta keeps the value, sets meta)
assert_eq 'wm_keepval' "$("$BIN" -e '(with-meta [1 2 3] {:a 1})')"         '[1 2 3]'
assert_eq 'wm_kw'      "$("$BIN" -e '(:a (meta (with-meta [1] {:a 5})))')" '5'
# vary-meta
assert_eq 'vary'       "$("$BIN" -e '(meta (vary-meta (with-meta [1] {:a 1}) assoc :b 2))')" '{:a 1, :b 2}'
assert_eq 'vary_nil'   "$("$BIN" -e '(meta (vary-meta [1] assoc :b 2))')"  '{:b 2}'
# ops preserve meta on the same-type result (cljw struct-copies thread .meta)
assert_eq 'preserve'   "$("$BIN" -e '(meta (assoc (with-meta {:a 1} {:m 1}) :b 2))')" '{:m 1}'
assert_eq 'preserve_v' "$("$BIN" -e '(meta (conj (with-meta [1] {:m 1}) 2))')" '{:m 1}'
# errors: non-IObj target, non-map meta
assert_has 'err_target' "$("$BIN" -e '(with-meta 5 {:a 1})' 2>&1)"         'meta'
assert_has 'err_notmap' "$("$BIN" -e '(with-meta [1] 5)' 2>&1)"            'meta'
# clojure.set/project + rename now preserve the source rel's meta (D-075 wrap restored)
assert_eq 'set_project' "$("$BIN" -e '(meta (clojure.set/project (with-meta #{{:a 1}} {:r 1}) [:a]))')" '{:r 1}'
assert_eq 'set_rename'  "$("$BIN" -e '(meta (clojure.set/rename (with-meta #{{:a 1}} {:r 1}) {:a :b}))')" '{:r 1}'
echo "OK — phase14_metadata smoke (17 cases) green"
