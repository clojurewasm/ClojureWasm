;; test/e2e/phase14_double_statics.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Double static methods. Surface runtime/java/lang/Double.zig,
;; delegating parsing to the shared runtime/numeric/parse.zig leaf
;; (parseFloat: rejects `_`, trims surrounding whitespace like Java
;; Double.parseDouble). isNaN / isInfinite wrap std.math.
;;
;; Bonus regression: routing clojure.core/parse-double through the same
;; leaf fixes a divergence where cljw did not trim — `(parse-double
;; " 3.14 ")` is 3.14 in real clj but was nil in cljw.

;; Migrated from test/e2e/phase14_double_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.double-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest double-statics-cases
  (is (= "3.14" (pr-str (Double/parseDouble "3.14"))) "double_parseDouble_basic")
  (is (= "3.14" (pr-str (Double/parseDouble " 3.14 "))) "double_parseDouble_trim")
  (is (= "##Inf" (pr-str (Double/parseDouble "Infinity"))) "double_parseDouble_inf")
  (is (= "##-Inf" (pr-str (Double/parseDouble "-Infinity"))) "double_parseDouble_neg_inf")
  (is (= "##NaN" (pr-str (Double/parseDouble "NaN"))) "double_parseDouble_nan")
  (is (= "true" (pr-str (Double/isNaN (/ 0.0 0.0)))) "double_isNaN_true")
  (is (= "false" (pr-str (Double/isNaN 1.0))) "double_isNaN_false")
  (is (= "true" (pr-str (Double/isInfinite (/ 1.0 0.0)))) "double_isInfinite_true")
  (is (= "false" (pr-str (Double/isInfinite 1.0))) "double_isInfinite_false")
  (is (= ":caught" (pr-str (try (Double/parseDouble "x") (catch NumberFormatException e :caught)))) "double_parseDouble_nfe")
  (is (= ":caught" (pr-str (try (Double/parseDouble "1_0.5") (catch NumberFormatException e :caught)))) "double_parseDouble_underscore_nfe")
  (is (= "3.14" (pr-str (parse-double " 3.14 "))) "parse_double_trim_fixed")
  (is (= "3.14" (pr-str (parse-double "3.14"))) "parse_double_no_regression")
  (is (= "nil" (pr-str (parse-double "x"))) "parse_double_invalid_nil"))
