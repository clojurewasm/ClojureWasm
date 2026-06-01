#!/usr/bin/env bash
# test/e2e/phase14_integer_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Integer static methods. Surface file
# runtime/java/lang/Integer.zig (___HOST_EXTENSION pattern, like
# Math/System), delegating integer parsing to the neutral
# runtime/numeric/parse.zig leaf shared with clojure.core/parse-long
# (F-009 neutral home + F-011 DRY).
#
# Parse failure raises a `number_error`-Kind catalog Code, which
# ADR-0060's kindToHostClass maps to NumberFormatException, so
# (catch NumberFormatException …) / (catch Exception …) catch it
# (behavioural equivalence vs real clj).
#
# Bonus regression: routing parse-long through the shared leaf fixes a
# divergence where cljw accepted Zig's `_` digit separators that real
# Clojure rejects — `(parse-long "1_000")` is nil in clj.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    # cljw may exit non-zero on an error path; capture without letting
    # `set -e` abort the assignment so the comparison reports the real diff.
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- parseInt ---
check '(Integer/parseInt "42")'      '42'    integer_parseInt_base10
check '(Integer/parseInt "ff" 16)'   '255'   integer_parseInt_radix16
check '(Integer/parseInt "-10")'     '-10'   integer_parseInt_negative
check '(Integer/parseInt "+5")'      '5'     integer_parseInt_plus

# --- toBinaryString / toHexString / toOctalString (always strings) ---
check '(Integer/toBinaryString 10)'  '"1010"' integer_toBinaryString
check '(Integer/toHexString 255)'    '"ff"'   integer_toHexString
check '(Integer/toOctalString 8)'    '"10"'   integer_toOctalString

# --- valueOf (string parses; number is identity) ---
check '(Integer/valueOf "42")'       '42'    integer_valueOf_string
check '(Integer/valueOf 7)'          '7'     integer_valueOf_int

# --- NumberFormatException via ADR-0060 bridge (number_error Kind) ---
check '(try (Integer/parseInt "x") (catch NumberFormatException e :caught))' ':caught' integer_parseInt_nfe_specific
check '(try (Integer/parseInt "x") (catch Exception e :caught))'             ':caught' integer_parseInt_nfe_exception
# out-of-int-range throws too (matches clj: int is 32-bit)
check '(try (Integer/parseInt "9999999999") (catch NumberFormatException e :caught))' ':caught' integer_parseInt_overflow_nfe

# --- F-011 commonisation regression: parse-long now rejects `_` (clj parity) ---
check '(parse-long "1_000")'         'nil'   parse_long_underscore_rejected
check '(parse-long "42")'            '42'    parse_long_no_regression
check '(parse-long "abc")'           'nil'   parse_long_invalid_nil

# --- bit-twiddling statics (i32 width; @popCount/@clz/@ctz/@bitReverse).
#     Every result fits i48 (counts are 0-32; highestOneBit/reverse
#     sign-extend an i32), so each returns a plain Long. clj-grounded. ---
check '(Integer/bitCount 7)'                  '3'           integer_bitCount
check '(Integer/bitCount -1)'                 '32'          integer_bitCount_neg
check '(Integer/bitCount 0)'                  '0'           integer_bitCount_zero
check '(Integer/numberOfLeadingZeros 1)'      '31'          integer_nlz
check '(Integer/numberOfLeadingZeros 0)'      '32'          integer_nlz_zero
check '(Integer/numberOfTrailingZeros 8)'     '3'           integer_ntz
check '(Integer/numberOfTrailingZeros 0)'     '32'          integer_ntz_zero
check '(Integer/highestOneBit 100)'           '64'          integer_highestOneBit
check '(Integer/highestOneBit -1)'            '-2147483648' integer_highestOneBit_neg
check '(Integer/highestOneBit 0)'             '0'           integer_highestOneBit_zero
check '(Integer/reverse 1)'                   '-2147483648' integer_reverse_one
check '(Integer/reverse 2)'                   '1073741824'  integer_reverse_two
check '(Integer/reverse -1)'                  '-1'          integer_reverse_allones
# D-173: lowestOneBit / reverseBytes / signum / rotateLeft / rotateRight
check '(Integer/lowestOneBit 12)'             '4'           integer_lowestOneBit
check '(Integer/reverseBytes 1)'              '16777216'    integer_reverseBytes
check '(Integer/signum -5)'                   '-1'          integer_signum_neg
check '(Integer/signum 0)'                    '0'           integer_signum_zero
check '(Integer/rotateLeft 1 4)'              '16'          integer_rotateLeft
check '(Integer/rotateRight 16 4)'            '1'           integer_rotateRight
# --- toString (signed; optional radix 2-36, out-of-range → 10) ---
check '(Integer/toString 255)'                '"255"'       integer_toString_dec
check '(Integer/toString 255 16)'             '"ff"'        integer_toString_radix16
check '(Integer/toString -255 16)'            '"-ff"'       integer_toString_neg

echo "ALL PASS phase14_integer_statics"
