#!/usr/bin/env bash
# test/e2e/phase14_transducers.sh — transducer surface (gap-map HIGH ROI).
# Cycle 1 (foundation): reduced / reduced? / unreduced / ensure-reduced +
# deref on a Reduced + reduce early-termination via (reduced acc). Later
# cycles add the transducer arities (map/filter/…), transduce, into-xform,
# completing, and the stateful transducers.
#
# Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# reduced sentinel surface
assert_eq 'reducedQ_t'  "$("$BIN" -e '(reduced? (reduced 5))')"            'true'
assert_eq 'reducedQ_f'  "$("$BIN" -e '(reduced? 5)')"                      'false'
assert_eq 'unreduced'   "$("$BIN" -e '(unreduced (reduced 7))')"          '7'
assert_eq 'unreduced_pl' "$("$BIN" -e '(unreduced 7)')"                   '7'
assert_eq 'ensure_red'  "$("$BIN" -e '(reduced? (ensure-reduced 5))')"    'true'
assert_eq 'ensure_idem' "$("$BIN" -e '(unreduced (ensure-reduced (reduced 9)))')" '9'
assert_eq 'deref_red'   "$("$BIN" -e '@(reduced 42)')"                    '42'
# reduce honors early termination
assert_eq 'reduce_early' "$("$BIN" -e '(reduce (fn [acc x] (if (>= acc 6) (reduced acc) (+ acc x))) 0 [1 2 3 4 5])')" '6'
# cycle 2: transducer arities + completing + transduce
assert_eq 'td_map'      "$("$BIN" -e '(transduce (map inc) + [1 2 3])')"       '9'
assert_eq 'td_filter'   "$("$BIN" -e '(transduce (filter even?) + 0 [1 2 3 4])')" '6'
assert_eq 'td_comp'     "$("$BIN" -e '(transduce (comp (map inc) (filter even?)) + 0 [1 2 3 4])')" '6'
assert_eq 'td_conj'     "$("$BIN" -e '(transduce (map inc) (completing conj) [] [1 2 3])')" '[2 3 4]'
assert_eq 'td_remove'   "$("$BIN" -e '(transduce (remove odd?) + 0 [1 2 3 4 5 6])')" '12'
assert_eq 'td_keep'     "$("$BIN" -e '(transduce (keep (fn [x] (if (even? x) x nil))) + 0 [1 2 3 4])')" '6'
# transducer arities must NOT break the lazy collection arities
assert_eq 'lazy_map'    "$("$BIN" -e '(into [] (map inc [1 2 3]))')"           '[2 3 4]'
assert_eq 'lazy_filter' "$("$BIN" -e '(into [] (filter even? [1 2 3 4]))')"    '[2 4]'
assert_eq 'lazy_inf'    "$("$BIN" -e '(first (map inc (iterate inc 0)))')"     '1'
# cycle 3a: conj 0/1/variadic arities + 3-arg into (transducer-aware)
assert_eq 'conj_0'      "$("$BIN" -e '(conj)')"                               '[]'
assert_eq 'conj_1'      "$("$BIN" -e '(conj [1 2])')"                         '[1 2]'
assert_eq 'conj_vararg' "$("$BIN" -e '(conj [1] 2 3 4)')"                     '[1 2 3 4]'
assert_eq 'into2_vec'   "$("$BIN" -e '(into [] [1 2 3])')"                     '[1 2 3]'
assert_eq 'into2_map'   "$("$BIN" -e '(into {} [[:a 1] [:b 2]])')"            '{:a 1, :b 2}'
assert_eq 'into3_map'   "$("$BIN" -e '(into [] (map inc) [1 2 3])')"          '[2 3 4]'
assert_eq 'into3_comp'  "$("$BIN" -e '(into [] (comp (filter even?) (map inc)) [1 2 3 4])')" '[3 5]'
assert_eq 'into3_set'   "$("$BIN" -e '(into #{} (map inc) [1 1 2 3])')"       '#{2 3 4}'
# cycle 3b: stateful transducers (take / drop / map-indexed)
assert_eq 'td_take'     "$("$BIN" -e '(into [] (take 3) [1 2 3 4 5])')"       '[1 2 3]'
assert_eq 'td_drop'     "$("$BIN" -e '(into [] (drop 2) [1 2 3 4 5])')"       '[3 4 5]'
assert_eq 'td_mapidx'   "$("$BIN" -e '(into [] (map-indexed (fn [i x] [i x])) [:a :b :c])')" '[[0 :a] [1 :b] [2 :c]]'
assert_eq 'td_comptake' "$("$BIN" -e '(into [] (comp (map inc) (take 2)) [1 2 3 4 5])')" '[2 3]'
assert_eq 'td_dropTake' "$("$BIN" -e '(into [] (comp (drop 1) (take 2)) [10 20 30 40])')" '[20 30]'
# take's ensure-reduced stops early even on an INFINITE lazy source
assert_eq 'td_take_inf' "$("$BIN" -e '(into [] (take 3) (iterate inc 0))')"   '[0 1 2]'
# regression: the lazy collection arities still work
assert_eq 'lazy_take'   "$("$BIN" -e '(into [] (take 3 [1 2 3 4 5]))')"       '[1 2 3]'
assert_eq 'lazy_drop'   "$("$BIN" -e '(into [] (drop 2 [1 2 3 4 5]))')"       '[3 4 5]'
# cycle 4: dedupe / distinct / partition-all transducers + cat
assert_eq 'td_dedupe'   "$("$BIN" -e '(into [] (dedupe) [1 1 2 2 2 3 1 1])')" '[1 2 3 1]'
assert_eq 'td_distinct' "$("$BIN" -e '(into [] (distinct) [1 2 1 3 2 4])')"   '[1 2 3 4]'
assert_eq 'td_partall'  "$("$BIN" -e '(into [] (partition-all 2) [1 2 3 4 5])')" '[[1 2] [3 4] [5]]'
assert_eq 'td_cat'      "$("$BIN" -e '(into [] cat [[1 2] [3 4] [5]])')"      '[1 2 3 4 5]'
assert_eq 'td_cat_map'  "$("$BIN" -e '(into [] (comp cat (map inc)) [[1 2] [3 4]])')" '[2 3 4 5]'
# cat + take: preserving-reduced must propagate the early-stop through cat
assert_eq 'td_cat_take' "$("$BIN" -e '(into [] (comp cat (take 3)) [[1 2] [3 4] [5 6]])')" '[1 2 3]'
assert_eq 'td_full'     "$("$BIN" -e '(into [] (comp (map inc) (filter even?) (distinct)) [1 1 2 3 3 4])')" '[2 4]'
# mapcat 1-arg xform = (comp (map f) cat) — the last single-arity arm (D-177)
assert_eq 'td_mapcat'    "$("$BIN" -e '(into [] (mapcat (fn [x] [x x])) [1 2 3])')" '[1 1 2 2 3 3]'
assert_eq 'td_mapcat_tr' "$("$BIN" -e '(transduce (mapcat range) + 0 [1 2 3])')"   '4'
# cycle 5: halt-when (sequence / eduction deferred — D-160, need lazy pull)
assert_eq 'halt_match'  "$("$BIN" -e '(transduce (halt-when neg?) conj [] [1 2 -3 4])')" '-3'
assert_eq 'halt_none'   "$("$BIN" -e '(transduce (halt-when neg?) conj [] [1 2 3])')" '[1 2 3]'
assert_eq 'halt_retf'   "$("$BIN" -e '(transduce (halt-when neg? (fn [r i] (conj r i))) conj [] [1 2 -3 4])')" '[1 2 -3]'
assert_eq 'halt_comp'   "$("$BIN" -e '(transduce (comp (map inc) (halt-when (fn [x] (> x 4)))) conj [] [1 2 3 4])')" '5'
echo "OK — phase14_transducers (44 cases, cycles 1-5; sequence/eduction = D-160) green"
