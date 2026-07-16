#!/usr/bin/env bash
# test/e2e/phase14_character_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Character static methods + fields + char instance methods.
# Surface runtime/java/lang/Character.zig wraps single-codepoint helpers
# in the neutral runtime/charset.zig leaf, which evaluates the JVM
# classification formulas over the generated UCD 16.0.0 tables
# (unicode_case.zig / unicode_category.zig) — full Unicode. The JVM
# char/int overload pairs take a char OR an int codepoint; the case
# folds echo the arg type back. Character/getName is the one member not
# carried (explicit unsupported; D-561).
#
# Char inputs are built with (char N) rather than \x literals: a `\x`
# literal passed through `cljw -e` has its backslash eaten by the shell
# (memory char-literal-e2e-oracle). N is the codepoint.

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

# --- digit (102='f' 122='z' 55='7'; 1637='٥' 65345='ａ' fullwidth) ---
check '(Character/digit (char 102) 16)'     '15'    character_digit_hex_f
check '(Character/digit (char 122) 16)'     '-1'    character_digit_z_radix16
check '(Character/digit (char 55) 10)'      '7'     character_digit_dec_7
check '(Character/digit (char 1637) 10)'    '5'     character_digit_arabic_indic
check '(Character/digit (char 65345) 16)'   '10'    character_digit_fullwidth_a

# --- full-Unicode classification (233='é' 12354='あ' 8544='Ⅰ' 170='ª') ---
check '(Character/isLetter (char 233))'     'true'  character_isLetter_e_acute
check '(Character/isLetter (char 12354))'   'true'  character_isLetter_hiragana
check '(Character/isLetter (char 8544))'    'false' character_isLetter_roman_numeral_Nl
check '(Character/isDigit (char 1637))'     'true'  character_isDigit_arabic_indic
check '(Character/isUpperCase (char 8544))' 'true'  character_isUpperCase_other_uppercase
check '(Character/isLowerCase (char 170))'  'true'  character_isLowerCase_other_lowercase
check '(Character/isAlphabetic (char 8544))' 'true' character_isAlphabetic_letter_number
check '(Character/isWhitespace (char 28))'  'true'  character_isWhitespace_file_separator
check '(Character/isWhitespace (char 160))' 'false' character_isWhitespace_nbsp
check '(Character/isSpaceChar (char 160))'  'true'  character_isSpaceChar_nbsp
check '(Character/isTitleCase (char 453))'  'true'  character_isTitleCase_digraph
check '(Character/isDefined (char 888))'    'false' character_isDefined_unassigned
check '(Character/isMirrored (char 40))'    'true'  character_isMirrored_paren
check '(Character/isIdeographic (int 19968))' 'true' character_isIdeographic_cjk
check '(Character/isIdeographic (int 12354))' 'false' character_isIdeographic_hiragana

# --- int-codepoint overloads (arg-type echo on case folds) ---
check '(Character/isDigit 53)'              'true'  character_isDigit_int_overload
check '(Character/toUpperCase 97)'          '65'    character_toUpperCase_int_echo
check '(Character/toUpperCase (char 97))'   '\A'    character_toUpperCase_char_echo
check '(Character/toTitleCase (char 454))'  '\ǅ'    character_toTitleCase_digraph
check '(Character/isLetter (int 1114112))'  'false' character_isLetter_out_of_range_int
check '(Character/toUpperCase (int 1114112))' '1114112' character_toUpperCase_out_of_range_echo
check '(Character/getType (int 1114112))'   '0'     character_getType_out_of_range

# --- identifier predicates ---
check '(Character/isJavaIdentifierStart (char 36))'  'true'  character_isJavaIdentifierStart_dollar
check '(Character/isJavaIdentifierStart (char 49))'  'false' character_isJavaIdentifierStart_digit
check '(Character/isJavaIdentifierPart (char 49))'   'true'  character_isJavaIdentifierPart_digit
check '(Character/isUnicodeIdentifierStart (char 95))' 'false' character_isUnicodeIdentifierStart_underscore
check '(Character/isUnicodeIdentifierPart (char 95))'  'true' character_isUnicodeIdentifierPart_underscore
check '(Character/isIdentifierIgnorable (char 173))' 'true'  character_isIdentifierIgnorable_soft_hyphen
check '(Character/isIdentifierIgnorable (char 9))'   'false' character_isIdentifierIgnorable_tab

# --- getType / getDirectionality / getNumericValue ---
check '(Character/getType (char 97))'       '2'     character_getType_lowercase
check '(Character/getType (char 32))'       '12'    character_getType_space
check '(Character/getType (char 95))'       '23'    character_getType_underscore
check '(Character/getDirectionality (char 97))'   '0'  character_getDirectionality_ltr
check '(Character/getDirectionality (char 1488))' '1'  character_getDirectionality_rtl
check '(Character/getDirectionality (char 888))'  '-1' character_getDirectionality_undefined
check '(Character/getNumericValue (char 8550))' '7'  character_getNumericValue_roman_vii
check '(Character/getNumericValue (char 189))'  '-2' character_getNumericValue_half
check '(Character/getNumericValue (char 33))'   '-1' character_getNumericValue_none

# --- compare / valueOf / isSpace / reverseBytes / hashCode ---
check '(Character/compare (char 97) (char 98))'  '-1' character_compare_lt
check '(Character/compare (char 98) (char 97))'  '1'  character_compare_gt
check '(Character/valueOf (char 97))'       '\a'    character_valueOf_identity
check '(Character/isSpace (char 32))'       'true'  character_isSpace_space
check '(Character/isSpace (char 11))'       'false' character_isSpace_vt_excluded
check '(Character/reverseBytes (char 97))'  '\愀'   character_reverseBytes
check '(Character/hashCode (char 97))'      '97'    character_hashCode_static

# --- codePointBefore / codePointCount / offsetByCodePoints ---
check '(Character/codePointBefore "abc" 2)' '98'    character_codePointBefore
check '(Character/codePointCount "abc" 0 3)' '3'    character_codePointCount
check '(Character/offsetByCodePoints "abc" 0 2)' '2' character_offsetByCodePoints

# --- static fields ---
check 'Character/MIN_RADIX'                 '2'     character_field_min_radix
check 'Character/MAX_RADIX'                 '36'    character_field_max_radix
check 'Character/SIZE'                      '16'    character_field_size
check 'Character/BYTES'                     '2'     character_field_bytes
check 'Character/MAX_CODE_POINT'            '1114111' character_field_max_code_point
check 'Character/MIN_SUPPLEMENTARY_CODE_POINT' '65536' character_field_min_supplementary
check '(int Character/MAX_VALUE)'           '65535' character_field_max_value_char
check 'Character/UPPERCASE_LETTER'          '1'     character_field_uppercase_letter
check 'Character/DECIMAL_DIGIT_NUMBER'      '9'     character_field_decimal_digit_number
check 'Character/FINAL_QUOTE_PUNCTUATION'   '30'    character_field_final_quote
check 'Character/DIRECTIONALITY_UNDEFINED'  '-1'    character_field_directionality_undefined
check 'Character/DIRECTIONALITY_RIGHT_TO_LEFT' '1'  character_field_directionality_rtl

# --- char instance methods + hash parity ---
check '(.charValue (char 97))'              '\a'    character_instance_charValue
check '(.compareTo (char 98) (char 97))'    '1'     character_instance_compareTo
check '(hash (char 97))'                    '97'    character_hash_parity
check '(.hashCode (char 97))'               '97'    character_instance_hashCode

# --- getName + codePointOf (D-561: the UCD name table, landed) ---
check '(Character/getName 97)'  '"LATIN SMALL LETTER A"'  character_getName
check '(Character/codePointOf "LATIN SMALL LETTER A")'  '97'  character_codePointOf

echo "ALL PASS phase14_character_statics"
