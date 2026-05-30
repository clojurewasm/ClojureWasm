#!/usr/bin/env bash
# test/e2e/phase14_ratio_arith.sh — ratio arithmetic (+ - * /) over ratio
# operands, incl. mixed ratio⊗integer, integer-collapse to Long, and
# float-contagion (ratio⊗float). Mirrors JVM Clojure: (+ 1/2 1/2) → 1
# (a Long, not 1/1); (* 1/2 0.5) → 0.25 (float).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# ratio ⊗ ratio
assert_eq 'add_collapse' "$("$BIN" -e '(+ 1/2 1/2)')"   '1'
assert_eq 'add_ratio'    "$("$BIN" -e '(+ 1/2 1/3)')"   '5/6'
assert_eq 'sub_ratio'    "$("$BIN" -e '(- 1/2 1/3)')"   '1/6'
assert_eq 'sub_neg'      "$("$BIN" -e '(- 1/3 1/2)')"   '-1/6'
assert_eq 'mul_ratio'    "$("$BIN" -e '(* 1/3 1/3)')"   '1/9'
assert_eq 'mul_collapse' "$("$BIN" -e '(* 2/3 3/2)')"   '1'
assert_eq 'div_ratio'    "$("$BIN" -e '(/ 1/2 1/3)')"   '3/2'
# ratio ⊗ integer (mixed)
assert_eq 'mul_int'      "$("$BIN" -e '(* 1/2 4)')"     '2'
assert_eq 'mul_int_l'    "$("$BIN" -e '(* 4 1/2)')"     '2'
assert_eq 'mul_int_r'    "$("$BIN" -e '(* 1/10 10)')"   '1'
assert_eq 'add_int'      "$("$BIN" -e '(+ 3 1/2)')"     '7/2'
assert_eq 'sub_int'      "$("$BIN" -e '(- 1/2 3)')"     '-5/2'
assert_eq 'div_int'      "$("$BIN" -e '(/ 1/2 3)')"     '1/6'
assert_eq 'div_int_l'    "$("$BIN" -e '(/ 3 1/2)')"     '6'
# integer / by ratio collapse
assert_eq 'mul_chain'    "$("$BIN" -e '(* 1/2 2/3 3/4)')" '1/4'
assert_eq 'add_chain'    "$("$BIN" -e '(+ 1/4 1/4 1/4 1/4)')" '1'
# float contagion (ratio ⊗ float → float)
assert_eq 'mul_float'    "$("$BIN" -e '(* 1/2 0.5)')"   '0.25'
assert_eq 'add_float'    "$("$BIN" -e '(+ 1/2 0.5)')"   '1.0'
assert_eq 'div_float'    "$("$BIN" -e '(/ 1/4 0.5)')"   '0.5'
# divide-by-zero on the ratio path
assert_has 'div_zero'    "$("$BIN" -e '(/ 1/2 0)' 2>&1)" 'Divide by zero'
# round-trip with rationalize / division output
assert_eq 'half_plus'    "$("$BIN" -e '(+ (/ 1 4) (/ 1 4))')" '1/2'
echo "OK — phase14_ratio_arith smoke (21 cases) green"
