;; CLJW-BIGINT-STR-PLACEHOLDER: printing a BigInt / Ratio / BigDecimal has no
;; width ceiling. Zig's std big-int formatter renders through a 64-limb stack
;; buffer (about 1233 digits) and writes the literal "(BigInt)" past it, so
;; `(str (reduce *' (range 1N 1000N)))` used to answer "(BigInt)". Every print
;; path (str, pr-str, .toString, print, format, json) now renders the digits,
;; and the decimal parser behind `bigdec` reads a significand of any width.
;;
;; Expected values were taken from clj (JVM) for the same expressions: digit
;; count, digit sum, leading digits and trailing-zero count of 3500!, which is
;; 10887 digits wide.
(ns suites.bignum-print-width-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn- fact [n] (reduce *' (range 1N (inc n))))

(defn- digit-sum [s]
  (reduce + (map #(- (int %) 48) (filter #(Character/isDigit ^char %) s))))

;; Built per test, never at load: run_suites loads every suite before running
;; any, and a load-time 3500! would sit in the heap under gc_heap_return_test's
;; committed-memory baseline.
(defn- big3500 [] (fact 3500))

(deftest bigint-past-the-std-format-bound
  (let [big (big3500)]
    (testing "str of 3500! is its 10887 digits, never the placeholder"
      (let [s (str big)]
        (is (= 10887 (count s)))
        (is (= "23911281994776495250" (subs s 0 20)))
        (is (= 45387 (digit-sum s)))
        (is (= 874 (count (re-find #"0+$" s))))
        (is (not (re-find #"BigInt" s)))))
    (testing "pr-str keeps the N suffix after the full digits"
      (let [s (pr-str big)]
        (is (= 10888 (count s)))
        (is (= \N (last s)))))
    (testing ".toString agrees with str; print keeps the N like pr-str (clj)"
      (is (= (str big) (.toString big)))
      (is (= (pr-str big) (with-out-str (print big)))))
    (testing "format %s is .toString: no N/M reader suffix (clj)"
      (is (= (str big) (format "%s" big)))
      (is (= "1 1.5" (format "%s %s" 1N 1.5M))))
    (testing "1000!, the reported case (999! = (reduce *' (range 1N 1000N)))"
      (is (= 2565 (count (str (fact 999)))))
      (is (= 2566 (count (pr-str (fact 999))))))))

(deftest ratio-past-the-std-format-bound
  (let [big (big3500)
        r (/ 1 big)]
    (is (= 10889 (count (pr-str r))))
    (is (= (str "1/" (str big)) (str r)))
    (is (= 45388 (digit-sum (pr-str r))))))

(deftest bigdecimal-past-the-old-buffer
  (let [big (big3500)
        s (str big)
        d (bigdec s)]
    (is (= s (str d)))
    (is (= (str s "M") (pr-str d)))
    (is (= 45387 (digit-sum (str d)))))
  (testing "scientific and plain forms of a 10887-digit unscaled value"
    (let [d (bigdec (str (str (big3500)) "E-5000"))]
      (is (= "239112819947" (subs (str d) 0 12)))
      (is (= 10888 (count (.toPlainString d)))))))

(deftest rationalize-a-wide-bigdecimal
  (testing "no digit or scale ceiling"
    (is (= 1203 (count (str (rationalize (bigdec "1E-1200"))))))
    (is (= 1501 (count (str (rationalize (bigdec "7E+1500"))))))
    (let [big (big3500)]
      (is (= big (rationalize (bigdec (str big))))))))
