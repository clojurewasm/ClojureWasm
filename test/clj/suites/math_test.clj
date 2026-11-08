;; test/e2e/phase14_math.sh
;;
;; §A26 interop coverage Q1 — java.lang.Math static dispatch + the
;; java.lang auto-import resolution path (ADR-0050 R3 follow-up).
;;
;; Validates:
;;   - bare (Math/abs …) resolves via the java.lang.<head> auto-import
;;     (today fails "No namespace: 'Math'")
;;   - F-005 type preservation: (Math/abs -5) → Integer 5, (Math/abs -5.0)
;;     → Float 5.0 (NOT widened); min/max likewise
;;   - sqrt/floor/ceil/pow always Float; round → Integer
;;   - bonus: bare (System/…) now also resolves via the auto-import
;;
;; Static dispatch is TreeWalk-only at v0.1.0 (the .static_method VM arm
;; is VM-DEFER, D-130); this runs on the default (tree-walk) backend.

;; Migrated from test/e2e/phase14_math.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.math-test
  (:require [clojure.test :refer [deftest is]]))

(deftest math-cases
  (is (= "5" (pr-str (Math/abs -5))) "abs_int")
  (is (= "true" (pr-str (integer? (Math/abs -5)))) "abs_int_type")
  (is (= "true" (pr-str (= 5.0 (Math/abs -5.0)))) "abs_float")
  (is (= "true" (pr-str (float? (Math/abs -5.0)))) "abs_float_type")
  (is (= "7" (pr-str (Math/max 3 7))) "max_int")
  (is (= "3" (pr-str (Math/min 3 7))) "min_int")
  (is (= "true" (pr-str (integer? (Math/max 3 7)))) "max_type")
  (is (= "true" (pr-str (= 2.0 (Math/sqrt 4)))) "sqrt")
  (is (= "true" (pr-str (= 2.0 (Math/floor 2.7)))) "floor")
  (is (= "true" (pr-str (= 3.0 (Math/ceil 2.1)))) "ceil")
  (is (= "true" (pr-str (= 1024.0 (Math/pow 2 10)))) "pow")
  (is (= "3" (pr-str (Math/round 2.6))) "round")
  (is (= "true" (pr-str (integer? (Math/round 2.6)))) "round_type")
  (is (= "true" (pr-str (> (System/currentTimeMillis) 0))) "system_auto_import"))
