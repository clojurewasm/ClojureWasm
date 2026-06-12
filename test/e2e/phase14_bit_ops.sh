#!/usr/bin/env bash
# test/e2e/phase14_bit_ops.sh — bit-set / bit-clear / bit-flip / bit-test
# (D-134). .clj compositions over the bit-* Zig primitives. n = bit index.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'set_0_3'    "$("$BIN" -e '(bit-set 0 3)')"    '8'
assert_eq 'set_5_1'    "$("$BIN" -e '(bit-set 5 1)')"    '7'
assert_eq 'clear_15_1' "$("$BIN" -e '(bit-clear 15 1)')" '13'
assert_eq 'clear_8_3'  "$("$BIN" -e '(bit-clear 8 3)')"  '0'
assert_eq 'flip_0_3'   "$("$BIN" -e '(bit-flip 0 3)')"   '8'
assert_eq 'flip_back'  "$("$BIN" -e '(bit-flip 8 3)')"   '0'
assert_eq 'test_set'   "$("$BIN" -e '(bit-test 4 2)')"   'true'
assert_eq 'test_unset' "$("$BIN" -e '(bit-test 4 1)')"   'false'
assert_eq 'test_zero'  "$("$BIN" -e '(bit-test 0 0)')"   'false'
# round-trip: set then test then clear
assert_eq 'roundtrip'  "$("$BIN" -e '(bit-test (bit-set 0 5) 5)')" 'true'

# D-214: bit ops accept a Long operand in (2^47, i64] (heap-boxed Long, D-165)
# and keep the full 64-bit result — no i48 truncation, no float fallback. A
# true BigInt (>i64) / float / ratio still errors (clj's bit ops are Long-only).
assert_eq 'and_big'    "$("$BIN" -e '(bit-and 1000000000000000 1000000000000000)')" '1000000000000000'
assert_eq 'or_big'     "$("$BIN" -e '(bit-or 1000000000000000 255)')"                '1000000000000255'
assert_eq 'not_big'    "$("$BIN" -e '(bit-not 1000000000000000)')"                   '-1000000000000001'
assert_eq 'shl_62'     "$("$BIN" -e '(bit-shift-left 1 62)')"                        '4611686018427387904'
assert_eq 'shl_63wrap' "$("$BIN" -e '(bit-shift-left 1 63)')"                        '-9223372036854775808'
assert_eq 'ushr_neg1'  "$("$BIN" -e '(unsigned-bit-shift-right -1 1)')"              '9223372036854775807'
assert_eq 'set_big'    "$("$BIN" -e '(bit-set 1000000000000000 0)')"                 '1000000000000001'
assert_eq 'test_big'   "$("$BIN" -e '(bit-test 1000000000000000 40)')"               'true'
assert_eq 'longstat'   "$("$BIN" -e '(Long/highestOneBit 1000000000000000)')"        '562949953421312'
assert_eq 'longmax'    "$("$BIN" -e '(Long/max 1000000000000000 5)')"                '1000000000000000'
# true-BigInt / float operands error (clj's bit ops reject non-Long).
if "$BIN" -e '(bit-and 5N 3)' >/dev/null 2>&1; then fail 'and_bigint_n: should error'; fi
echo 'PASS and_bigint_n -> errors'
if "$BIN" -e '(bit-and 1.5 2)' >/dev/null 2>&1; then fail 'and_float: should error'; fi
echo 'PASS and_float -> errors'

echo "OK — phase14_bit_ops smoke (22 cases) green"
