;; Upstream: clojure/test/clojure/test_clojure/numbers.clj
;; Upstream lines: 959
;; CLJW markers: 65

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Stephen C. Gilardi
;;  scgilardi (gmail)
;;  Created 30 October 2008
;;

;; CLJW: ns simplified — removed generative/template/helper imports
(ns clojure.test-clojure.numbers
  (:use clojure.test))

;; CLJW: Coerced-BigDecimal — adapted (removed instance? BigDecimal, used decimal? instead)
(deftest Coerced-BigDecimal
  (doseq [v [(bigdec 3) (bigdec 42N)]]
    (are [x] (true? x)
      (number? v)
      (decimal? v)
      (not (float? v)))))

;; CLJW: BigInteger-conversions — adapted from upstream (removed Float/Double/Long class refs, added M literal)
(deftest BigInteger-conversions
  (doseq [coerce-fn [bigint biginteger]]
    (doseq [v (map coerce-fn [42
                              13178456923875639284562345789M
                              13178456923875639284562345789N])]
      (are [x] (true? x)
        (integer? v)
        (number? v)))))

;; CLJW: equality-tests — adapted (removed ratio, Java class constructors, added BigDecimal)
(deftest equality-tests
  ;; = returns true for numbers in the same category
  ;; CLJW: integer, BigInt and BigDecimal categories
  (are [x y] (= x y)
    2 (bigint 2)
    (bigint 2) (biginteger 2)
    2 (biginteger 2))

  ;; cross-type BigInt equality
  (are [x y] (= x y)
    42N 42
    42 42N
    0N 0
    -1N -1)

  ;; BigDecimal equality
  (are [x y] (= x y)
    2.0M 2.00M
    1.50M 1.500M
    0.0M 0.00M
    42M 42
    42M 42.0
    3.14M 3.14)

  ;; hash consistency for BigInt = integer
  (are [x y] (= (hash x) (hash y))
    42N 42
    0N 0
    -1N -1))

;; CLJW: unchecked-cast-num-obj/prim skipped — Java arrays
;; CLJW: expected-casts skipped — Java arrays/Float/Double classes
;; CLJW: test-prim-with-matching-hint skipped — Math/round type hints

;; *** Functions ***

(defonce DELTA 1e-12)

(deftest test-add
  (are [x y] (= x y)
    (+) 0
    (+ 1) 1
    (+ 1 2) 3
    (+ 1 2 3) 6

    (+ -1) -1
    (+ -1 -2) -3
    (+ -1 +2 -3) -2

    (+ 1 -1) 0
    (+ -1 1) 0

      ;; CLJW: ratio literals (2/3 etc.) removed — not supported
    )

  ;; CLJW: BigInt addition tests
  (are [x y] (= x y)
    (+ 1N 2N) 3N
    (+ 1N 2) 3N
    (+ 1 2N) 3N
    (+ 42N 0) 42N)

  (are [x y] (< (- x y) DELTA)
    (+ 1.2) 1.2
    (+ 1.1 2.4) 3.5
    (+ 1.1 2.2 3.3) 6.6))

;; CLJW: thrown? tests removed from test-add — Integer/MAX_VALUE, ClassCastException

(deftest test-subtract
  ;; CLJW: (is (thrown? IllegalArgumentException (-))) — arity error differs
  (are [x y] (= x y)
    (- 1) -1
    (- 1 2) -1
    (- 1 2 3) -4

    (- -2) 2
    (- 1 -2) 3
    (- 1 -2 -3) 6

    (- 1 1) 0
    (- -1 -1) 0

      ;; CLJW: ratio literals removed
    )

  ;; CLJW: BigInt subtraction tests
  (are [x y] (= x y)
    (- 10N 3N) 7N
    (- 10N 3) 7N
    (- 10 3N) 7N)

  (are [x y] (< (- x y) DELTA)
    (- 1.2) -1.2
    (- 2.2 1.1) 1.1
    (- 6.6 2.2 1.1) 3.3))

;; CLJW: Integer/MIN_VALUE overflow check removed

(deftest test-multiply
  (are [x y] (= x y)
    (*) 1
    (* 2) 2
    (* 2 3) 6
    (* 2 3 4) 24

    (* -2) -2
    (* 2 -3) -6
    (* 2 -3 -1) 6

      ;; CLJW: ratio literals removed
    )

  ;; CLJW: BigInt multiplication tests
  (are [x y] (= x y)
    (* 6N 7N) 42N
    (* 6N 7) 42N
    (* 6 7N) 42N)

  (are [x y] (< (- x y) DELTA)
    (* 1.2) 1.2
    (* 2.0 1.2) 2.4
    (* 3.5 2.0 1.2) 8.4))

;; CLJW: adapted to i48 integer range (NaN-boxing), upstream uses Long/MIN_VALUE
(def ^:private I48-MIN -140737488355328)  ;; CLJW-ADD: i48 min for NaN-boxed integers
(def ^:private I48-MAX 140737488355327)   ;; CLJW-ADD: i48 max for NaN-boxed integers

(deftest test-multiply-longs-at-edge
  ;; CLJW: adapted to i48 range; upstream uses Long/MIN_VALUE = -9223372036854775808
  (are [x] (= x 140737488355328N)
    (*' -1 I48-MIN)
    (*' I48-MIN -1)
    (* -1N I48-MIN)
    (* I48-MIN -1N)
    (* -1 (bigint I48-MIN))
    (* (bigint I48-MIN) -1)))

;; CLJW: test-ratios-simplify-to-ints-where-appropriate skipped — ratio

(deftest test-divide
  (are [x y] (= x y)
    (/ 1) 1
      ;; CLJW: ratio results removed (/ 2) etc.
    (/ 4 2) 2
    (/ 24 3 2) 4
    (/ 24 3 2 -1) -4

    (/ -1) -1
      ;; CLJW: ratio results removed
    (/ -4 -2) 2
    (/ -4 2) -2)

  (are [x y] (< (- x y) DELTA)
    (/ 4.5 3) 1.5
    (/ 4.5 3.0 3.0) 0.5)

  (is (thrown? ArithmeticException (/ 0)))
  (is (thrown? ArithmeticException (/ 2 0))))

;; CLJW: adapted to i48 range; upstream uses Long/MIN_VALUE
(deftest test-divide-bigint-at-edge
  (are [x] (= x (-' I48-MIN))
    (/ I48-MIN -1N)
    (/ (bigint I48-MIN) -1)
    (/ (bigint I48-MIN) -1N)
    (quot I48-MIN -1N)
    (quot (bigint I48-MIN) -1)
    (quot (bigint I48-MIN) -1N)))

;; mod
;; http://en.wikipedia.org/wiki/Modulo_operation

(deftest test-mod
  ; divide by zero
  (is (thrown? ArithmeticException (mod 9 0)))
  (is (thrown? ArithmeticException (mod 0 0)))

  (are [x y] (= x y)
    (mod 4 2) 0
    (mod 3 2) 1
    (mod 6 4) 2
    (mod 0 5) 0

    ;; CLJW: ratio mod tests removed

    (mod 4.0 2.0) 0.0
    (mod 4.5 2.0) 0.5

    ; |num| > |div|, num != k * div
    (mod 42 5) 2      ; (42 / 5) * 5 + (42 mod 5)        = 8 * 5 + 2        = 42
    (mod 42 -5) -3    ; (42 / -5) * (-5) + (42 mod -5)   = -9 * (-5) + (-3) = 42
    (mod -42 5) 3     ; (-42 / 5) * 5 + (-42 mod 5)      = -9 * 5 + 3       = -42
    (mod -42 -5) -2   ; (-42 / -5) * (-5) + (-42 mod -5) = 8 * (-5) + (-2)  = -42

    ; |num| > |div|, num = k * div
    (mod 9 3) 0       ; (9 / 3) * 3 + (9 mod 3) = 3 * 3 + 0 = 9
    (mod 9 -3) 0
    (mod -9 3) 0
    (mod -9 -3) 0

    ; |num| < |div|
    (mod 2 5) 2       ; (2 / 5) * 5 + (2 mod 5)        = 0 * 5 + 2          = 2
    (mod 2 -5) -3     ; (2 / -5) * (-5) + (2 mod -5)   = (-1) * (-5) + (-3) = 2
    (mod -2 5) 3      ; (-2 / 5) * 5 + (-2 mod 5)      = (-1) * 5 + 3       = -2
    (mod -2 -5) -2    ; (-2 / -5) * (-5) + (-2 mod -5) = 0 * (-5) + (-2)    = -2

    ; num = 0, div != 0
    (mod 0 3) 0       ; (0 / 3) * 3 + (0 mod 3) = 0 * 3 + 0 = 0
    (mod 0 -3) 0

    ; large args
    (mod 3216478362187432 432143214) 120355456))

;; rem & quot

(deftest test-rem
  ; divide by zero
  (is (thrown? ArithmeticException (rem 9 0)))
  (is (thrown? ArithmeticException (rem 0 0)))

  (are [x y] (= x y)
    (rem 4 2) 0
    (rem 3 2) 1
    (rem 6 4) 2
    (rem 0 5) 0

    ;; CLJW: ratio rem tests removed

    (rem 4.0 2.0) 0.0
    (rem 4.5 2.0) 0.5

    ; |num| > |div|, num != k * div
    (rem 42 5) 2      ; (8 * 5) + 2 == 42
    (rem 42 -5) 2     ; (-8 * -5) + 2 == 42
    (rem -42 5) -2    ; (-8 * 5) + -2 == -42
    (rem -42 -5) -2   ; (8 * -5) + -2 == -42

    ; |num| > |div|, num = k * div
    (rem 9 3) 0
    (rem 9 -3) 0
    (rem -9 3) 0
    (rem -9 -3) 0

    ; |num| < |div|
    (rem 2 5) 2
    (rem 2 -5) 2
    (rem -2 5) -2
    (rem -2 -5) -2

    ; num = 0, div != 0
    (rem 0 3) 0
    (rem 0 -3) 0))

(deftest test-quot
  ; divide by zero
  (is (thrown? ArithmeticException (quot 9 0)))
  (is (thrown? ArithmeticException (quot 0 0)))

  (are [x y] (= x y)
    (quot 4 2) 2
    (quot 3 2) 1
    (quot 6 4) 1
    (quot 0 5) 0

    ;; CLJW: ratio quot tests removed

    (quot 4.0 2.0) 2.0
    (quot 4.5 2.0) 2.0

    ; |num| > |div|, num != k * div
    (quot 42 5) 8     ; (8 * 5) + 2 == 42
    (quot 42 -5) -8   ; (-8 * -5) + 2 == 42
    (quot -42 5) -8   ; (-8 * 5) + -2 == -42
    (quot -42 -5) 8   ; (8 * -5) + -2 == -42

    ; |num| > |div|, num = k * div
    (quot 9 3) 3
    (quot 9 -3) -3
    (quot -9 3) -3
    (quot -9 -3) 3

    ; |num| < |div|
    (quot 2 5) 0
    (quot 2 -5) 0
    (quot -2 5) 0
    (quot -2 -5) 0

    ; num = 0, div != 0
    (quot 0 3) 0
    (quot 0 -3) 0

    ;; CLJW: BigInt quot tests
    (quot 10N 3N) 3N
    (quot 10N 3) 3N
    (quot 10 3N) 3N
    (quot -42N 5N) -8N))

;; CLJW-ADD: BigInt-specific rem/mod tests
(deftest test-bigint-rem-mod
  (are [x y] (= x y)
    (rem 10N 3N) 1N
    (rem 10N 3) 1N
    (rem 10 3N) 1N
    (rem -42N 5N) -2N
    (mod 10N 3N) 1N
    (mod 10N 3) 1N
    (mod -42N 5N) 3N))

;; *** Predicates ***

;; CLJW: test-pos?-zero?-neg? — no byte/short/ratio/Float (added bigdec)
(deftest test-pos?-zero?-neg?
  (are [x] (true? x)
    (pos? 5)
    (not (pos? 0))
    (not (pos? -5))
    (pos? 7.0)
    (not (pos? 0.0))
    (not (pos? -7.0))
    ;; CLJW: restored BigInt predicates
    (pos? (bigint 6))
    (not (pos? (bigint 0)))
    (not (pos? (bigint -6)))
    ;; CLJW: BigDecimal predicates
    (pos? (bigdec 9))
    (not (pos? (bigdec 0)))
    (not (pos? (bigdec -9)))
    (zero? 0)
    (zero? 0.0)
    (not (zero? 1))
    (not (zero? -1))
    ;; CLJW: restored BigInt zero?
    (zero? (bigint 0))
    (not (zero? (bigint 1)))
    ;; CLJW: BigDecimal zero?
    (zero? (bigdec 0))
    (not (zero? (bigdec 1)))
    (neg? -5)
    (not (neg? 0))
    (not (neg? 5))
    (neg? -7.0)
    (not (neg? 0.0))
    (not (neg? 7.0))
    ;; CLJW: restored BigInt neg?
    (neg? (bigint -6))
    (not (neg? (bigint 0)))
    (not (neg? (bigint 6)))
    ;; CLJW: BigDecimal neg?
    (neg? (bigdec -9))
    (not (neg? (bigdec 0)))
    (not (neg? (bigdec 9)))))

;; even? odd?

(deftest test-even?
  (are [x] (true? x)
    (even? -4)
    (not (even? -3))
    (even? 0)
    (not (even? 5))
    (even? 8)
    ;; CLJW: restored BigInt even?
    (even? 42N)
    (not (even? 43N))))
;; CLJW: thrown? tests for ratio/double even? — not supported

(deftest test-odd?
  (are [x] (true? x)
    (not (odd? -4))
    (odd? -3)
    (not (odd? 0))
    (odd? 5)
    (not (odd? 8))
    ;; CLJW: restored BigInt odd?
    (odd? 43N)
    (not (odd? 42N))))
;; CLJW: thrown? tests for ratio/double odd? — not supported

;; CLJW: upstream uses *' for auto-promoting multiply
(defn- expt
  [x n] (reduce *' 1 (repeat n x)))

(deftest test-bit-shift-left
  (are [x y] (= x y)
    2r10 (bit-shift-left 2r1 1)
    2r100 (bit-shift-left 2r1 2)
    2r1000 (bit-shift-left 2r1 3)
    2r00101110 (bit-shift-left 2r00010111 1)
    2r00101110 (apply bit-shift-left [2r00010111 1])
    0 (bit-shift-left 2r10 -1) ; truncated to least 6-bits, 63
    (expt 2 32) (bit-shift-left 1 32)
    (expt 2 16) (bit-shift-left 1 10000) ; truncated to least 6-bits, 16
    ))
;; CLJW: thrown? for BigInt bit-shift-left — not supported

(deftest test-bit-shift-right
  (are [x y] (= x y)
    2r0 (bit-shift-right 2r1 1)
    2r010 (bit-shift-right 2r100 1)
    2r001 (bit-shift-right 2r100 2)
    2r000 (bit-shift-right 2r100 3)
    2r0001011 (bit-shift-right 2r00010111 1)
    2r0001011 (apply bit-shift-right [2r00010111 1])
    0 (bit-shift-right 2r10 -1) ; truncated to least 6-bits, 63
    1 (bit-shift-right (expt 2 32) 32)
    1 (bit-shift-right (expt 2 16) 10000) ; truncated to least 6-bits, 16
    -1 (bit-shift-right -2r10 1)))
;; CLJW: thrown? for BigInt bit-shift-right — not supported

(deftest test-unsigned-bit-shift-right
  (are [x y] (= x y)
    2r0 (unsigned-bit-shift-right 2r1 1)
    2r010 (unsigned-bit-shift-right 2r100 1)
    2r001 (unsigned-bit-shift-right 2r100 2)
    2r000 (unsigned-bit-shift-right 2r100 3)
    2r0001011 (unsigned-bit-shift-right 2r00010111 1)
    2r0001011 (apply unsigned-bit-shift-right [2r00010111 1])
    0 (unsigned-bit-shift-right 2r10 -1) ; truncated to least 6-bits, 63
    1 (unsigned-bit-shift-right (expt 2 32) 32)
    1 (unsigned-bit-shift-right (expt 2 16) 10000) ; truncated to least 6-bits, 16
    9223372036854775807 (unsigned-bit-shift-right -2r10 1)))
;; CLJW: thrown? for BigInt unsigned-bit-shift-right — not supported

(deftest test-bit-clear
  (is (= 2r1101 (bit-clear 2r1111 1)))
  (is (= 2r1101 (bit-clear 2r1101 1))))

(deftest test-bit-set
  (is (= 2r1111 (bit-set 2r1111 1)))
  (is (= 2r1111 (bit-set 2r1101 1))))

(deftest test-bit-flip
  (is (= 2r1101 (bit-flip 2r1111 1)))
  (is (= 2r1111 (bit-flip 2r1101 1))))

(deftest test-bit-test
  (is (true? (bit-test 2r1111 1)))
  (is (false? (bit-test 2r1101 1))))

;; CLJW: test-array-types skipped — Java arrays
;; CLJW: test-ratios skipped — ratio type
;; CLJW: test-arbitrary-precision-subtract skipped — BigInt class
;; CLJW: test-min-max skipped — Float. constructor, class checks, ratio

(deftest test-abs
  (are [in ex] (= ex (abs in))
    -1 1
    1 1
    -1.0 1.0
    -0.0 0.0
    ;; CLJW: restored BigInt abs tests
    -123N 123N
    123N 123N
    ;; CLJW: BigDecimal abs (returns float)
    -123.456M 123.456
    123.456M 123.456))
;; CLJW: ratio/##Inf/##NaN abs tests removed

;; CLJW: clj-868 (NaN contagious min/max) skipped — Float/Double class constructors

(deftest test-nan-comparison
  (are [x y] (= x y)
    (< 1000 ##NaN) false
    (<= 1000 ##NaN) false
    (> 1000 ##NaN) false
    (>= 1000 ##NaN) false))
;; CLJW: Double/NaN class constructor tests removed, used ##NaN instead

(deftest test-nan-as-operand
  (testing "All numeric operations with NaN as an operand produce NaN as a result"
    (let [nan ##NaN]
      (are [x] (NaN? x)
        (+ nan 1)
        (+ nan 0)
        (+ nan 0.0)
        (+ 1 nan)
        (+ 0 nan)
        (+ 0.0 nan)
        (+ nan nan)
        (- nan 1)
        (- nan 0)
        (- nan 0.0)
        (- 1 nan)
        (- 0 nan)
        (- 0.0 nan)
        (- nan nan)
        (* nan 1)
        (* nan 0)
        (* nan 0.0)
        (* 1 nan)
        (* 0 nan)
        (* 0.0 nan)
        (* nan nan)
        (/ nan 1)
        (/ nan 0)
        (/ nan 0.0)
        (/ 1 nan)
        (/ 0 nan)
        (/ 0.0 nan)
        (/ nan nan)))))
;; CLJW: Object-cast (onan) NaN tests removed — no cast

;; CLJW: unchecked-inc/dec/negate/add/subtract/multiply overflow tests skipped — Long/MIN_VALUE, Long/MAX_VALUE, Long/valueOf
;; CLJW: warn-on-boxed skipped — *unchecked-math*, eval-in-temp-ns
;; CLJW: comparisons — adapted (removed Integer/Float constructors, ratio; added BigDecimal)
(deftest comparisons
  ;; BigInt comparisons with integers
  (are [x y] (= x y)
    (< 1N 10) true
    (< 10 1N) false
    (< 1N 10N) true
    (<= 1N 1) true
    (<= 1 1N) true
    (> 10N 1) true
    (> 1 10N) false
    (>= 10N 10) true
    (>= 10 10N) true)
  ;; BigInt comparisons with floats
  (are [x y] (= x y)
    (< 1N 10.0) true
    (< 10.0 1N) false
    (<= 1N 1.0) true
    (> 10N 1.0) true
    (>= 10N 10.0) true)
  ;; CLJW: BigDecimal comparisons
  (are [x y] (= x y)
    (< 1M 10M) true
    (< 10M 1M) false
    (<= 1M 1M) true
    (> 10M 1M) true
    (>= 10M 10M) true
    (< 1M 10) true
    (> 10M 1) true
    (< 1M 10.0) true
    (> 10M 1.0) true))

;; CLJW-ADD: BigDecimal arithmetic tests
(deftest test-bigdec-arithmetic
  ;; basic ops
  (are [x y] (= x y)
    (+ 1M 2M) 3M
    (- 10M 3M) 7M
    (* 3M 4M) 12M)
  ;; cross-type with integer
  (are [x y] (= x y)
    (+ 1M 2) 3M
    (- 10M 3) 7M
    (* 2M 3) 6M)
  ;; bigdec coercion
  (is (decimal? (bigdec 42)))
  (is (decimal? (bigdec 3.14)))
  (is (decimal? (bigdec "99.9")))
  (is (= (bigdec 42) 42M))
  ;; max / min with BigDecimal
  (is (= (max 1M 5M 3M) 5M))
  (is (= (min 1M 5M 3M) 1M)))

;; CLJW: defspec generative tests skipped — clojure.test.generative

;; CLJW-ADD: auto-promoting arithmetic tests (Phase 43.7)
;; CLJW: instance? BigInt replaced with (= :big-int (type ...))
(deftest test-auto-promoting-arithmetic
  (testing "basic operations (no overflow)"
    (is (= 3 (+' 1 2)))
    (is (= 7 (-' 10 3)))
    (is (= 20 (*' 4 5)))
    (is (= 0 (+')))
    (is (= 1 (*')))
    (is (= -5 (-' 5))))
  (testing "i48 overflow promotes to BigInt"
    (is (= 140737488355328N (+' I48-MAX 1)))
    (is (= :big-int (type (+' I48-MAX 1))))
    (is (= -140737488355329N (-' I48-MIN 1)))
    (is (= :big-int (type (-' I48-MIN 1))))
    (is (= 281474976710654N (*' I48-MAX 2)))
    (is (= :big-int (type (*' I48-MAX 2)))))
  (testing "inc'/dec' promote on overflow"
    (is (= 140737488355328N (inc' I48-MAX)))
    (is (= :big-int (type (inc' I48-MAX))))
    (is (= -140737488355329N (dec' I48-MIN)))
    (is (= :big-int (type (dec' I48-MIN)))))
  (testing "BigInt inputs remain BigInt"
    (is (= 3N (+' 1N 2)))
    (is (= :big-int (type (+' 1N 2))))
    (is (= 7N (-' 10N 3)))
    (is (= :big-int (type (-' 10N 3))))
    (is (= 6N (*' 2N 3)))
    (is (= :big-int (type (*' 2N 3)))))
  (testing "variadic"
    (is (= 15 (+' 1 2 3 4 5)))
    (is (= 120 (*' 1 2 3 4 5)))
    (is (= -5 (-' 10 5 3 7)))))

;; CLJW-ADD: test runner invocation
(run-tests)
