#!/usr/bin/env bash
# test/e2e/phase14_equality.sh
#
# Phase 14 §9.16 — D-136. `=` universal value equality (was numeric-only,
# a correctness bug) vs `==` numeric-tower equivalence. ADR-0052.
# `=` = clojure.lang.Util.equiv: by-value across nil/bool/number/char/
# keyword/symbol/string, structural for sequentials (vector/list cross-
# type) + maps/sets, numeric category-gated per F-005 ((= 1 1.0)->false);
# never raises on type mismatch. `==` widens numeric categories.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- the bug cases (previously type_error) ---
assert_eq 'eq_kw_same'    "$("$BIN" -e '(= :a :a)')"          'true'
assert_eq 'eq_kw_diff'    "$("$BIN" -e '(= :a :b)')"          'false'
assert_eq 'eq_nil'        "$("$BIN" -e '(= nil nil)')"        'true'
assert_eq 'eq_int_nil'    "$("$BIN" -e '(= 1 nil)')"          'false'
assert_eq 'eq_str_same'   "$("$BIN" -e '(= "a" "a")')"        'true'
assert_eq 'eq_str_diff'   "$("$BIN" -e '(= "a" "b")')"        'false'
assert_eq 'eq_bool'       "$("$BIN" -e '(= true true)')"      'true'
assert_eq 'eq_bool_diff'  "$("$BIN" -e '(= true false)')"     'false'

# --- structural collections ---
assert_eq 'eq_vec_same'   "$("$BIN" -e '(= [1 2] [1 2])')"    'true'
assert_eq 'eq_vec_diff'   "$("$BIN" -e '(= [1 2] [1 3])')"    'false'
assert_eq 'eq_vec_len'    "$("$BIN" -e '(= [1 2] [1 2 3])')"  'false'
assert_eq 'eq_nested'     "$("$BIN" -e '(= [1 [2 3]] [1 [2 3]])')" 'true'
assert_eq 'eq_map_same'   "$("$BIN" -e '(= {:a 1} {:a 1})')"  'true'
assert_eq 'eq_map_diff'   "$("$BIN" -e '(= {:a 1} {:a 2})')"  'false'
assert_eq 'eq_set_same'   "$("$BIN" -e '(= #{1 2} #{2 1})')"  'true'

# --- sequential cross-type (vector vs list) ---
assert_eq 'eq_seq_cross'  "$("$BIN" -e "(= [1 2] '(1 2))")"   'true'
assert_eq 'eq_set_not_vec' "$("$BIN" -e '(= #{1} [1])')"      'false'

# --- numeric category gate (= ) vs widening (==) ---
assert_eq 'eq_int_same'   "$("$BIN" -e '(= 1 1)')"            'true'
assert_eq 'eq_int_float'  "$("$BIN" -e '(= 1 1.0)')"          'false'
assert_eq 'equiv_int_float' "$("$BIN" -e '(== 1 1.0)')"       'true'
assert_eq 'equiv_int_int'   "$("$BIN" -e '(== 2 2)')"         'true'

echo "ALL phase14_equality PASS"
