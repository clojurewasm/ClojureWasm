#!/usr/bin/env bash
# test/e2e/phase14_seq_helpers2.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 4. empty? / interpose / fnil /
# zipmap / interleave. Pattern A over count / reduce / conj / rest /
# first / assoc / into / nil? / or (+ recursion for zipmap/interleave).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'empty_yes'    "$("$BIN" -e '(empty? [])')"                         'true'
assert_eq 'empty_no'     "$("$BIN" -e '(empty? [1])')"                        'false'
assert_eq 'empty_nil'    "$("$BIN" -e '(empty? nil)')"                        'true'
assert_eq 'interpose'    "$("$BIN" -e '(into [] (interpose :s [1 2 3]))')"    '[1 :s 2 :s 3]'
assert_eq 'interpose_one' "$("$BIN" -e '(into [] (interpose :s [1]))')"       '[1]'
# 1-arg transducer forms (§A26 sweep): interpose / drop-while as xforms.
assert_eq 'interpose_xf'  "$("$BIN" -e '(into [] (interpose 0) [1 2 3])')"     '[1 0 2 0 3]'
assert_eq 'drop_while_xf' "$("$BIN" -e '(into [] (drop-while neg?) [-1 -2 3 4])')" '[3 4]'
assert_eq 'drop_while_comp' "$("$BIN" -e '(into [] (comp (drop-while neg?) (take 1)) [-1 3 4 5])')" '[3]'
assert_eq 'fnil_nil'     "$("$BIN" -e '((fnil inc 0) nil)')"                  '1'
assert_eq 'fnil_val'     "$("$BIN" -e '((fnil inc 0) 5)')"                    '6'
# fnil 2/3-default arities + variadic-pass-through (was 1-default, 1-arg only)
assert_eq 'fnil_2def'    "$("$BIN" -e '((fnil + 0 0) nil nil)')"             '0'
assert_eq 'fnil_2mix'    "$("$BIN" -e '((fnil + 10 20) nil 5)')"            '15'
assert_eq 'fnil_trail'   "$("$BIN" -e '((fnil + 0) nil 1 2 3)')"            '6'
assert_eq 'zipmap'       "$("$BIN" -e '(get (zipmap [:a :b] [1 2]) :b)')"     '2'
# zipmap: dup keys last-wins (Clojure semantics) + no stack overflow at scale
assert_eq 'zipmap_dup'   "$("$BIN" -e '(zipmap [:a :a] [1 2])')"            '{:a 2}'
assert_eq 'zipmap_large' "$("$BIN" -e '(count (zipmap (range 5000) (range 5000)))')" '5000'
assert_eq 'interleave'   "$("$BIN" -e '(into [] (interleave [1 2] [:a :b]))')" '[1 :a 2 :b]'
assert_eq 'interleave_unequal' "$("$BIN" -e '(into [] (interleave [1 2 3] [:a :b]))')" '[1 :a 2 :b]'
# large interleave must not blow the stack (loop/recur, was non-tail recursion)
assert_eq 'interleave_large' "$("$BIN" -e '(count (interleave (range 50000) (range 50000)))')" '100000'
# variadic (3+ colls) + SEQ return (JVM parity, clj-verified)
assert_eq 'interleave_3'   "$("$BIN" -e '(interleave [1 2] [3 4] [5 6])')" '(1 3 5 2 4 6)'
assert_eq 'interleave_1'   "$("$BIN" -e '(interleave [1 2])')"             '(1 2)'
assert_eq 'interleave_seq' "$("$BIN" -e '(seq? (interleave [1] [2]))')"    'true'

echo "ALL phase14_seq_helpers2 PASS"
