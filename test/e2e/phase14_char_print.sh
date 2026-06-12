#!/usr/bin/env bash
# test/e2e/phase14_char_print.sh — char printing fidelity (clj-faithful, D-154/D-208).
# A char value's readable (-e echo / pr) form: named forms for the 6 standard
# whitespace chars, else `\` + the literal char. clj emits NO \uXXXX (verified
# vs clj: (char 7) prints `\`+BEL, (char 233) prints `\`+e-acute, (char 12354)
# prints `\`+the CJK char). D-208 corrects D-154's mistaken \uXXXX belief.
# The raw str/print form emits the bare char. Expected non-ASCII values are
# built with printf so this script stays pure-ASCII (the tool channel
# transcodes literal non-ASCII bytes).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'rd_ascii'    "$("$BIN" -e '(char 65)')"   '\A'
assert_eq 'rd_digit'    "$("$BIN" -e '(char 57)')"   '\9'
assert_eq 'rd_space'    "$("$BIN" -e '(char 32)')"   '\space'
assert_eq 'rd_newline'  "$("$BIN" -e '(char 10)')"   '\newline'
assert_eq 'rd_tab'      "$("$BIN" -e '(char 9)')"    '\tab'
# U+00E9 = C3 A9, U+3042 = E3 81 82; BEL = 07. Each expected = `\` + the char.
assert_eq 'rd_nonascii' "$("$BIN" -e '(char 233)')"   "$(printf '\\\xc3\xa9')"
assert_eq 'rd_cjk'      "$("$BIN" -e '(char 12354)')" "$(printf '\\\xe3\x81\x82')"
assert_eq 'rd_control'  "$("$BIN" -e '(char 7)')"     "$(printf '\\\a')"
assert_eq 'raw_ascii'   "$("$BIN" -e '(str (char 65))')"             '"A"'
assert_eq 'raw_concat'  "$("$BIN" -e '(str (char 104) (char 105))')" '"hi"'
assert_eq 'raw_mixed'   "$("$BIN" -e '(str "x=" (char 65) "!")')"     '"x=A!"'

echo "OK — phase14_char_print smoke (11 cases) green"
