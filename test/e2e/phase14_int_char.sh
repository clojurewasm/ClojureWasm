#!/usr/bin/env bash
# test/e2e/phase14_int_char.sh — D-134 int/char coercion primitives.
# int: float truncates toward zero, char -> codepoint, integer passthrough.
# char: codepoint -> char (0..0x10FFFF). Tested via codepoint round-trips
# to avoid shell-escaping char literals (\A). NOTE: chars now print JVM-faithful (D-154 fixed); raw str gives the bare char,
# \uXXXX (pre-existing printer; JVM uses readable \A — tracked as D-154),
# so char results are checked by round-tripping back to int.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'int_trunc_pos' "$("$BIN" -e '(int 3.7)')"               '3'
assert_eq 'int_trunc_neg' "$("$BIN" -e '(int -3.7)')"              '-3'
assert_eq 'int_ident'     "$("$BIN" -e '(int 5)')"                 '5'
assert_eq 'int_of_char'   "$("$BIN" -e '(int (char 66))')"         '66'
assert_eq 'char_rt_low'   "$("$BIN" -e '(int (char 65))')"         '65'
assert_eq 'char_rt_high'  "$("$BIN" -e '(int (char 200))')"        '200'
assert_eq 'char_idem'     "$("$BIN" -e '(int (char (char 90)))')"  '90'
assert_eq 'char_eq'       "$("$BIN" -e '(= (char 65) (char 65))')" 'true'
# guarded errors (no ReleaseSafe panic on out-of-range float / codepoint)
out="$("$BIN" -e '(int "x")' 2>&1 || true)";        [[ "$out" == *"expected number"* ]] || fail "int_str: $out";  echo "PASS int_str -> err"
out="$("$BIN" -e '(char 9999999999)' 2>&1 || true)"; [[ "$out" == *"codepoint"* ]] || fail "char_oob: $out"; echo "PASS char_oob -> err"
# string seq/first yield CHARACTERS, not 1-char strings (JVM parity, clj-verified)
assert_eq 'str_first_char' "$("$BIN" -e '(char? (first "abc"))')"          'true'
assert_eq 'str_seq_int'    "$("$BIN" -e '(into [] (map int "abc"))')"      '[97 98 99]'
assert_eq 'str_freq_char'  "$("$BIN" -e '(get (frequencies "aab") (char 97))')" '2'

echo "OK — phase14_int_char smoke (13 cases) green"
