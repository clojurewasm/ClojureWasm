;; test/e2e/phase14_long_statics.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Long static methods. Surface runtime/java/lang/Long.zig,
;; delegating parsing to the shared runtime/numeric/parse.zig leaf
;; (F-011 DRY with parse-long / Integer/parseInt) but at i64 width.
;; parseLong wraps through promote.wrapManaged so a value beyond i48 is
;; exact (BigInt) rather than a lossy Float — see the D-165 note below.

;; Migrated from test/e2e/phase14_long_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.long-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest long-statics-cases
  (is (= "9999999999" (pr-str (Long/parseLong "9999999999"))) "long_parseLong_big_i48safe")
  (is (= "255" (pr-str (Long/parseLong "ff" 16))) "long_parseLong_radix16")
  (is (= "-10" (pr-str (Long/parseLong "-10"))) "long_parseLong_negative")
  (is (= "\"1010\"" (pr-str (Long/toBinaryString 10))) "long_toBinaryString")
  (is (= "\"ff\"" (pr-str (Long/toHexString 255))) "long_toHexString")
  (is (= "\"10\"" (pr-str (Long/toOctalString 8))) "long_toOctalString")
  (is (= "42" (pr-str (Long/valueOf "42"))) "long_valueOf_string")
  (is (= "7" (pr-str (Long/valueOf 7))) "long_valueOf_int")
  (is (= ":caught" (pr-str (try (Long/parseLong "x") (catch NumberFormatException e :caught)))) "long_parseLong_nfe")
  (is (= ":caught" (pr-str (try (Long/parseLong "1_000") (catch NumberFormatException e :caught)))) "long_parseLong_underscore_nfe")
  (is (= "999999999999999" (pr-str (Long/parseLong "999999999999999"))) "long_parseLong_i48_overflow_long")
  (is (= "3" (pr-str (Long/bitCount 7))) "long_bitCount")
  (is (= "64" (pr-str (Long/bitCount -1))) "long_bitCount_neg")
  (is (= "63" (pr-str (Long/numberOfLeadingZeros 1))) "long_nlz")
  (is (= "64" (pr-str (Long/numberOfLeadingZeros 0))) "long_nlz_zero")
  (is (= "3" (pr-str (Long/numberOfTrailingZeros 8))) "long_ntz")
  (is (= "64" (pr-str (Long/highestOneBit 100))) "long_highestOneBit")
  (is (= "0" (pr-str (Long/highestOneBit 0))) "long_highestOneBit_zero")
  (is (= "-1" (pr-str (Long/reverse -1))) "long_reverse_allones")
  (is (= "0" (pr-str (Long/reverse 0))) "long_reverse_zero")
  (is (= "-9223372036854775808" (pr-str (Long/highestOneBit -1))) "long_highestOneBit_neg_long")
  (is (= "-9223372036854775808" (pr-str (Long/reverse 1))) "long_reverse_one_long")
  (is (= "4" (pr-str (Long/lowestOneBit 12))) "long_lowestOneBit")
  (is (= "-1" (pr-str (Long/signum -5))) "long_signum_neg")
  (is (= "0" (pr-str (Long/signum 0))) "long_signum_zero")
  (is (= "16" (pr-str (Long/rotateLeft 1 4))) "long_rotateLeft")
  (is (= "1" (pr-str (Long/rotateRight 16 4))) "long_rotateRight")
  (is (= "72057594037927936" (pr-str (Long/reverseBytes 1))) "long_reverseBytes_long")
  (is (= "\"255\"" (pr-str (Long/toString 255))) "long_toString_dec")
  (is (= "\"ff\"" (pr-str (Long/toString 255 16))) "long_toString_radix16")
  (is (= "\"-ff\"" (pr-str (Long/toString -255 16))) "long_toString_neg")
  (is (= "\"11111111\"" (pr-str (Long/toString 255 2))) "long_toString_bin"))
