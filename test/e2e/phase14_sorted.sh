#!/usr/bin/env bash
# test/e2e/phase14_sorted.sh — sorted-map / sorted-set (ADR-0057,
# persistent LLRB red-black tree, default valueCompare): build / get /
# contains? / count / keys / vals / seq (in key order) / assoc / conj /
# sorted? (cycle A) + dissoc / disj (LLRB delete, cycle B1). Custom -by
# comparators (B2) / subseq / rsubseq / rseq (C) still pending.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# sorted-map: ordered keys/vals regardless of insertion order
assert_eq 'keys_ord'  "$("$BIN" -e '(keys (sorted-map :c 3 :a 1 :b 2))')"  '(:a :b :c)'
assert_eq 'vals_ord'  "$("$BIN" -e '(vals (sorted-map :c 3 :a 1 :b 2))')"  '(1 2 3)'
assert_eq 'get'       "$("$BIN" -e '(get (sorted-map :a 1 :b 2) :b)')"     '2'
assert_eq 'count'     "$("$BIN" -e '(count (sorted-map :a 1 :b 2 :c 3))')" '3'
assert_eq 'cont_t'    "$("$BIN" -e '(contains? (sorted-map :a 1) :a)')"    'true'
assert_eq 'cont_f'    "$("$BIN" -e '(contains? (sorted-map :a 1) :z)')"    'false'
assert_eq 'num_ord'   "$("$BIN" -e '(keys (sorted-map 3 :c 1 :a 2 :b))')"  '(1 2 3)'
assert_eq 'dup_val'   "$("$BIN" -e '(get (sorted-map :a 1 :a 2) :a)')"     '2'
assert_eq 'dup_cnt'   "$("$BIN" -e '(count (sorted-map :a 1 :a 2))')"      '1'
assert_eq 'assoc'     "$("$BIN" -e '(keys (assoc (sorted-map :z 26) :a 1 :m 13))')" '(:a :m :z)'
assert_eq 'into20'    "$("$BIN" -e '(vec (keys (into (sorted-map) (map (fn [i] [(- 20 i) i]) (range 20)))))')" '[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20]'
assert_eq 'print_map' "$("$BIN" -e '(str (sorted-map :b 2 :a 1))')"        '"{:a 1, :b 2}"'
assert_eq 'as_fn'     "$("$BIN" -e '((sorted-map :a 1 :b 2) :b)')"         '2'
# sorted-set
assert_eq 'set_seq'   "$("$BIN" -e '(seq (sorted-set 5 3 1 4 2))')"        '(1 2 3 4 5)'
assert_eq 'set_cont'  "$("$BIN" -e '(contains? (sorted-set 1 2 3) 2)')"    'true'
assert_eq 'set_conj'  "$("$BIN" -e '(seq (conj (sorted-set 1 3) 2))')"     '(1 2 3)'
assert_eq 'set_dup'   "$("$BIN" -e '(count (sorted-set 1 2 2 3))')"        '3'
assert_eq 'set_print' "$("$BIN" -e '(str (sorted-set 3 1 2))')"           '"#{1 2 3}"'
# sorted?
assert_eq 'sortedQ_m' "$("$BIN" -e '(sorted? (sorted-map))')"            'true'
assert_eq 'sortedQ_s' "$("$BIN" -e '(sorted? (sorted-set))')"            'true'
assert_eq 'sortedQ_n' "$("$BIN" -e '(sorted? {})')"                      'false'
# dissoc / disj — LLRB delete (cycle B1), ordering preserved
assert_eq 'dissoc'    "$("$BIN" -e '(keys (dissoc (sorted-map :a 1 :b 2 :c 3) :b))')" '(:a :c)'
assert_eq 'dissoc_cnt' "$("$BIN" -e '(count (dissoc (sorted-map :a 1 :b 2 :c 3) :b))')" '2'
assert_eq 'dissoc_multi' "$("$BIN" -e '(keys (dissoc (sorted-map :a 1 :b 2 :c 3 :d 4) :b :d))')" '(:a :c)'
assert_eq 'dissoc_miss' "$("$BIN" -e '(count (dissoc (sorted-map :a 1) :z))')" '1'
assert_eq 'dissoc_empty' "$("$BIN" -e '(count (dissoc (sorted-map :a 1) :a))')" '0'
assert_eq 'disj'      "$("$BIN" -e '(seq (disj (sorted-set 1 2 3 4 5) 3))')" '(1 2 4 5)'
assert_eq 'disj_cnt'  "$("$BIN" -e '(count (disj (sorted-set 1 2 3) 2))')" '2'
assert_eq 'disj_drain' "$("$BIN" -e '(count (disj (disj (sorted-set 1 2) 1) 2))')" '0'
assert_eq 'dissoc_reorder' "$("$BIN" -e '(vec (keys (reduce dissoc (into (sorted-map) (map (fn [i] [i i]) (range 10))) [3 7 1 9])))')" '[0 2 4 5 6 8]'
# sorted-map-by / sorted-set-by — custom comparator (cycle B2)
assert_eq 'set_by_gt'   "$("$BIN" -e '(seq (sorted-set-by > 1 5 3 2 4))')"   '(5 4 3 2 1)'
assert_eq 'set_by_lt'   "$("$BIN" -e '(seq (sorted-set-by < 5 3 1 4 2))')"   '(1 2 3 4 5)'
assert_eq 'map_by_gt'   "$("$BIN" -e '(keys (sorted-map-by > 1 :a 3 :c 2 :b))')" '(3 2 1)'
assert_eq 'by_get'      "$("$BIN" -e '(get (sorted-map-by > 1 :a 2 :b) 2)')" ':b'
assert_eq 'by_disj'     "$("$BIN" -e '(seq (disj (sorted-set-by > 1 2 3 4 5) 3))')" '(5 4 2 1)'
assert_eq 'by_as_fn'    "$("$BIN" -e '((sorted-set-by > 1 2 3) 2)')"         '2'
assert_eq 'by_numeric'  "$("$BIN" -e '(seq (sorted-set-by (fn [a b] (- b a)) 1 2 3))')" '(3 2 1)'
assert_eq 'by_str_len'  "$("$BIN" -e '(vec (sorted-set-by (fn [a b] (- (count a) (count b))) "ccc" "a" "bb"))')" '["a" "bb" "ccc"]'
# rseq / reversible? (cycle C)
assert_eq 'rseq_smap'   "$("$BIN" -e '(rseq (sorted-map :a 1 :b 2 :c 3))')" '([:c 3] [:b 2] [:a 1])'
assert_eq 'rseq_sset'   "$("$BIN" -e '(rseq (sorted-set 3 1 2))')"         '(3 2 1)'
assert_eq 'rseq_vec'    "$("$BIN" -e '(rseq [1 2 3])')"                    '(3 2 1)'
assert_eq 'rseq_empty'  "$("$BIN" -e '(rseq (sorted-set))')"               'nil'
assert_eq 'rseq_by'     "$("$BIN" -e '(rseq (sorted-set-by > 1 2 3))')"    '(1 2 3)'
assert_eq 'rev_smap'    "$("$BIN" -e '(reversible? (sorted-map))')"        'true'
assert_eq 'rev_sset'    "$("$BIN" -e '(reversible? (sorted-set))')"        'true'
assert_eq 'rev_list'    "$("$BIN" -e '(reversible? (list 1 2))')"          'false'
# subseq / rsubseq — range queries (cycle C2)
assert_eq 'subseq_gt'   "$("$BIN" -e '(subseq (sorted-set 1 2 3 4 5) > 2)')" '(3 4 5)'
assert_eq 'subseq_gte'  "$("$BIN" -e '(subseq (sorted-set 1 2 3 4 5) >= 3)')" '(3 4 5)'
assert_eq 'subseq_lt'   "$("$BIN" -e '(subseq (sorted-set 1 2 3 4 5) < 3)')" '(1 2)'
assert_eq 'subseq_rng'  "$("$BIN" -e '(subseq (sorted-set 1 2 3 4 5 6 7) >= 2 <= 5)')" '(2 3 4 5)'
assert_eq 'subseq_map'  "$("$BIN" -e '(subseq (sorted-map 1 :a 2 :b 3 :c 4 :d) > 2)')" '([3 :c] [4 :d])'
assert_eq 'subseq_none' "$("$BIN" -e '(subseq (sorted-set 1 2 3) > 99)')"  'nil'
assert_eq 'rsubseq_gt'  "$("$BIN" -e '(rsubseq (sorted-set 1 2 3 4 5) > 2)')" '(5 4 3)'
assert_eq 'rsubseq_rng' "$("$BIN" -e '(rsubseq (sorted-set 1 2 3 4 5 6 7) > 2 < 6)')" '(5 4 3)'
assert_eq 'subseq_by'   "$("$BIN" -e '(subseq (sorted-set-by > 1 2 3 4 5) > 3)')" '(2 1)'
echo "OK — phase14_sorted smoke (55 cases) green"
