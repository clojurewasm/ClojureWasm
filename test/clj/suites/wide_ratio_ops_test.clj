;; Comparison and integer coercion of Ratios and BigDecimals wider than a Long
;; (CLJW-BIG-RATIO-LITERAL follow-up).
;;
;; A ratio literal can now be as wide as a BigInt, so everything that consumes
;; a Ratio has to handle one. Two exact numbers compare by exact value, as clj's
;; `Numbers.combine` ladder does, never through doubles: 24691357802469135781/2
;; and 12345678901234567891 are the same double but not the same number. Every
;; assertion here also holds under clj 1.12.
(ns suites.wide-ratio-ops-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn- same-number?
  "True when `a` and `b` are `=` and of one class."
  [a b]
  (and (= a b) (= (class a) (class b))))

;; 12345678901234567890.5, which rounds to the same double as both neighbours.
(def ^:private wide-half 24691357802469135781/2)

(deftest comparison-is-exact-across-categories
  (testing "a wide Ratio against the integers either side of it"
    (is (< wide-half 12345678901234567891))
    (is (> wide-half 12345678901234567890))
    (is (<= 12345678901234567890 wide-half 12345678901234567891))
    (is (>= 12345678901234567891 wide-half 12345678901234567890))
    (is (not (== wide-half 12345678901234567891))))
  (testing "a Ratio and a BigDecimal of one value are =="
    (is (== wide-half 12345678901234567890.5M))
    (is (== 1/2 0.5M))
    (is (< 1/4 0.5M)))
  (testing "a Long against a BigDecimal past a double's precision"
    (is (not (== 9007199254740993 9007199254740992.0M)))
    (is (< 9007199254740992.0M 9007199254740993)))
  (testing "a float operand still compares as a double"
    (is (== 1/2 0.5))
    (is (< 1/4 0.5))))

(deftest max-min-pick-by-exact-value
  (is (same-number? 12345678901234567891N (max wide-half 12345678901234567891N)))
  (is (same-number? 12345678901234567890N (min wide-half 12345678901234567890N)))
  (is (= wide-half (max wide-half 12345678901234567890N)))
  (is (= wide-half (min wide-half 12345678901234567891N)))
  (is (= wide-half (max 1 wide-half 12345678901234567890N -5/2))))

(deftest non-terminating-ratio-against-bigdecimal-throws
  (testing "clj converts the Ratio to an exact BigDecimal, which 1/3 has not"
    (is (thrown? ArithmeticException (compare 1/3 0.5M)))
    (is (thrown? ArithmeticException (< 1/3 0.5M)))
    (is (thrown? ArithmeticException (== 1/3 0.5M)))))

(deftest integer-coercions-truncate-any-width
  (is (same-number? 12345678901234567890N (bigint wide-half)))
  (is (same-number? -12345678901234567890N (bigint (- wide-half))))
  (is (same-number? 3N (bigint 7/2)))
  (is (same-number? -3N (bigint -7/2)))
  (is (= 12345678901234567890 (biginteger wide-half)))
  (is (same-number? 123456789012345678901234567890N
                    (bigint 123456789012345678901234567890.75M)))
  (is (same-number? -123456789012345678901234567890N
                    (bigint -123456789012345678901234567890.75M)))
  (testing "long and int still reject a value past their range"
    (is (thrown? IllegalArgumentException (long wide-half)))
    (is (thrown? IllegalArgumentException (int wide-half)))
    (is (same-number? 3 (long 7/2)))
    (is (same-number? -3 (long -7/2)))))

(deftest double-of-ratio-and-bigdecimal-is-clj-doubleValue
  (testing "a Ratio rounds through a DECIMAL64 quotient, as Ratio.doubleValue"
    (is (= 0.6666666666666667 (double 2/3)))
    (is (= -0.6666666666666667 (double -2/3)))
    (is (= 0.1428571428571429 (double 1/7)))
    (is (= 1.234567890123457E19 (double wide-half)))
    (is (= 0.6666666666666667 (+ 2/3 0.0)))
    (is (== 2/3 0.6666666666666667))
    (is (zero? (compare 2/3 0.6666666666666667))))
  (testing "a BigDecimal rounds once to the nearest double"
    (is (= 0.3 (double 0.3M)))
    (is (= 0.3 (+ 0.3M 0.0)))
    (is (= 0.3 (.doubleValue 0.3M)))
    (is (= ##Inf (double 1e400M)))
    (is (= 0.0 (double 1E-400M)))))
