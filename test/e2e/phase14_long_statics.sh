#!/usr/bin/env bash
# test/e2e/phase14_long_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Long static methods. Surface runtime/java/lang/Long.zig,
# delegating parsing to the shared runtime/numeric/parse.zig leaf
# (F-011 DRY with parse-long / Integer/parseInt) but at i64 width.
# parseLong wraps through promote.wrapManaged so a value beyond i48 is
# exact (BigInt) rather than a lossy Float — see the D-165 note below.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- parseLong (i64 width, optional radix) ---
check '(Long/parseLong "9999999999")' '9999999999' long_parseLong_big_i48safe
check '(Long/parseLong "ff" 16)'      '255'        long_parseLong_radix16
check '(Long/parseLong "-10")'        '-10'        long_parseLong_negative

# --- toBinaryString / toHexString / toOctalString (64-bit width) ---
check '(Long/toBinaryString 10)'      '"1010"'     long_toBinaryString
check '(Long/toHexString 255)'        '"ff"'       long_toHexString
check '(Long/toOctalString 8)'        '"10"'       long_toOctalString

# --- valueOf ---
check '(Long/valueOf "42")'           '42'         long_valueOf_string
check '(Long/valueOf 7)'              '7'          long_valueOf_int

# --- NumberFormatException via ADR-0060 bridge ---
check '(try (Long/parseLong "x") (catch NumberFormatException e :caught))'   ':caught' long_parseLong_nfe
check '(try (Long/parseLong "1_000") (catch NumberFormatException e :caught))' ':caught' long_parseLong_underscore_nfe

# --- D-165 CLOSED (clj-parity campaign C7): a value in (2^47, 2^63] is a
#     heap-boxed Long (origin .long) that prints WITHOUT the N suffix and
#     reports (class …) → Long, matching JVM's primitive long. ---
check '(Long/parseLong "999999999999999")' '999999999999999' long_parseLong_i48_overflow_long

# --- bit-twiddling statics (i64 width). Counts (bitCount/nlz/ntz) are
#     small Longs; highestOneBit/reverse route through promote.wrapI64 so
#     a result beyond i48 stays exact as a heap Long (D-165 C7) — value and
#     print form both match JVM's primitive long. clj-grounded. ---
check '(Long/bitCount 7)'                 '3'   long_bitCount
check '(Long/bitCount -1)'                '64'  long_bitCount_neg
check '(Long/numberOfLeadingZeros 1)'     '63'  long_nlz
check '(Long/numberOfLeadingZeros 0)'     '64'  long_nlz_zero
check '(Long/numberOfTrailingZeros 8)'    '3'   long_ntz
check '(Long/highestOneBit 100)'          '64'  long_highestOneBit
check '(Long/highestOneBit 0)'            '0'   long_highestOneBit_zero
check '(Long/reverse -1)'                 '-1'  long_reverse_allones
check '(Long/reverse 0)'                  '0'   long_reverse_zero
# i48-overflow results are heap Longs, no N (D-165 C7, clj-parity):
check '(Long/highestOneBit -1)'  '-9223372036854775808' long_highestOneBit_neg_long
check '(Long/reverse 1)'         '-9223372036854775808' long_reverse_one_long
# D-173: lowestOneBit / reverseBytes / signum / rotateLeft / rotateRight
check '(Long/lowestOneBit 12)'   '4'  long_lowestOneBit
check '(Long/signum -5)'         '-1' long_signum_neg
check '(Long/signum 0)'          '0'  long_signum_zero
check '(Long/rotateLeft 1 4)'    '16' long_rotateLeft
check '(Long/rotateRight 16 4)'  '1'  long_rotateRight
check '(Long/reverseBytes 1)'    '72057594037927936' long_reverseBytes_long

# --- toString (signed; optional radix 2-36, out-of-range → 10) ---
check '(Long/toString 255)'      '"255"'      long_toString_dec
check '(Long/toString 255 16)'   '"ff"'       long_toString_radix16
check '(Long/toString -255 16)'  '"-ff"'      long_toString_neg
check '(Long/toString 255 2)'    '"11111111"' long_toString_bin

echo "ALL PASS phase14_long_statics"
