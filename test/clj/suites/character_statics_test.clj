;; test/e2e/phase14_character_statics.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Character static methods + fields + char instance methods.
;; Surface runtime/java/lang/Character.zig wraps single-codepoint helpers
;; in the neutral runtime/charset.zig leaf, which evaluates the JVM
;; classification formulas over the generated UCD 16.0.0 tables
;; (unicode_case.zig / unicode_category.zig) — full Unicode. The JVM
;; char/int overload pairs take a char OR an int codepoint; the case
;; folds echo the arg type back. Character/getName is the one member not
;; carried (explicit unsupported; D-561).
;;
;; Char inputs are built with (char N) rather than \x literals: a `\x`
;; literal passed through `cljw -e` has its backslash eaten by the shell
;; (memory char-literal-e2e-oracle). N is the codepoint.

;; Migrated from test/e2e/phase14_character_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.character-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest character-statics-cases
  (is (= "true" (pr-str (Character/isDigit (char 53)))) "character_isDigit_true")
  (is (= "false" (pr-str (Character/isDigit (char 120)))) "character_isDigit_false")
  (is (= "true" (pr-str (Character/isLetter (char 97)))) "character_isLetter_true")
  (is (= "false" (pr-str (Character/isLetter (char 53)))) "character_isLetter_false")
  (is (= "true" (pr-str (Character/isWhitespace (char 32)))) "character_isWhitespace_true")
  (is (= "false" (pr-str (Character/isWhitespace (char 97)))) "character_isWhitespace_false")
  (is (= "\\A" (pr-str (Character/toUpperCase (char 97)))) "character_toUpperCase_letter")
  (is (= "\\5" (pr-str (Character/toUpperCase (char 53)))) "character_toUpperCase_nonletter")
  (is (= "\\a" (pr-str (Character/toLowerCase (char 65)))) "character_toLowerCase_letter")
  (is (= "15" (pr-str (Character/digit (char 102) 16))) "character_digit_hex_f")
  (is (= "-1" (pr-str (Character/digit (char 122) 16))) "character_digit_z_radix16")
  (is (= "7" (pr-str (Character/digit (char 55) 10))) "character_digit_dec_7")
  (is (= "5" (pr-str (Character/digit (char 1637) 10))) "character_digit_arabic_indic")
  (is (= "10" (pr-str (Character/digit (char 65345) 16))) "character_digit_fullwidth_a")
  (is (= "true" (pr-str (Character/isLetter (char 233)))) "character_isLetter_e_acute")
  (is (= "true" (pr-str (Character/isLetter (char 12354)))) "character_isLetter_hiragana")
  (is (= "false" (pr-str (Character/isLetter (char 8544)))) "character_isLetter_roman_numeral_Nl")
  (is (= "true" (pr-str (Character/isDigit (char 1637)))) "character_isDigit_arabic_indic")
  (is (= "true" (pr-str (Character/isUpperCase (char 8544)))) "character_isUpperCase_other_uppercase")
  (is (= "true" (pr-str (Character/isLowerCase (char 170)))) "character_isLowerCase_other_lowercase")
  (is (= "true" (pr-str (Character/isAlphabetic (char 8544)))) "character_isAlphabetic_letter_number")
  (is (= "true" (pr-str (Character/isWhitespace (char 28)))) "character_isWhitespace_file_separator")
  (is (= "false" (pr-str (Character/isWhitespace (char 160)))) "character_isWhitespace_nbsp")
  (is (= "true" (pr-str (Character/isSpaceChar (char 160)))) "character_isSpaceChar_nbsp")
  (is (= "true" (pr-str (Character/isTitleCase (char 453)))) "character_isTitleCase_digraph")
  (is (= "false" (pr-str (Character/isDefined (char 888)))) "character_isDefined_unassigned")
  (is (= "true" (pr-str (Character/isMirrored (char 40)))) "character_isMirrored_paren")
  (is (= "true" (pr-str (Character/isIdeographic (int 19968)))) "character_isIdeographic_cjk")
  (is (= "false" (pr-str (Character/isIdeographic (int 12354)))) "character_isIdeographic_hiragana")
  (is (= "true" (pr-str (Character/isDigit 53))) "character_isDigit_int_overload")
  (is (= "65" (pr-str (Character/toUpperCase 97))) "character_toUpperCase_int_echo")
  (is (= "\\A" (pr-str (Character/toUpperCase (char 97)))) "character_toUpperCase_char_echo")
  (is (= "\\ǅ" (pr-str (Character/toTitleCase (char 454)))) "character_toTitleCase_digraph")
  (is (= "false" (pr-str (Character/isLetter (int 1114112)))) "character_isLetter_out_of_range_int")
  (is (= "1114112" (pr-str (Character/toUpperCase (int 1114112)))) "character_toUpperCase_out_of_range_echo")
  (is (= "0" (pr-str (Character/getType (int 1114112)))) "character_getType_out_of_range")
  (is (= "true" (pr-str (Character/isJavaIdentifierStart (char 36)))) "character_isJavaIdentifierStart_dollar")
  (is (= "false" (pr-str (Character/isJavaIdentifierStart (char 49)))) "character_isJavaIdentifierStart_digit")
  (is (= "true" (pr-str (Character/isJavaIdentifierPart (char 49)))) "character_isJavaIdentifierPart_digit")
  (is (= "false" (pr-str (Character/isUnicodeIdentifierStart (char 95)))) "character_isUnicodeIdentifierStart_underscore")
  (is (= "true" (pr-str (Character/isUnicodeIdentifierPart (char 95)))) "character_isUnicodeIdentifierPart_underscore")
  (is (= "true" (pr-str (Character/isIdentifierIgnorable (char 173)))) "character_isIdentifierIgnorable_soft_hyphen")
  (is (= "false" (pr-str (Character/isIdentifierIgnorable (char 9)))) "character_isIdentifierIgnorable_tab")
  (is (= "2" (pr-str (Character/getType (char 97)))) "character_getType_lowercase")
  (is (= "12" (pr-str (Character/getType (char 32)))) "character_getType_space")
  (is (= "23" (pr-str (Character/getType (char 95)))) "character_getType_underscore")
  (is (= "0" (pr-str (Character/getDirectionality (char 97)))) "character_getDirectionality_ltr")
  (is (= "1" (pr-str (Character/getDirectionality (char 1488)))) "character_getDirectionality_rtl")
  (is (= "-1" (pr-str (Character/getDirectionality (char 888)))) "character_getDirectionality_undefined")
  (is (= "7" (pr-str (Character/getNumericValue (char 8550)))) "character_getNumericValue_roman_vii")
  (is (= "-2" (pr-str (Character/getNumericValue (char 189)))) "character_getNumericValue_half")
  (is (= "-1" (pr-str (Character/getNumericValue (char 33)))) "character_getNumericValue_none")
  (is (= "-1" (pr-str (Character/compare (char 97) (char 98)))) "character_compare_lt")
  (is (= "1" (pr-str (Character/compare (char 98) (char 97)))) "character_compare_gt")
  (is (= "\\a" (pr-str (Character/valueOf (char 97)))) "character_valueOf_identity")
  (is (= "true" (pr-str (Character/isSpace (char 32)))) "character_isSpace_space")
  (is (= "false" (pr-str (Character/isSpace (char 11)))) "character_isSpace_vt_excluded")
  (is (= "\\愀" (pr-str (Character/reverseBytes (char 97)))) "character_reverseBytes")
  (is (= "97" (pr-str (Character/hashCode (char 97)))) "character_hashCode_static")
  (is (= "98" (pr-str (Character/codePointBefore "abc" 2))) "character_codePointBefore")
  (is (= "3" (pr-str (Character/codePointCount "abc" 0 3))) "character_codePointCount")
  (is (= "2" (pr-str (Character/offsetByCodePoints "abc" 0 2))) "character_offsetByCodePoints")
  (is (= "2" (pr-str Character/MIN_RADIX)) "character_field_min_radix")
  (is (= "36" (pr-str Character/MAX_RADIX)) "character_field_max_radix")
  (is (= "16" (pr-str Character/SIZE)) "character_field_size")
  (is (= "2" (pr-str Character/BYTES)) "character_field_bytes")
  (is (= "1114111" (pr-str Character/MAX_CODE_POINT)) "character_field_max_code_point")
  (is (= "65536" (pr-str Character/MIN_SUPPLEMENTARY_CODE_POINT)) "character_field_min_supplementary")
  (is (= "65535" (pr-str (int Character/MAX_VALUE))) "character_field_max_value_char")
  (is (= "1" (pr-str Character/UPPERCASE_LETTER)) "character_field_uppercase_letter")
  (is (= "9" (pr-str Character/DECIMAL_DIGIT_NUMBER)) "character_field_decimal_digit_number")
  (is (= "30" (pr-str Character/FINAL_QUOTE_PUNCTUATION)) "character_field_final_quote")
  (is (= "-1" (pr-str Character/DIRECTIONALITY_UNDEFINED)) "character_field_directionality_undefined")
  (is (= "1" (pr-str Character/DIRECTIONALITY_RIGHT_TO_LEFT)) "character_field_directionality_rtl")
  (is (= "\\a" (pr-str (.charValue (char 97)))) "character_instance_charValue")
  (is (= "1" (pr-str (.compareTo (char 98) (char 97)))) "character_instance_compareTo")
  (is (= "97" (pr-str (hash (char 97)))) "character_hash_parity")
  (is (= "97" (pr-str (.hashCode (char 97)))) "character_instance_hashCode")
  (is (= "\"LATIN SMALL LETTER A\"" (pr-str (Character/getName 97))) "character_getName")
  (is (= "97" (pr-str (Character/codePointOf "LATIN SMALL LETTER A"))) "character_codePointOf"))
