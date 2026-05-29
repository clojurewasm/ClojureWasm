#!/usr/bin/env bash
# test/e2e/phase14_compare.sh
#
# Phase 14 §9.16 — D-137. General 3-way `compare` (= clojure.lang.Util.compare),
# was numeric-only. ADR-0053. nil lowest; numbers cross the tower; strings
# lexicographic; bool false<true; keywords/symbols ns-then-name; vectors
# length-first then element-wise; uncomparable pairs raise.
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

# numbers (incl. cross int/float)
assert_eq 'num_lt'    "$("$BIN" -e '(compare 1 2)')"      '-1'
assert_eq 'num_eq'    "$("$BIN" -e '(compare 2 2)')"      '0'
assert_eq 'num_gt'    "$("$BIN" -e '(compare 3 1)')"      '1'
assert_eq 'num_cross' "$("$BIN" -e '(compare 1 1.0)')"    '0'
assert_eq 'num_float' "$("$BIN" -e '(compare 1.5 2)')"    '-1'
# nil lowest
assert_eq 'nil_nil'   "$("$BIN" -e '(compare nil nil)')"  '0'
assert_eq 'nil_lt'    "$("$BIN" -e '(compare nil 5)')"    '-1'
assert_eq 'nil_gt'    "$("$BIN" -e '(compare 5 nil)')"    '1'
# keywords / strings
assert_eq 'kw_lt'     "$("$BIN" -e '(compare :a :b)')"    '-1'
assert_eq 'kw_eq'     "$("$BIN" -e '(compare :a :a)')"    '0'
assert_eq 'str_lt'    "$("$BIN" -e '(compare "a" "b")')"  '-1'
assert_eq 'str_eq'    "$("$BIN" -e '(compare "abc" "abc")')" '0'
# vectors (length-first then element-wise)
assert_eq 'vec_elem'  "$("$BIN" -e '(compare [1 2] [1 3])')"  '-1'
assert_eq 'vec_len'   "$("$BIN" -e '(compare [1] [1 2])')"    '-1'
assert_eq 'vec_eq'    "$("$BIN" -e '(compare [1 2] [1 2])')"  '0'
# booleans
assert_eq 'bool_lt'   "$("$BIN" -e '(compare false true)')"   '-1'
assert_eq 'bool_gt'   "$("$BIN" -e '(compare true false)')"   '1'

echo "ALL phase14_compare PASS"
