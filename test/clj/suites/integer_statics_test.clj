;; test/e2e/phase14_integer_statics.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Integer static methods. Surface file
;; runtime/java/lang/Integer.zig (___HOST_EXTENSION pattern, like
;; Math/System), delegating integer parsing to the neutral
;; runtime/numeric/parse.zig leaf shared with clojure.core/parse-long
;; (F-009 neutral home + F-011 DRY).
;;
;; Parse failure raises a `number_error`-Kind catalog Code, which
;; ADR-0060's kindToHostClass maps to NumberFormatException, so
;; (catch NumberFormatException …) / (catch Exception …) catch it
;; (behavioural equivalence vs real clj).
;;
;; Bonus regression: routing parse-long through the shared leaf fixes a
;; divergence where cljw accepted Zig's `_` digit separators that real
;; Clojure rejects — `(parse-long "1_000")` is nil in clj.

;; Migrated from test/e2e/phase14_integer_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.integer-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest integer-statics-cases
  (is (= "42" (pr-str (Integer/parseInt "42"))) "integer_parseInt_base10")
  (is (= "255" (pr-str (Integer/parseInt "ff" 16))) "integer_parseInt_radix16")
  (is (= "-10" (pr-str (Integer/parseInt "-10"))) "integer_parseInt_negative")
  (is (= "5" (pr-str (Integer/parseInt "+5"))) "integer_parseInt_plus")
  (is (= "\"1010\"" (pr-str (Integer/toBinaryString 10))) "integer_toBinaryString")
  (is (= "\"ff\"" (pr-str (Integer/toHexString 255))) "integer_toHexString")
  (is (= "\"10\"" (pr-str (Integer/toOctalString 8))) "integer_toOctalString")
  (is (= "42" (pr-str (Integer/valueOf "42"))) "integer_valueOf_string")
  (is (= "7" (pr-str (Integer/valueOf 7))) "integer_valueOf_int")
  (is (= ":caught" (pr-str (try (Integer/parseInt "x") (catch NumberFormatException e :caught)))) "integer_parseInt_nfe_specific")
  (is (= ":caught" (pr-str (try (Integer/parseInt "x") (catch Exception e :caught)))) "integer_parseInt_nfe_exception")
  (is (= ":caught" (pr-str (try (Integer/parseInt "9999999999") (catch NumberFormatException e :caught)))) "integer_parseInt_overflow_nfe")
  (is (= "nil" (pr-str (parse-long "1_000"))) "parse_long_underscore_rejected")
  (is (= "42" (pr-str (parse-long "42"))) "parse_long_no_regression")
  (is (= "nil" (pr-str (parse-long "abc"))) "parse_long_invalid_nil")
  (is (= "3" (pr-str (Integer/bitCount 7))) "integer_bitCount")
  (is (= "32" (pr-str (Integer/bitCount -1))) "integer_bitCount_neg")
  (is (= "0" (pr-str (Integer/bitCount 0))) "integer_bitCount_zero")
  (is (= "31" (pr-str (Integer/numberOfLeadingZeros 1))) "integer_nlz")
  (is (= "32" (pr-str (Integer/numberOfLeadingZeros 0))) "integer_nlz_zero")
  (is (= "3" (pr-str (Integer/numberOfTrailingZeros 8))) "integer_ntz")
  (is (= "32" (pr-str (Integer/numberOfTrailingZeros 0))) "integer_ntz_zero")
  (is (= "64" (pr-str (Integer/highestOneBit 100))) "integer_highestOneBit")
  (is (= "-2147483648" (pr-str (Integer/highestOneBit -1))) "integer_highestOneBit_neg")
  (is (= "0" (pr-str (Integer/highestOneBit 0))) "integer_highestOneBit_zero")
  (is (= "-2147483648" (pr-str (Integer/reverse 1))) "integer_reverse_one")
  (is (= "1073741824" (pr-str (Integer/reverse 2))) "integer_reverse_two")
  (is (= "-1" (pr-str (Integer/reverse -1))) "integer_reverse_allones")
  (is (= "4" (pr-str (Integer/lowestOneBit 12))) "integer_lowestOneBit")
  (is (= "16777216" (pr-str (Integer/reverseBytes 1))) "integer_reverseBytes")
  (is (= "-1" (pr-str (Integer/signum -5))) "integer_signum_neg")
  (is (= "0" (pr-str (Integer/signum 0))) "integer_signum_zero")
  (is (= "16" (pr-str (Integer/rotateLeft 1 4))) "integer_rotateLeft")
  (is (= "1" (pr-str (Integer/rotateRight 16 4))) "integer_rotateRight")
  (is (= "\"255\"" (pr-str (Integer/toString 255))) "integer_toString_dec")
  (is (= "\"ff\"" (pr-str (Integer/toString 255 16))) "integer_toString_radix16")
  (is (= "\"-ff\"" (pr-str (Integer/toString -255 16))) "integer_toString_neg"))
