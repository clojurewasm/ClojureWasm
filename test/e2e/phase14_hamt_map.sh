#!/usr/bin/env bash
# test/e2e/phase14_hamt_map.sh — PersistentHashMap HAMT body (D-045 cycle A).
# Maps with > 8 entries promote ArrayMap -> HamtMap; build (assoc/into) +
# read (get/contains?) must work. Exercises string-key-by-bytes (D-151)
# + int + keyword keys through the trie, literal promotion, assoc
# replace/insert on a .hash_map, and contains? vs nil-value disambiguation.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# headline: 20 string keys (forces promotion past 8 + D-151 byte-match)
assert_eq 'str20_get'  "$("$BIN" -e '(get (into {} (map (fn [i] [(str i) i]) (range 20))) "5")')" '5'
assert_eq 'str20_cnt'  "$("$BIN" -e '(count (into {} (map (fn [i] [(str i) i]) (range 20))))')"   '20'
assert_eq 'str20_miss' "$("$BIN" -e '(get (into {} (map (fn [i] [(str i) i]) (range 20))) "99")')" 'nil'
# 50 int keys
assert_eq 'int50_cnt'  "$("$BIN" -e '(count (into {} (map (fn [i] [i (* i i)]) (range 50))))')"    '50'
assert_eq 'int50_get'  "$("$BIN" -e '(get (into {} (map (fn [i] [i (* i i)]) (range 50))) 7)')"    '49'
# 30 keyword keys (interned)
assert_eq 'kw30_get'   "$("$BIN" -e '(get (into {} (map (fn [i] [(keyword (str "k" i)) i]) (range 30))) :k15)')" '15'
# contains? true/false
assert_eq 'cont_t'     "$("$BIN" -e '(contains? (into {} (map (fn [i] [(str i) i]) (range 20))) "13")')" 'true'
assert_eq 'cont_f'     "$("$BIN" -e '(contains? (into {} (map (fn [i] [(str i) i]) (range 20))) "x")')"  'false'
# map literal with > 8 keys promotes
assert_eq 'lit_cnt'    "$("$BIN" -e '(count {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10})')" '10'
assert_eq 'lit_get'    "$("$BIN" -e '(get {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10} :i)')" '9'
# assoc on a .hash_map: replace keeps count, insert grows it
assert_eq 'assoc_repl' "$("$BIN" -e '(get (assoc (into {} (map (fn [i] [i i]) (range 12))) 3 :x) 3)')" ':x'
assert_eq 'assoc_repl_cnt' "$("$BIN" -e '(count (assoc (into {} (map (fn [i] [i i]) (range 12))) 3 :x))')" '12'
assert_eq 'assoc_ins_cnt'  "$("$BIN" -e '(count (assoc (into {} (map (fn [i] [i i]) (range 12))) 100 :new))')" '13'
# contains? distinguishes a nil value from an absent key
assert_eq 'nil_val_get'  "$("$BIN" -e '(get (assoc (into {} (map (fn [i] [i i]) (range 10))) :k nil) :k)')" 'nil'
assert_eq 'nil_val_cont' "$("$BIN" -e '(contains? (assoc (into {} (map (fn [i] [i i]) (range 10))) :k nil) :k)')" 'true'
# --- cycle B: keys / vals / seq / dissoc / print / equality ---
assert_eq 'keys_cnt'   "$("$BIN" -e '(count (keys (into {} (map (fn [i] [i i]) (range 20)))))')" '20'
assert_eq 'vals_sum'   "$("$BIN" -e '(apply + (vals (into {} (map (fn [i] [i i]) (range 12)))))')" '66'
assert_eq 'keys_set'   "$("$BIN" -e '(= (set (keys (into {} (map (fn [i] [i i]) (range 12))))) (set (range 12)))')" 'true'
assert_eq 'map_eq'     "$("$BIN" -e '(= (into {} (map (fn [i] [i i]) (range 20))) (into {} (map (fn [i] [i i]) (range 20))))')" 'true'
assert_eq 'map_neq'    "$("$BIN" -e '(= (into {} (map (fn [i] [i i]) (range 20))) (into {} (map (fn [i] [i i]) (range 19))))')" 'false'
assert_eq 'dissoc_cnt' "$("$BIN" -e '(count (dissoc (into {} (map (fn [i] [i i]) (range 20))) 5))')" '19'
assert_eq 'dissoc_get' "$("$BIN" -e '(get (dissoc (into {} (map (fn [i] [i i]) (range 20))) 5) 5)')" 'nil'
assert_eq 'dissoc_oth' "$("$BIN" -e '(get (dissoc (into {} (map (fn [i] [i i]) (range 20))) 5) 7)')" '7'
assert_eq 'dissoc_abs' "$("$BIN" -e '(count (dissoc (into {} (map (fn [i] [i i]) (range 20))) 999))')" '20'
# print is no longer silently empty — 12 entries => 11 commas => 12 splits
assert_eq 'map_print'  "$("$BIN" -e '(count (clojure.string/split (str (into {} (map (fn [i] [i i]) (range 12)))) #","))')" '12'
# set ops on a > 8 set (backed transitively by the map HAMT)
assert_eq 'set_cnt'    "$("$BIN" -e '(count (into #{} (range 20)))')" '20'
assert_eq 'set_cont'   "$("$BIN" -e '(contains? (into #{} (range 20)) 13)')" 'true'
assert_eq 'set_disj'   "$("$BIN" -e '(count (disj (into #{} (range 20)) 5))')" '19'
assert_eq 'set_seqsum' "$("$BIN" -e '(apply + (into #{} (range 12)))')" '66'
assert_eq 'set_eq'     "$("$BIN" -e '(= (into #{} (range 20)) (into #{} (range 20)))')" 'true'
echo "OK — phase14_hamt_map smoke (28 cases) green"
