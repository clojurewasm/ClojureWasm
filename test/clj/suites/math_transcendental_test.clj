;; test/e2e/phase14_math_transcendental.sh — java.lang.Math transcendentals
;; (log/log10/exp/cbrt/sin/cos/tan/asin/acos/atan/atan2/sinh/cosh/tanh/
;; signum/toRadians/toDegrees/hypot). std.math + builtins; always Double (F-005).

;; Migrated from test/e2e/phase14_math_transcendental.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.math-transcendental-test
  (:require [clojure.test :refer [deftest is]]))

(deftest math-transcendental-cases
  (is (= "0.0" (pr-str (Math/log 1.0))) "log_1")
  (is (= "1.0" (pr-str (Math/exp 0.0))) "exp_0")
  (is (= "3.0" (pr-str (Math/log10 1000.0))) "log10_1k")
  (is (= "3.0" (pr-str (Math/cbrt 27.0))) "cbrt_27")
  (is (= "0.0" (pr-str (Math/sin 0.0))) "sin_0")
  (is (= "1.0" (pr-str (Math/cos 0.0))) "cos_0")
  (is (= "0.0" (pr-str (Math/tan 0.0))) "tan_0")
  (is (= "0.0" (pr-str (Math/atan 0.0))) "atan_0")
  (is (= "0.0" (pr-str (Math/atan2 0.0 1.0))) "atan2")
  (is (= "5.0" (pr-str (Math/hypot 3.0 4.0))) "hypot")
  (is (= "-1.0" (pr-str (Math/signum -3.5))) "signum_n")
  (is (= "0.0" (pr-str (Math/signum 0.0))) "signum_z")
  (is (= "3.141592653589793" (pr-str (Math/toRadians 180.0))) "toRad")
  (is (= "180.0" (pr-str (Math/toDegrees 3.141592653589793))) "toDeg")
  (is (= "true" (pr-str (let [x 0.7] (< (Math/abs (- 1.0 (+ (Math/pow (Math/sin x) 2) (Math/pow (Math/cos x) 2)))) 1e-9)))) "pythag"))
