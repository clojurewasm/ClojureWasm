#!/usr/bin/env bash
# test/e2e/phase16_gc_torture.sh — GC torture regression guard (D-250 / D-251).
#
# Runs representative programs under CLJW_GC_TORTURE=1 (force a stop-the-world
# collect at every VM back-edge poll, post-bootstrap) and asserts they still
# produce the correct value. This locks the two GC fixes the torture mode
# surfaced:
#   - Function.header forced to offset 0 (D-251 layout class) — without it the
#     mark walk OOB-crashes on every .clj fn.
#   - the .fn_val GC trace that marks closure_bindings (D-251 rooting class) —
#     without it a fn's captured GC values are swept under collect.
#
# Scope: only the cases that are torture-clean today. The remaining D-251
# rooting gaps (transducer/interpose seq intermediates, protocol-machinery
# values) are NOT yet covered — adding them here is the close-out test for
# those fixes.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Every program runs with a collect forced at every back-edge poll.
export CLJW_GC_TORTURE=1

assert_eq 'arith'        "$("$BIN" -e '(+ 1 2)')"                                              '3'
assert_eq 'sum_squares'  "$("$BIN" -e '(reduce + (map (fn [x] (* x x)) (range 1 100)))')"      '328350'
assert_eq 'sqrt'         "$("$BIN" -e '(clojure.math/sqrt 16)')"                               '4.0'
assert_eq 'filter_count' "$("$BIN" -e '(count (filter even? (range 1 200)))')"                 '99'
# closure capturing a GC vector — exercises the .fn_val closure_bindings trace.
assert_eq 'closure_vec'  "$("$BIN" -e '(let [x [1 2 3]] ((fn [] (reduce + x))))')"             '6'
# nested closure capturing a captured value.
assert_eq 'closure_nest' "$("$BIN" -e '(let [a 10] (let [f (fn [b] (+ a b))] (f 5)))')"        '15'
# map building into a persistent map (HAMT nodes survive repeated collects).
assert_eq 'into_map'     "$("$BIN" -e '(count (into {} (map (fn [i] [i (* i i)]) (range 1 50))))')" '49'
# reduce accumulator rooted across the reducing-fn eval (ADR-0094 / D-251).
assert_eq 'reduce_sum'   "$("$BIN" -e '(reduce + (range 1 101))')"                                  '5050'
assert_eq 'mapv_lit'     "$("$BIN" -e '(mapv inc [10 20 30])')"                                     '[11 21 31]'
assert_eq 'frequencies'  "$("$BIN" -e '(frequencies [1 1 2 3 3 3])')"                               '{1 2, 2 1, 3 3}'
# reduce over a vector source (the .vector fast path's racc rooting).
assert_eq 'reduce_vec'   "$("$BIN" -e '(reduce + [1 2 3 4 5 6 7 8 9 10])')"                         '55'
# .clj reducing-fn closure rooted across iterations (f-slot) over a chunked
# range source (coll rooted across the first force) — D-251 / ADR-0094.
assert_eq 'reduce_clos'  "$("$BIN" -e '(count (reduce (fn [a x] (conj a (inc x))) [] (range 1 150)))')" '149'
assert_eq 'vec_range'    "$("$BIN" -e '(count (vec (range 1 1000)))')"                              '999'

# ADR-0095 Class 2a — executing-chunk LITERAL constants rooted via
# EvalFrame.constants. A bare string literal is reachable only through the
# chunk's constant pool until op_const loads it; without the pool as a root a
# pre-load torture collect swept it (`"hello"` -> garbage bytes).
assert_eq 'str_literal'  "$("$BIN" -e '(count "hello")')"                                           '5'
assert_eq 'str_concat'   "$("$BIN" -e '(apply str ["a" "b" "c"])')"                                 '"abc"'
# interpose's literal separator (a constant) survives the reduce realiser.
assert_eq 'interpose'    "$("$BIN" -e '(apply str (interpose "," (map str (range 1 30))))')"        '"1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29"'
# ADR-0095 Class 1 — persistent-waypoint re-clear: the source range captured in
# a map lazy-seq thunk's closure stays marked across repeated collects (the
# thunk fn's stale bit no longer blocks the closure re-trace).
assert_eq 'vec_lazymap'  "$("$BIN" -e '(count (vec (map inc (range 1 200))))')"                     '199'
assert_eq 'into_lazymap' "$("$BIN" -e '(count (into [] (map inc (range 1 200))))')"                 '199'
# map producing pair vectors into a hash-map under torture (HAMT + the pair
# vectors survive the reduce realiser).
assert_eq 'into_pairs'   "$("$BIN" -e '(count (into {} (map (fn [x] [x (* x x)]) (range 1 50))))')" '49'
# ADR-0095 Alt D — a DORMANT fn's chunk LITERAL constant rooted via traceFunction
# (the isGcManaged membrane makes that constant walk safe). `g` is reachable via
# its var but not executing between mapv calls; without the trace its "n=" literal
# is swept and the next call loads a dangling pointer.
assert_eq 'dormant_lit'  "$("$BIN" -e '(do (defn g [x] (str "n=" x)) (apply str (mapv g (range 1 20))))')" '"n=1n=2n=3n=4n=5n=6n=7n=8n=9n=10n=11n=12n=13n=14n=15n=16n=17n=18n=19"'
# keyword/symbol constants (gpa-interned, non-GC) are filtered by isGcManaged, so
# a fn whose body references a keyword is torture-clean.
assert_eq 'kw_const'     "$("$BIN" -e '(count (filter (fn [m] (:keep m)) [{:keep true} {:keep false} {:keep true}]))')" '2'
# D-252 C9 — the CLI result-print path realises a lazy seq (forcing thunks
# re-enters the VM); `result` is pinned across printResult so a collect mid-print
# does not sweep the seq + its source (was a hang/UAF, exit 124/garbage).
assert_eq 'print_lazy'   "$("$BIN" -e '(filter even? (range 1 20))')"                               '(2 4 6 8 10 12 14 16 18)'
# D-252 C2/C3 — every?/some? root the seq cursor across the predicate's reentrant
# eval (EvalFrame, like reduceFn); over a LAZY-MAP source the cursor was swept.
assert_eq 'some_lazy'    "$("$BIN" -e '(some (fn [x] (when (> x 150) x)) (map inc (range 1 200)))')" '151'
assert_eq 'every_lazy'   "$("$BIN" -e '(every? (fn [x] (< x 500)) (map inc (range 1 200)))')"        'true'

echo "ALL phase16_gc_torture PASS"
