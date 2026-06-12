#!/usr/bin/env bash
# test/e2e/phase14_character_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Character static methods. Surface
# runtime/java/lang/Character.zig wraps single-codepoint helpers in the
# neutral runtime/charset.zig leaf (isDigit/isLetter/isWhitespace/
# toUpper/toLower/digitValue — ASCII-only, D-057 Unicode caveat).
#
# Char inputs are built with (char N) rather than \x literals: a `\x`
# literal passed through `cljw -e` has its backslash eaten by the shell
# (memory char-literal-e2e-oracle). N is the ASCII codepoint.

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

# --- isDigit / isLetter / isWhitespace (53='5' 120='x' 97='a' 32=space) ---
check '(Character/isDigit (char 53))'       'true'  character_isDigit_true
check '(Character/isDigit (char 120))'      'false' character_isDigit_false
check '(Character/isLetter (char 97))'      'true'  character_isLetter_true
check '(Character/isLetter (char 53))'      'false' character_isLetter_false
check '(Character/isWhitespace (char 32))'  'true'  character_isWhitespace_true
check '(Character/isWhitespace (char 97))'  'false' character_isWhitespace_false

# --- toUpperCase / toLowerCase (return a char; non-letter unchanged) ---
check '(Character/toUpperCase (char 97))'   '\A'    character_toUpperCase_letter
check '(Character/toUpperCase (char 53))'   '\5'    character_toUpperCase_nonletter
check '(Character/toLowerCase (char 65))'   '\a'    character_toLowerCase_letter

# --- digit (102='f' 122='z' 55='7') ---
check '(Character/digit (char 102) 16)'     '15'    character_digit_hex_f
check '(Character/digit (char 122) 16)'     '-1'    character_digit_z_radix16
check '(Character/digit (char 55) 10)'      '7'     character_digit_dec_7

echo "ALL PASS phase14_character_statics"
