;; test/e2e/phase14_math_extra.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Math static FIELDS (PI / E, via ADR-0061 static-field
;; resolution) + floorDiv / floorMod methods. Extends runtime/java/lang/
;; Math.zig.

;; Migrated from test/e2e/phase14_math_extra.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.math-extra-test
  (:require [clojure.test :refer [deftest is]]))

(deftest math-extra-cases
  (is (= "3.141592653589793" (pr-str Math/PI)) "math_pi")
  (is (= "2.718281828459045" (pr-str Math/E)) "math_e")
  (is (= "true" (pr-str (< 3 Math/PI 4))) "math_pi_in_expr")
  (is (= "3" (pr-str (Math/floorDiv 7 2))) "math_floorDiv_pos")
  (is (= "-4" (pr-str (Math/floorDiv -7 2))) "math_floorDiv_neg")
  (is (= "2" (pr-str (Math/floorMod -7 3))) "math_floorMod_neg")
  (is (= "1" (pr-str (Math/floorMod 7 3))) "math_floorMod_pos")
  (is (= "true" (pr-str (and (<= 0.0 (Math/random)) (< (Math/random) 1.0)))) "math_random_range")
  (is (= "true" (pr-str (double? (Math/random)))) "math_random_double"))
