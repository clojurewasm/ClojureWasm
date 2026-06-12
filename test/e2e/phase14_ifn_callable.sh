#!/usr/bin/env bash
# test/e2e/phase14_ifn_callable.sh — data structures + keywords as IFn
# (D-085): keyword·symbol·map·set·vector invoked as functions, directly,
# inside higher-order fns (map/filter/apply), and as bare threading steps
# (-> m :k) / (some-> m :k) (threadStep keyword arm).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# keyword as fn
assert_eq 'kw_get'    "$("$BIN" -e '(:a {:a 1 :b 2})')"        '1'
assert_eq 'kw_dflt'   "$("$BIN" -e '(:c {:a 1} :missing)')"    ':missing'
assert_eq 'kw_empty'  "$("$BIN" -e '(:a {})')"                 'nil'
assert_eq 'kw_nil'    "$("$BIN" -e '(:a nil)')"                'nil'
assert_eq 'kw_nonmap' "$("$BIN" -e '(:a 5)')"                  'nil'
# symbol as fn
assert_eq 'sym_get'   "$("$BIN" -e "('x {'x 7})")"             '7'
# map as fn (array_map + hash_map)
assert_eq 'map_get'   "$("$BIN" -e '({:a 1 :b 2} :b)')"        '2'
assert_eq 'map_miss'  "$("$BIN" -e '({:a 1} :z)')"             'nil'
assert_eq 'map_dflt'  "$("$BIN" -e '({:a 1} :z :fb)')"         ':fb'
assert_eq 'hmap_get'  "$("$BIN" -e '((into {} (map (fn [i] [i (* i i)]) (range 20))) 7)')" '49'
# set as fn
assert_eq 'set_in'    "$("$BIN" -e '(#{1 2 3} 2)')"            '2'
assert_eq 'set_out'   "$("$BIN" -e '(#{1 2 3} 9)')"            'nil'
# vector as fn (nth; throws on OOB, like nth)
assert_eq 'vec_idx'   "$("$BIN" -e '([10 20 30] 1)')"          '20'
assert_has 'vec_oob'  "$("$BIN" -e '([10 20 30] 5)' 2>&1)"     'nth'
assert_has 'vec_neg'  "$("$BIN" -e '([10 20 30] -1)' 2>&1)"    'nth'
# higher-order use — the high-value payoff
assert_eq 'map_kw'    "$("$BIN" -e '(map :a [{:a 1} {:a 2} {:a 3}])')"  '(1 2 3)'
assert_eq 'filter_kw' "$("$BIN" -e '(count (filter :ok [{:ok true} {:ok false} {:ok true}]))')" '2'
assert_eq 'apply_kw'  "$("$BIN" -e '(apply :a [{:a 99}])')"    '99'
assert_eq 'map_mapfn' "$("$BIN" -e '(map {:a 1 :b 2} [:a :b])')"  '(1 2)'
assert_eq 'map_setfn' "$("$BIN" -e '(map #{1 3} [1 2 3])')"    '(1 nil 3)'
assert_eq 'mapv_vfn'  "$("$BIN" -e '(mapv [10 20 30] [0 2])')" '[10 30]'
# keyword/symbol as bare threading steps (threadStep keyword arm)
assert_eq 'thread_kw'  "$("$BIN" -e '(-> {:a {:b 5}} :a :b)')"     '5'
assert_eq 'threadl_kw' "$("$BIN" -e '(->> {:a 3} :a)')"            '3'
assert_eq 'some_kw'    "$("$BIN" -e '(some-> {:a 1} :a)')"         '1'
assert_eq 'thread_mix' "$("$BIN" -e '(-> {:a 1} :a inc (* 10))')"  '20'
# arity errors
assert_has 'kw_arity' "$("$BIN" -e '(:a {:a 1} :b :c)' 2>&1)"  'keyword'
assert_has 'set_arity' "$("$BIN" -e '(#{1} 1 2)' 2>&1)"        'set'
echo "OK — phase14_ifn_callable smoke (27 cases) green"
