;; Ported from clojure/test_clojure/numbers.clj
;; Tests for numeric operations: arithmetic, predicates, bitwise, comparisons
;;
;; SKIP: BigDecimal (M literals), BigInt (N literals), Ratio (e.g. 2/3)
;; SKIP: Java class refs (Long/MAX_VALUE, Float/MAX_VALUE, etc.)
;; SKIP: Generative testing (clojure.test.generative, clojure.data.generators)
;; SKIP: Java exceptions (ClassCastException, ArithmeticException, IllegalArgumentException)
;; SKIP: char tests (\a etc.)
;; SKIP: instance? checks (Java-specific)
;; NaN? and infinite? now implemented (T18.4)
;; SKIP: unchecked-* operations (not implemented)
;; SKIP: Type/class identity tests
;; SKIP: warn-on-boxed, array types, expected-casts

(ns test.numbers
  (:use clojure.test))

;; *** Arithmetic ***

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
    (+ -1 1) 0)

  ;; SKIP: Ratio tests (+ 2/3), (+ 2/3 1), (+ 2/3 1/3)

  ;; float addition
  (is (< (- (+ 1.2) 1.2) 1e-12))
  (is (< (- (+ 1.1 2.4) 3.5) 1e-12))
  (is (< (- (+ 1.1 2.2 3.3) 6.6) 1e-12))

  ;; no integer overflow for moderate values (i64 range)
  (is (> (+ 2147483647 10) 2147483647)))

  ;; SKIP: (is (thrown? ClassCastException (+ "ab" "cd")))

(deftest test-subtract
  ;; SKIP: (is (thrown? IllegalArgumentException (-))) — arity check

  (are [x y] (= x y)
    (- 1) -1
    (- 1 2) -1
    (- 1 2 3) -4

    (- -2) 2
    (- 1 -2) 3
    (- 1 -2 -3) 6

    (- 1 1) 0
    (- -1 -1) 0)

  ;; SKIP: Ratio tests (- 2/3), (- 2/3 1), (- 2/3 1/3)

  ;; float subtraction
  (is (< (- (- 1.2) -1.2) 1e-12))
  (is (< (- (- 2.2 1.1) 1.1) 1e-12))
  (is (< (- (- 6.6 2.2 1.1) 3.3) 1e-12))

  ;; no underflow for moderate values
  (is (< (- -2147483648 10) -2147483648)))

(deftest test-multiply
  (are [x y] (= x y)
    (*) 1
    (* 2) 2
    (* 2 3) 6
    (* 2 3 4) 24

    (* -2) -2
    (* 2 -3) -6
    (* 2 -3 -1) 6)

  ;; SKIP: Ratio tests (* 1/2), (* 1/2 1/3), etc.

  ;; float multiplication
  (is (< (- (* 1.2) 1.2) 1e-12))
  (is (< (- (* 2.0 1.2) 2.4) 1e-12))
  (is (< (- (* 3.5 2.0 1.2) 8.4) 1e-12))

  ;; no overflow for moderate values
  (is (> (* 3 1073741823) 2147483647)))

  ;; SKIP: test-multiply-longs-at-edge (BigInt, *' operators)

(deftest test-divide
  (are [x y] (= x y)
    (/ 1) 1
    (/ 4 2) 2
    (/ 24 3 2) 4
    (/ 24 3 2 -1) -4

    (/ -1) -1
    (/ -4 -2) 2
    (/ -4 2) -2)

  ;; SKIP: Ratio results (/ 2) => 1/2, (/ 3 2) => 3/2, etc.

  ;; float division
  (is (< (- (/ 4.5 3) 1.5) 1e-12))
  (is (< (- (/ 4.5 3.0 3.0) 0.5) 1e-12))

  ;; divide by zero
  (is (thrown? Exception (/ 0)))
  (is (thrown? Exception (/ 2 0))))

  ;; SKIP: (is (thrown? IllegalArgumentException (/))) — arity check
  ;; SKIP: test-divide-bigint-at-edge (BigInt)

;; *** mod / rem / quot ***

(deftest test-mod
  ;; divide by zero
  (is (thrown? Exception (mod 9 0)))
  (is (thrown? Exception (mod 0 0)))

  (are [x y] (= x y)
    (mod 4 2) 0
    (mod 3 2) 1
    (mod 6 4) 2
    (mod 0 5) 0

    ;; SKIP: Ratio tests (mod 2 1/2), (mod 2/3 1/2), (mod 1 2/3)

    (mod 4.0 2.0) 0.0
    (mod 4.5 2.0) 0.5

    ;; |num| > |div|, num != k * div
    (mod 42 5) 2
    (mod 42 -5) -3
    (mod -42 5) 3
    (mod -42 -5) -2

    ;; |num| > |div|, num = k * div
    (mod 9 3) 0
    (mod 9 -3) 0
    (mod -9 3) 0
    (mod -9 -3) 0

    ;; |num| < |div|
    (mod 2 5) 2
    (mod 2 -5) -3
    (mod -2 5) 3
    (mod -2 -5) -2

    ;; num = 0, div != 0
    (mod 0 3) 0
    (mod 0 -3) 0

    ;; large args
    (mod 3216478362187432 432143214) 120355456))

(deftest test-rem
  ;; divide by zero
  (is (thrown? Exception (rem 9 0)))
  (is (thrown? Exception (rem 0 0)))

  (are [x y] (= x y)
    (rem 4 2) 0
    (rem 3 2) 1
    (rem 6 4) 2
    (rem 0 5) 0

    ;; SKIP: Ratio tests (rem 2 1/2), (rem 2/3 1/2), (rem 1 2/3)

    (rem 4.0 2.0) 0.0
    (rem 4.5 2.0) 0.5

    ;; |num| > |div|, num != k * div
    (rem 42 5) 2      ; (8 * 5) + 2 == 42
    (rem 42 -5) 2     ; (-8 * -5) + 2 == 42
    (rem -42 5) -2    ; (-8 * 5) + -2 == -42
    (rem -42 -5) -2   ; (8 * -5) + -2 == -42

    ;; |num| > |div|, num = k * div
    (rem 9 3) 0
    (rem 9 -3) 0
    (rem -9 3) 0
    (rem -9 -3) 0

    ;; |num| < |div|
    (rem 2 5) 2
    (rem 2 -5) 2
    (rem -2 5) -2
    (rem -2 -5) -2

    ;; num = 0, div != 0
    (rem 0 3) 0
    (rem 0 -3) 0))

(deftest test-quot
  ;; divide by zero
  (is (thrown? Exception (quot 9 0)))
  (is (thrown? Exception (quot 0 0)))

  (are [x y] (= x y)
    (quot 4 2) 2
    (quot 3 2) 1
    (quot 6 4) 1
    (quot 0 5) 0

    ;; SKIP: Ratio tests (quot 2 1/2), (quot 2/3 1/2), (quot 1 2/3)

    (quot 4.0 2.0) 2.0
    (quot 4.5 2.0) 2.0

    ;; |num| > |div|, num != k * div
    (quot 42 5) 8     ; (8 * 5) + 2 == 42
    (quot 42 -5) -8   ; (-8 * -5) + 2 == 42
    (quot -42 5) -8   ; (-8 * 5) + -2 == -42
    (quot -42 -5) 8   ; (8 * -5) + -2 == -42

    ;; |num| > |div|, num = k * div
    (quot 9 3) 3
    (quot 9 -3) -3
    (quot -9 3) -3
    (quot -9 -3) 3

    ;; |num| < |div|
    (quot 2 5) 0
    (quot 2 -5) 0
    (quot -2 5) 0
    (quot -2 -5) 0

    ;; num = 0, div != 0
    (quot 0 3) 0
    (quot 0 -3) 0))

;; *** Predicates ***

(deftest test-pos?-zero?-neg?
  ;; Integer predicates
  (is (true? (pos? 5)))
  (is (false? (pos? 0)))
  (is (false? (pos? -5)))

  (is (false? (zero? 5)))
  (is (true? (zero? 0)))
  (is (false? (zero? -5)))

  (is (false? (neg? 5)))
  (is (false? (neg? 0)))
  (is (true? (neg? -5)))

  ;; Float predicates
  (is (true? (pos? 7.0)))
  (is (false? (pos? 0.0)))
  (is (false? (pos? -7.0)))

  (is (false? (zero? 7.0)))
  (is (true? (zero? 0.0)))
  (is (false? (zero? -7.0)))

  (is (false? (neg? 7.0)))
  (is (false? (neg? 0.0)))
  (is (true? (neg? -7.0))))

  ;; NOTE: byte/short/int/long coercion tests moved to end of file (T18.5.2)
  ;; SKIP: BigInt, BigDecimal, Ratio predicates

(deftest test-even?
  (is (true? (even? -4)))
  (is (false? (even? -3)))
  (is (true? (even? 0)))
  (is (false? (even? 5)))
  (is (true? (even? 8))))

  ;; SKIP: (is (thrown? IllegalArgumentException (even? 1/2)))
  ;; SKIP: (is (thrown? IllegalArgumentException (even? (double 10))))

(deftest test-odd?
  (is (false? (odd? -4)))
  (is (true? (odd? -3)))
  (is (false? (odd? 0)))
  (is (true? (odd? 5)))
  (is (false? (odd? 8))))

  ;; SKIP: (is (thrown? IllegalArgumentException (odd? 1/2)))
  ;; SKIP: (is (thrown? IllegalArgumentException (odd? (double 10))))

;; *** Bitwise Operations ***

(deftest test-bit-shift-left
  (are [x y] (= x y)
    2r10 (bit-shift-left 2r1 1)
    2r100 (bit-shift-left 2r1 2)
    2r1000 (bit-shift-left 2r1 3)
    2r00101110 (bit-shift-left 2r00010111 1)
    2r00101110 (apply bit-shift-left [2r00010111 1])))

  ;; SKIP: shift with negative amount (truncated to 6-bits) — JVM-specific behavior
  ;; SKIP: expt helper tests (depend on *' operator)
  ;; SKIP: (is (thrown? IllegalArgumentException (bit-shift-left 1N 1)))

(deftest test-bit-shift-right
  (are [x y] (= x y)
    2r0 (bit-shift-right 2r1 1)
    2r010 (bit-shift-right 2r100 1)
    2r001 (bit-shift-right 2r100 2)
    2r000 (bit-shift-right 2r100 3)
    2r0001011 (bit-shift-right 2r00010111 1)
    2r0001011 (apply bit-shift-right [2r00010111 1])
    -1 (bit-shift-right -2r10 1)))

  ;; SKIP: shift with negative amount (truncated to 6-bits) — JVM-specific behavior
  ;; SKIP: expt helper tests
  ;; SKIP: (is (thrown? IllegalArgumentException (bit-shift-right 1N 1)))

(deftest test-unsigned-bit-shift-right
  (are [x y] (= x y)
    2r0 (unsigned-bit-shift-right 2r1 1)
    2r010 (unsigned-bit-shift-right 2r100 1)
    2r001 (unsigned-bit-shift-right 2r100 2)
    2r000 (unsigned-bit-shift-right 2r100 3)
    2r0001011 (unsigned-bit-shift-right 2r00010111 1)
    2r0001011 (apply unsigned-bit-shift-right [2r00010111 1])
    9223372036854775807 (unsigned-bit-shift-right -2r10 1)))

  ;; SKIP: shift with negative amount (truncated to 6-bits) — JVM-specific behavior
  ;; SKIP: expt helper tests
  ;; SKIP: (is (thrown? IllegalArgumentException (unsigned-bit-shift-right 1N 1)))

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

;; *** Bitwise logic (additional) ***

(deftest test-bit-and
  (are [x y] (= x y)
    (bit-and 2r1100 2r1010) 2r1000
    (bit-and 2r1111 2r1010) 2r1010
    (bit-and 2r1111 2r0000) 2r0000
    (bit-and 0xFF 0x0F) 0x0F
    (bit-and -1 42) 42))

(deftest test-bit-or
  (are [x y] (= x y)
    (bit-or 2r1100 2r1010) 2r1110
    (bit-or 2r1111 2r0000) 2r1111
    (bit-or 2r0000 2r0000) 2r0000
    (bit-or 0xF0 0x0F) 0xFF))

(deftest test-bit-xor
  (are [x y] (= x y)
    (bit-xor 2r1100 2r1010) 2r0110
    (bit-xor 2r1111 2r1111) 2r0000
    (bit-xor 2r0000 2r1111) 2r1111
    (bit-xor 0xFF 0xFF) 0))

(deftest test-bit-not
  (are [x y] (= x y)
    (bit-not 0) -1
    (bit-not -1) 0
    (bit-not 1) -2
    (bit-not 42) -43))

;; *** Comparisons ***

(deftest test-comparisons
  ;; Basic integer comparisons
  (is (< 1 10))
  (is (not (< 10 1)))
  (is (not (< 1 1)))

  (is (<= 1 10))
  (is (<= 1 1))
  (is (not (<= 10 1)))

  (is (> 10 1))
  (is (not (> 1 10)))
  (is (not (> 1 1)))

  (is (>= 10 1))
  (is (>= 1 1))
  (is (not (>= 1 10)))

  ;; Float comparisons
  (is (< 1.0 10.0))
  (is (not (< 10.0 1.0)))
  (is (not (< 1.0 1.0)))

  (is (<= 1.0 10.0))
  (is (<= 1.0 1.0))
  (is (not (<= 10.0 1.0)))

  (is (> 10.0 1.0))
  (is (not (> 1.0 10.0)))
  (is (not (> 1.0 1.0)))

  (is (>= 10.0 1.0))
  (is (>= 1.0 1.0))
  (is (not (>= 1.0 10.0)))

  ;; Mixed int/float comparisons
  (is (< 1 10.0))
  (is (< 1.0 10))
  (is (not (< 10.0 1)))
  (is (not (< 10 1.0)))

  (is (<= 1 1.0))
  (is (<= 1.0 1))

  (is (> 10.0 1))
  (is (> 10 1.0))

  (is (>= 1 1.0))
  (is (>= 1.0 1))

  ;; Multi-arity comparisons
  (is (< 1 2 3 4 5))
  (is (not (< 1 2 3 3 5)))
  (is (<= 1 2 3 3 5))
  (is (> 5 4 3 2 1))
  (is (not (> 5 4 3 3 1)))
  (is (>= 5 4 3 3 1)))

  ;; SKIP: Integer/Float object comparisons (no Integer. Float. constructors)
  ;; SKIP: Ratio, BigInt, BigDecimal comparison tests

;; *** Numeric equality (==) ***

(deftest test-numeric-equality
  ;; == returns true for numerically equal values across int/float
  (is (== 0 0.0))
  (is (== 2 2.0))
  (is (== -1 -1.0))
  (is (== 42 42.0))

  ;; == on same types
  (is (== 1 1))
  (is (== 1.0 1.0))
  (is (not (== 1 2)))
  (is (not (== 1.0 2.0)))

  ;; Multi-arity ==
  (is (== 1 1 1 1))
  (is (== 1 1.0 1 1.0))
  (is (not (== 1 1 2 1))))

  ;; SKIP: BigInt, BigDecimal, Ratio equality tests

;; *** abs ***

(deftest test-abs
  (are [in ex] (= ex (abs in))
    -1 1
    1 1
    0 0
    -1.0 1.0
    -0.0 0.0)

  ;; SKIP: Long/MIN_VALUE special case (depends on BigInt auto-promotion)
  ;; SKIP: ##-Inf ##Inf (abs of infinity)
  ;; SKIP: BigDecimal, BigInt, Ratio abs tests
  ;; SKIP: (is (NaN? (abs ##NaN))) — NaN? not implemented

  ;; Basic abs for large integers
  (is (= 1000000 (abs -1000000)))
  (is (= 1000000 (abs 1000000))))

;; *** min / max ***

(deftest test-min-max
  ;; single argument
  (is (= 0.0 (min 0.0)))
  (is (= 0.0 (max 0.0)))
  (is (= 5 (min 5)))
  (is (= 5 (max 5)))

  ;; two arguments
  (is (= -1.0 (min 0.0 -1.0)))
  (is (= 0.0 (max 0.0 -1.0)))
  (is (= -1.0 (min -1.0 0.0)))
  (is (= 0.0 (max -1.0 0.0)))
  (is (= 0.0 (min 0.0 1.0)))
  (is (= 1.0 (max 0.0 1.0)))
  (is (= 0.0 (min 1.0 0.0)))
  (is (= 1.0 (max 1.0 0.0)))

  ;; three arguments
  (is (= -1.0 (min 0.0 1.0 -1.0)))
  (is (= 1.0 (max 0.0 1.0 -1.0)))
  (is (= -1.0 (min 0.0 -1.0 1.0)))
  (is (= 1.0 (max 0.0 -1.0 1.0)))
  (is (= -1.0 (min -1.0 1.0 0.0)))
  (is (= 1.0 (max -1.0 1.0 0.0)))

  ;; integer min/max
  (is (= 1 (min 1 2 3)))
  (is (= 3 (max 1 2 3)))
  (is (= -3 (min -3 -2 -1)))
  (is (= -1 (max -3 -2 -1)))

  ;; mixed int/float
  (is (= 1 (min 1 2.0 3)))
  (is (= 3 (max 1.0 2 3))))

  ;; SKIP: Float/NaN contagion tests
  ;; SKIP: Type preservation tests (class checks)

;; *** Type predicates ***

(deftest test-number?
  (is (true? (number? 0)))
  (is (true? (number? 42)))
  (is (true? (number? -1)))
  (is (true? (number? 3.14)))
  (is (true? (number? -0.0)))
  (is (false? (number? nil)))
  (is (false? (number? "42")))
  (is (false? (number? :foo)))
  (is (false? (number? true))))

(deftest test-integer?
  (is (true? (integer? 0)))
  (is (true? (integer? 42)))
  (is (true? (integer? -1)))
  (is (false? (integer? 3.14)))
  (is (false? (integer? 0.0)))
  (is (false? (integer? nil)))
  (is (false? (integer? "42"))))

(deftest test-float?
  (is (true? (float? 3.14)))
  (is (true? (float? 0.0)))
  (is (true? (float? -1.5)))
  (is (false? (float? 0)))
  (is (false? (float? 42)))
  (is (false? (float? nil)))
  (is (false? (float? "3.14"))))

;; *** NaN behavior ***

(deftest test-nan-comparison
  ;; NaN comparisons always return false
  (is (false? (< 1000 ##NaN)))
  (is (false? (<= 1000 ##NaN)))
  (is (false? (> 1000 ##NaN)))
  (is (false? (>= 1000 ##NaN)))
  (is (false? (= ##NaN ##NaN)))
  (is (false? (== ##NaN ##NaN)))
  (is (false? (< ##NaN 1000)))
  (is (false? (<= ##NaN 1000)))
  (is (false? (> ##NaN 1000)))
  (is (false? (>= ##NaN 1000))))

(deftest test-nan-as-operand
  (testing "Arithmetic with NaN produces NaN"
    ;; We test NaN-ness by checking (not (= x x)), since NaN != NaN
    (let [nan ##NaN
          nan-result? (fn [x] (not (= x x)))]
      ;; Addition
      (is (nan-result? (+ nan 1)))
      (is (nan-result? (+ nan 0)))
      (is (nan-result? (+ nan 0.0)))
      (is (nan-result? (+ 1 nan)))
      (is (nan-result? (+ 0 nan)))
      (is (nan-result? (+ 0.0 nan)))
      (is (nan-result? (+ nan nan)))

      ;; Subtraction
      (is (nan-result? (- nan 1)))
      (is (nan-result? (- nan 0)))
      (is (nan-result? (- nan 0.0)))
      (is (nan-result? (- 1 nan)))
      (is (nan-result? (- 0 nan)))
      (is (nan-result? (- 0.0 nan)))
      (is (nan-result? (- nan nan)))

      ;; Multiplication
      (is (nan-result? (* nan 1)))
      (is (nan-result? (* nan 0)))
      (is (nan-result? (* nan 0.0)))
      (is (nan-result? (* 1 nan)))
      (is (nan-result? (* 0 nan)))
      (is (nan-result? (* 0.0 nan)))
      (is (nan-result? (* nan nan)))

      ;; Division
      (is (nan-result? (/ nan 1)))
      (is (nan-result? (/ nan 0.0)))
      (is (nan-result? (/ 1 nan)))
      (is (nan-result? (/ 0 nan)))
      (is (nan-result? (/ 0.0 nan)))
      (is (nan-result? (/ nan nan))))))

  ;; SKIP: (/ nan 0) — integer divide by zero may throw instead of NaN
  ;; SKIP: Object NaN (cast Object Double/NaN)

;; *** Infinity ***

(deftest test-infinity
  (is (= ##Inf ##Inf))
  (is (= ##-Inf ##-Inf))
  (is (not (= ##Inf ##-Inf)))
  (is (< ##-Inf 0))
  (is (> ##Inf 0))
  (is (< ##-Inf ##Inf))

  ;; Arithmetic with infinity
  (is (= ##Inf (+ ##Inf 1)))
  (is (= ##Inf (+ ##Inf 1000000)))
  (is (= ##-Inf (- ##-Inf 1)))
  (is (= ##Inf (* ##Inf 2)))
  (is (= ##-Inf (* ##Inf -1)))
  (is (= 0.0 (/ 1 ##Inf))))

;; *** Spec predicates (1.9) ***

(deftest test-pos-int?
  (is (true? (pos-int? 1)))
  (is (true? (pos-int? 42)))
  (is (false? (pos-int? 0)))
  (is (false? (pos-int? -1)))
  (is (false? (pos-int? 1.5)))
  (is (false? (pos-int? nil))))

(deftest test-neg-int?
  (is (true? (neg-int? -1)))
  (is (true? (neg-int? -42)))
  (is (false? (neg-int? 0)))
  (is (false? (neg-int? 1)))
  (is (false? (neg-int? -1.5)))
  (is (false? (neg-int? nil))))

(deftest test-nat-int?
  (is (true? (nat-int? 0)))
  (is (true? (nat-int? 1)))
  (is (true? (nat-int? 42)))
  (is (false? (nat-int? -1)))
  (is (false? (nat-int? 1.5)))
  (is (false? (nat-int? nil))))

(deftest test-double?
  (is (true? (double? 1.0)))
  (is (true? (double? 0.0)))
  (is (true? (double? -1.5)))
  (is (false? (double? 0)))
  (is (false? (double? 42)))
  (is (false? (double? nil)))
  (is (false? (double? "1.0"))))

(deftest test-NaN?-fn
  (is (true? (NaN? ##NaN)))
  (is (false? (NaN? 0)))
  (is (false? (NaN? 0.0)))
  (is (false? (NaN? 1.5)))
  (is (false? (NaN? ##Inf))))

(deftest test-infinite?-fn
  (is (true? (infinite? ##Inf)))
  (is (true? (infinite? ##-Inf)))
  (is (false? (infinite? 0)))
  (is (false? (infinite? 0.0)))
  (is (false? (infinite? 1.5)))
  (is (false? (infinite? ##NaN))))

(deftest test-int-coercion
  (is (= 3 (int 3.14)))
  (is (= 3 (int 3)))
  (is (= -2 (int -2.9)))
  (is (= 0 (int 0.5))))

(deftest test-long-coercion
  (is (= 3 (long 3.14)))
  (is (= 42 (long 42)))
  (is (= -1 (long -1.9))))

(deftest test-float-coercion
  (is (= 3.0 (float 3)))
  (is (= 3.14 (float 3.14)))
  (is (= 0.0 (float 0))))

(deftest test-double-coercion
  (is (= 3.0 (double 3)))
  (is (= 3.14 (double 3.14))))

(deftest test-num-coercion
  (is (= 42 (num 42)))
  (is (= 3.14 (num 3.14))))

(deftest test-short-byte-coercion
  (is (= 3 (short 3.7)))
  (is (= 255 (byte 255.9)))
  (is (= 0 (short 0)))
  (is (= 0 (byte 0))))

(deftest test-char-coercion
  (is (= \A (char 65)))
  (is (= \a (char 97)))
  (is (= \0 (char 48))))

;; Run all tests when executed directly
(run-tests)
