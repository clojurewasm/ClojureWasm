#!/usr/bin/env bash
# test/e2e/phase14_char_print.sh — D-154 char printing fidelity (JVM-faithful).
# A char value's readable (-e echo / pr) form: \A for printable ASCII, named
# forms for whitespace, \uXXXX otherwise. The raw str/print form: bare char.
# (We echo the CHAR value directly for the readable form — pr-str would
# re-escape the backslash inside the returned string.)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'rd_ascii'    "$("$BIN" -e '(char 65)')"   '\A'
assert_eq 'rd_digit'    "$("$BIN" -e '(char 57)')"   '\9'
assert_eq 'rd_space'    "$("$BIN" -e '(char 32)')"   '\space'
assert_eq 'rd_newline'  "$("$BIN" -e '(char 10)')"   '\newline'
assert_eq 'rd_tab'      "$("$BIN" -e '(char 9)')"    '\tab'
assert_eq 'rd_nonascii' "$("$BIN" -e '(char 233)')"  '\u00e9'
assert_eq 'raw_ascii'   "$("$BIN" -e '(str (char 65))')"             '"A"'
assert_eq 'raw_concat'  "$("$BIN" -e '(str (char 104) (char 105))')" '"hi"'
assert_eq 'raw_mixed'   "$("$BIN" -e '(str "x=" (char 65) "!")')"     '"x=A!"'

echo "OK — phase14_char_print smoke (9 cases) green"
