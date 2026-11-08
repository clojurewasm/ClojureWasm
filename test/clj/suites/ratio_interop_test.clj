;; test/e2e/phase14_ratio_interop.sh — D-420.
;; clojure.lang.Ratio instance interop: `(.numerator r)` / `(.denominator r)`
;; reached via the dot form. clojure.math.numeric-tower's MathFunctions extends
;; Ratio and computes floor/ceil/sqrt with `(. n numerator)`/`(. n denominator)`.
;; The values mirror cljw's core `(numerator r)`/`(denominator r)` (Long when the
;; component fits i48 — cljw's F-005 narrow-when-fits; clj keeps BigInteger, an
;; accepted representation divergence, the VALUE is `=`).

;; Migrated from test/e2e/phase14_ratio_interop.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.ratio-interop-test
  (:require [clojure.test :refer [deftest is]]))

(deftest ratio-interop-cases
  (is (= "5" (pr-str (.numerator 5/2))) "dot_numerator")
  (is (= "2" (pr-str (.denominator 5/2))) "dot_denominator")
  (is (= "22" (pr-str (. 22/7 numerator))) "dotform_numer")
  (is (= "7" (pr-str (. 22/7 denominator))) "dotform_denom")
  (is (= "[true true]" (pr-str [(= (.numerator 9/4) (numerator 9/4)) (= (.denominator 9/4) (denominator 9/4))])) "matches_core")
  (is (= "[-3 4]" (pr-str [(.numerator -3/4) (.denominator -3/4)])) "neg_numerator"))
