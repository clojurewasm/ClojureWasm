#!/usr/bin/env bash
# test/e2e/phase14_empty_list.sh
#
# D-164 / clj-parity C1: the empty list `()` is a DISTINCT interned Value
# (JVM `PersistentList.EMPTY`), not nil. `(seq? '())`/`(list? '())`→true,
# `(= '() nil)`→false, `(pr-str '())`→"()", and `(rest …)` of any empty
# seq yields `()` not nil (JVM `RT.more`) while `(next …)`/`(seq …)` stay
# nil (the more/next asymmetry). Supersedes the earlier D-188 assertions
# that `()` collapsed to nil.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# `()` self-evaluates to the distinct empty list, not nil.
assert_eq 'el_eval'      "$("$BIN" -e '()')"                    '()'
assert_eq 'el_in_fn'     "$("$BIN" -e '((fn* [] ()))')"         '()'
assert_eq 'el_let'       "$("$BIN" -e '(let [x ()] x)')"        '()'
assert_eq 'el_quote'     "$("$BIN" -e '(quote ())')"            '()'

# Distinct from nil; equal to other empty spellings + empty vector.
assert_eq 'el_ne_nil'    "$("$BIN" -e '(= () nil)')"            'false'
assert_eq 'el_eq_list'   "$("$BIN" -e '(= () (list))')"         'true'
assert_eq 'el_eq_quote'  "$("$BIN" -e '(= () (quote ()))')"     'true'
assert_eq 'el_eq_vec'    "$("$BIN" -e '(= () [])')"             'true'

# Predicates key on the `.list` tag, so they are true for `()`.
assert_eq 'el_list_q'    "$("$BIN" -e '(list? ())')"            'true'
assert_eq 'el_seq_q'     "$("$BIN" -e '(seq? ())')"             'true'
assert_eq 'el_empty_q'   "$("$BIN" -e '(empty? ())')"           'true'
assert_eq 'el_count'     "$("$BIN" -e '(count ())')"            '0'

# seq / first / next of empty → nil (JVM); rest → () (the asymmetry).
assert_eq 'el_seq'       "$("$BIN" -e '(seq ())')"              'nil'
assert_eq 'el_first'     "$("$BIN" -e '(first ())')"            'nil'
assert_eq 'el_next'      "$("$BIN" -e '(next ())')"             'nil'
assert_eq 'el_rest'      "$("$BIN" -e '(rest ())')"             '()'

# rest of a 1-elem coll / nil / vector → () (RT.more); next → nil.
assert_eq 'el_rest1'     "$("$BIN" -e '(rest (quote (1)))')"    '()'
assert_eq 'el_rest_nil'  "$("$BIN" -e '(rest nil)')"            '()'
assert_eq 'el_rest_vec'  "$("$BIN" -e '(rest [1])')"            '()'
assert_eq 'el_next1'     "$("$BIN" -e '(next (quote (1)))')"    'nil'
assert_eq 'el_rest_isl'  "$("$BIN" -e '(list? (rest (quote (1))))')" 'true'

# `(list)` → () (JVM PersistentList/EMPTY), distinct from `& xs`→nil.
assert_eq 'el_list0'     "$("$BIN" -e '(list)')"               '()'
assert_eq 'el_fn_rest0'  "$("$BIN" -e '((fn* [& xs] xs))')"    'nil'
assert_eq 'el_apply'     "$("$BIN" -e '(apply list [])')"      '()'

# Empty results of the seq pipeline print `()` not nil (one big-bang).
assert_eq 'el_filter'    "$("$BIN" -e '(filter even? [1 3])')"  '()'
assert_eq 'el_map_nil'   "$("$BIN" -e '(map inc nil)')"        '()'
assert_eq 'el_take0'     "$("$BIN" -e '(take 0 [1 2])')"       '()'
assert_eq 'el_distinct'  "$("$BIN" -e '(distinct [])')"        '()'
assert_eq 'el_sort'      "$("$BIN" -e '(sort [])')"            '()'
assert_eq 'el_range0'    "$("$BIN" -e '(range 0)')"            '()'
assert_eq 'el_concat0'   "$("$BIN" -e '(concat)')"            '()'
assert_eq 'el_conj'      "$("$BIN" -e '(conj () 1)')"          '(1)'

# butlast of ≤1 elem → nil (JVM `(seq ret)`); >1 → the prefix list.
assert_eq 'el_butlast1'  "$("$BIN" -e '(butlast [1])')"        'nil'
assert_eq 'el_butlast3'  "$("$BIN" -e '(butlast [1 2 3])')"    '(1 2)'

echo "ALL phase14_empty_list PASS"
