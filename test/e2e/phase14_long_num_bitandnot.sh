#!/usr/bin/env bash
# test/e2e/phase14_long_num_bitandnot.sh — long / num coercions + bit-and-not
# (D-134). long ≡ int (cw v1 has one i64 integer type). num is identity for
# any numeric (type error otherwise). bit-and-not = x AND (NOT y).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# long (truncates float, passes integer, codepoint of char)
assert_eq 'long_float' "$("$BIN" -e '(long 3.7)')" '3'
assert_eq 'long_int'   "$("$BIN" -e '(long 5)')"   '5'
assert_eq 'long_char'  "$("$BIN" -e '(long (char 65))')" '65'
# num (identity for numbers)
assert_eq 'num_int'    "$("$BIN" -e '(num 5)')"   '5'
assert_eq 'num_float'  "$("$BIN" -e '(num 1.5)')" '1.5'
assert_has 'num_str'   "$("$BIN" -e '(num "x")' 2>&1)" 'expected number'
# bit-and-not
assert_eq 'ban_7_2'    "$("$BIN" -e '(bit-and-not 7 2)')"  '5'
assert_eq 'ban_15_9'   "$("$BIN" -e '(bit-and-not 15 9)')" '6'
assert_eq 'ban_0_0'    "$("$BIN" -e '(bit-and-not 0 0)')"  '0'
echo "OK — phase14_long_num_bitandnot smoke (9 cases) green"
