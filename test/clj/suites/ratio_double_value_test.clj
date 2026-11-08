;; A Ratio becomes a double through clj's `Ratio.doubleValue`, which rounds the
;; exact quotient HALF_EVEN to 16 significant digits (MathContext.DECIMAL64)
;; before taking the nearest double. That first rounding is observable: `-2/3`
;; is -0.6666666666666667 and `1/7` is 0.1428571428571429, where an f64 divide
;; of numerator by denominator gives ...666 and ...285. `double`, float
;; contagion, the mixed float comparison, `.doubleValue` and JSON output all
;; take the one path (`ratio.toF64`), so they cannot disagree.
;;
;; Every expected value is JVM Clojure 1.12's, measured with `clojure -M`.
;; Run by `test/clj/run_suites.clj`.
(ns suites.ratio-double-value-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.data.json :as json]))

(def ^:private ten-pow-23 (reduce *' (repeat 23 10N)))

(deftest double-coercion
  (is (= -0.6666666666666667 (double -2/3)))
  (is (= 0.1428571428571429 (double 1/7)))
  (is (= 3.142857142857143 (double 22/7)))
  (is (= 0.3333333333333333 (double 1/3)))
  (is (= 0.5 (double 1/2)))
  (is (= -3.074457345618259E18 (double (/ -9223372036854775808 3))))
  (is (= 1.084202172485504E-19 (double (/ 1 9223372036854775807))))
  (testing "big ratios, either side of 1"
    (is (= 3.333333333333333E22 (double (/ ten-pow-23 3))))
    (is (= 3.0E-23 (double (/ 3 ten-pow-23))))
    (is (= 5.992310449541053E307 (double (/ (reduce *' (repeat 1024 2N)) 3))))
    (is (= ##Inf (double (/ (reduce *' (repeat 400 10N)) 3))))
    (is (= 0.0 (double (/ 1 (reduce *' (repeat 400 10N))))))))

(deftest every-path-agrees
  (doseq [r [-2/3 1/7 22/7 1/3 (/ ten-pow-23 7)]]
    (is (= (double r) (.doubleValue r) (+ 0.0 r) (* 1.0 r) (- r 0.0) (/ r 1.0)) (pr-str r))))

(deftest float-contagion
  (is (= -0.6666666666666667 (+ 0.0 -2/3)))
  (is (= 1.1428571428571428 (+ 1.0 1/7)))
  (is (= 0.2857142857142858 (* 2.0 1/7))))

(deftest mixed-float-comparison
  (is (true? (< 0.6666666666666666 2/3)))
  (is (false? (== 0.6666666666666666 2/3)))
  (is (true? (== 0.6666666666666667 2/3))))

(deftest json-writes-the-double
  (is (= "0.1428571428571429" (json/write-str 1/7)))
  (is (= "[-0.6666666666666667]" (json/write-str [-2/3]))))
