;; test/e2e/phase14_float_statics.sh
;;
;; java.lang.Float static surface (runtime/java/lang/Float.zig), the sibling
;; compat_tiers.yaml has carried as Tier A "no surface" since phase 14.
;;
;; Values are f64 throughout: cljw has no f32 representation, so `Float/*`
;; arithmetic and parsing operate on the single-double tower exactly as
;; `clojure.core/float` does (AD-004). The CONSTANTS are still Java's real
;; float constants, and the bit conversions narrow to f32 because their
;; signature is defined on the 32-bit pattern.

;; Migrated from test/e2e/phase14_float_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.float-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest float-statics-cases
  (is (= "3.14" (pr-str (Float/parseFloat "3.14"))) "float_parseFloat_basic")
  (is (= "3.14" (pr-str (Float/parseFloat " 3.14 "))) "float_parseFloat_trim")
  (is (= "-0.5" (pr-str (Float/parseFloat "-0.5"))) "float_parseFloat_negative")
  (is (= "##Inf" (pr-str (Float/parseFloat "Infinity"))) "float_parseFloat_inf")
  (is (= "##-Inf" (pr-str (Float/parseFloat "-Infinity"))) "float_parseFloat_neg_inf")
  (is (= "##NaN" (pr-str (Float/parseFloat "NaN"))) "float_parseFloat_nan")
  (is (= ":caught" (pr-str (try (Float/parseFloat "x") (catch NumberFormatException e :caught)))) "float_parseFloat_nfe")
  (is (= ":caught" (pr-str (try (Float/parseFloat "1_0.5") (catch NumberFormatException e :caught)))) "float_parseFloat_underscore_nfe")
  (is (= "true" (pr-str (Float/isNaN (/ 0.0 0.0)))) "float_isNaN_true")
  (is (= "false" (pr-str (Float/isNaN 1.0))) "float_isNaN_false")
  (is (= "true" (pr-str (Float/isInfinite (/ 1.0 0.0)))) "float_isInfinite_true")
  (is (= "false" (pr-str (Float/isInfinite 1.0))) "float_isInfinite_false")
  (is (= "true" (pr-str (Float/isFinite 1.0))) "float_isFinite_true")
  (is (= "false" (pr-str (Float/isFinite (/ 1.0 0.0)))) "float_isFinite_false")
  (is (= "2.5" (pr-str (Float/valueOf "2.5"))) "float_valueOf_string")
  (is (= "2.5" (pr-str (Float/valueOf 2.5))) "float_valueOf_number")
  (is (= "\"1.5\"" (pr-str (Float/toString 1.5))) "float_toString")
  (is (= "-1" (pr-str (Float/compare 1.0 2.0))) "float_compare_lt")
  (is (= "1" (pr-str (Float/compare 2.0 1.0))) "float_compare_gt")
  (is (= "0" (pr-str (Float/compare 1.0 1.0))) "float_compare_eq")
  (is (= "-1" (pr-str (Float/compare -0.0 0.0))) "float_compare_neg_zero")
  (is (= "2.0" (pr-str (Float/max 1.0 2.0))) "float_max")
  (is (= "1.0" (pr-str (Float/min 1.0 2.0))) "float_min")
  (is (= "3.0" (pr-str (Float/sum 1.0 2.0))) "float_sum")
  (is (= "32" (pr-str Float/SIZE)) "float_SIZE")
  (is (= "4" (pr-str Float/BYTES)) "float_BYTES")
  (is (= "127" (pr-str Float/MAX_EXPONENT)) "float_MAX_EXPONENT")
  (is (= "-126" (pr-str Float/MIN_EXPONENT)) "float_MIN_EXPONENT")
  (is (= "true" (pr-str (Float/isNaN Float/NaN))) "float_NaN_field")
  (is (= "true" (pr-str (Float/isInfinite Float/POSITIVE_INFINITY))) "float_POSITIVE_INFINITY")
  (is (= "false" (pr-str (< 0.0 Float/NEGATIVE_INFINITY))) "float_NEGATIVE_INFINITY")
  (is (= "true" (pr-str (< 3.4e38 Float/MAX_VALUE 3.5e38))) "float_MAX_VALUE")
  (is (= "true" (pr-str (< 0.0 Float/MIN_VALUE 1.5e-45))) "float_MIN_VALUE")
  (is (= "true" (pr-str (< 1.17e-38 Float/MIN_NORMAL 1.18e-38))) "float_MIN_NORMAL")
  (is (= "1065353216" (pr-str (Float/floatToIntBits 1.0))) "float_floatToIntBits")
  (is (= "1.0" (pr-str (Float/intBitsToFloat 1065353216))) "float_intBitsToFloat")
  (is (= "1065353216" (pr-str (Float/floatToRawIntBits 1.0))) "float_floatToRawIntBits")
  (is (= "1065353216" (pr-str (Float/hashCode 1.0))) "float_hashCode")
  (is (= "42.0" (pr-str (Float/parseFloat (str 42)))) "float_parseFloat_from_str"))
