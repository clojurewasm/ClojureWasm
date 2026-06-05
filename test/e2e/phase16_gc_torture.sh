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

echo "ALL phase16_gc_torture PASS"
