;; The BigDecimal interop surface — D-097 / D-420 / D-511 / ADR-0160.
;;
;; `bigdec` values carry a SCALE, and almost every assertion here is really
;; about that scale surviving an operation: `.setScale` rounds under an
;; explicit mode, `.multiply` adds the operand scales, `.stripTrailingZeros`
;; removes them, and `.equals` is scale-SENSITIVE where `=` and `.compareTo`
;; are not. Expected values are the `clj` oracle (java.math.BigDecimal).
;;
;; Assertions compare the PRINTED form (`str`) wherever the bash script did,
;; because that is what discriminates scale: `1.0M` and `1.00M` are `=` and
;; compare 0, so a value assertion could not tell them apart.
;;
;; Two rounding-mode vocabularies are both live: the deprecated
;; `BigDecimal/ROUND_*` ints and the `java.math.RoundingMode` host-enum
;; singletons (ADR-0160). `.setScale` and `.divide` accept either.
;;
;; Migrated from test/e2e/phase14_bigdecimal_setscale.sh; each assertion keeps
;; its bash case name.
(ns suites.bigdecimal-test
  (:require [clojure.test :refer [deftest is testing]]))

;; the ROUND_* ints resolve as static fields, in JVM ordinal order
(deftest the-round-constants-resolve-as-static-fields
  (is (= [0 1 2 3 4 5 6 7]
         [BigDecimal/ROUND_UP BigDecimal/ROUND_DOWN
          BigDecimal/ROUND_CEILING BigDecimal/ROUND_FLOOR
          BigDecimal/ROUND_HALF_UP BigDecimal/ROUND_HALF_DOWN
          BigDecimal/ROUND_HALF_EVEN BigDecimal/ROUND_UNNECESSARY]))) ; round_const

;; setScale to 0 — the rounding-mode matrix against the clj oracle
(deftest setscale-to-zero-rounds-per-mode
  (is (= "3" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_HALF_UP))))     ; half_up_2.5
  (is (= "2" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_HALF_DOWN))))   ; half_down_2.5
  (is (= "2" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_HALF_EVEN))))   ; half_even_2.5
  (testing "HALF_EVEN breaks the tie toward the even neighbour, so 3.5 goes UP"
    (is (= "4" (str (.setScale (bigdec "3.5") 0 BigDecimal/ROUND_HALF_EVEN))))) ; half_even_3.5
  (is (= "2" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_FLOOR))))       ; floor_2.5
  (is (= "3" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_CEILING))))     ; ceiling_2.5
  (is (= "2" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_DOWN))))        ; down_2.5
  (is (= "3" (str (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_UP))))          ; up_2.5
  (is (= "2" (str (.setScale (bigdec "2.4") 0 BigDecimal/ROUND_HALF_UP)))))    ; half_up_2.4

;; FLOOR is toward -inf and CEILING toward +inf, so on a negative value they
;; swap places with DOWN / UP (which are toward and away from zero)
(deftest the-directional-modes-are-defined-by-the-number-line-not-by-zero
  (is (= "-3" (str (.setScale (bigdec "-2.5") 0 BigDecimal/ROUND_FLOOR))))     ; floor_neg2.5
  (is (= "-2" (str (.setScale (bigdec "-2.5") 0 BigDecimal/ROUND_CEILING))))   ; ceiling_neg2.5
  (is (= "-3" (str (.setScale (bigdec "-2.5") 0 BigDecimal/ROUND_UP))))        ; up_neg2.5
  (is (= "-2" (str (.setScale (bigdec "-2.5") 0 BigDecimal/ROUND_DOWN))))      ; down_neg2.5
  (is (= "-3" (str (.setScale (bigdec "-2.5") 0 BigDecimal/ROUND_HALF_UP)))))  ; half_up_neg2.5

;; a newScale at or above the current one is an exact pad — no rounding, and
;; the added trailing zeros are kept
(deftest widening-the-scale-pads-exactly
  (is (= "1.500" (str (.setScale (bigdec "1.5") 3 BigDecimal/ROUND_FLOOR))))          ; pad_1.5_to_3
  (is (= "2" (str (.setScale (bigdec "2.00") 0 BigDecimal/ROUND_UNNECESSARY))))       ; exact_2.50_to_0
  (testing "UNNECESSARY refuses to round rather than rounding silently"
    (is (thrown? Throwable (.setScale (bigdec "2.5") 0 BigDecimal/ROUND_UNNECESSARY))))) ; unnecessary_throws

;; the 2-arg form is JVM setScale(int) = ROUND_UNNECESSARY
(deftest two-arg-setscale-rescales-exactly-or-throws
  (is (= "1.500" (str (.setScale (bigdec "1.5") 3))))                          ; 2arg_pad
  (is (= "1.5" (str (.setScale (bigdec "1.500") 1))))                          ; 2arg_exact
  (is (thrown? Throwable (.setScale (bigdec "1.55") 1))))                      ; 2arg_unnecessary_throws

(deftest the-read-accessors
  (is (= 2 (.scale (bigdec "1.23"))))                       ; scale
  (is (= -1 (.signum (bigdec "-1.5"))))                     ; signum_neg
  (is (= 0 (.signum (bigdec "0.00"))))                      ; signum_zero
  (is (= "123" (str (.unscaledValue (bigdec "1.23")))))     ; unscaled
  (is (= 5 (.precision (bigdec "123.45"))))                 ; precision
  (testing "zero has precision 1 whatever its scale"
    (is (= 1 (.precision (bigdec "0.00"))))))               ; precision_zero

(deftest the-value-transformers
  (is (= "-1.5" (str (.negate (bigdec "1.5")))))            ; negate
  (is (= "1.5" (str (.abs (bigdec "-1.5")))))               ; abs_neg
  (is (= "1.5" (str (.abs (bigdec "1.5")))))                ; abs_pos
  (is (= "1" (str (.toBigInteger (bigdec "1.99")))))        ; tobigint
  (is (= "-1" (str (.toBigInteger (bigdec "-1.99")))))      ; tobigint_neg
  (is (= "1.5" (str (.stripTrailingZeros (bigdec "1.500"))))) ; strip
  (testing "stripping an integer's zeros yields a negative scale, so it prints scientific"
    (is (= "1E+2" (str (.stripTrailingZeros (bigdec "100")))))))  ; strip_e

(deftest instance-arithmetic-and-point-shift
  (is (= "3.3" (str (.add (bigdec "1.1") (bigdec "2.2")))))               ; bd_add
  (is (= "4.4" (str (.subtract (bigdec "5.5") (bigdec "1.1")))))          ; bd_subtract
  (testing "multiply ADDS the operand scales"
    (is (= "6.00" (str (.multiply (bigdec "2.0") (bigdec "3.0"))))))      ; bd_multiply
  (is (= "2.5" (str (.divide (bigdec "10") (bigdec "4")))))               ; bd_divide
  (is (= "1.50" (str (.movePointLeft (bigdec "150") 2))))                 ; bd_mpl
  (is (= "150" (str (.movePointRight (bigdec "1.5") 2))))                 ; bd_mpr
  (is (= "12340" (str (.movePointRight (bigdec "12.34") 3))))             ; bd_mpr_big
  (testing "the no-mode divide is EXACT, so a non-terminating quotient throws"
    (is (thrown? Throwable (.divide (bigdec "1") (bigdec "3"))))))        ; bd_div_nonterm

;; ADR-0160 — java.math.RoundingMode constants are host-enum singletons, not
;; the deprecated ints. Only their opaque print form diverges (AD-002).
(deftest the-roundingmode-enum-constants
  (is (= ["UP" "DOWN" "CEILING" "FLOOR" "HALF_UP" "HALF_DOWN" "HALF_EVEN" "UNNECESSARY"]
         (mapv str [java.math.RoundingMode/UP java.math.RoundingMode/DOWN
                    java.math.RoundingMode/CEILING java.math.RoundingMode/FLOOR
                    java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_DOWN
                    java.math.RoundingMode/HALF_EVEN java.math.RoundingMode/UNNECESSARY]))) ; rm_names
  (testing "the class is the enum class, NOT Long — the int-ordinal anti-pattern"
    (is (= "java.math.RoundingMode" (pr-str (class java.math.RoundingMode/HALF_UP))))) ; rm_class
  (is (true? (= java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_UP)))       ; rm_eq
  (testing "and an enum is never = to its int ordinal"
    (is (false? (= java.math.RoundingMode/HALF_UP 4)))))                               ; rm_eq_int

(deftest setscale-takes-a-roundingmode-enum-too
  (is (= "3.14" (str (.setScale (bigdec "3.14159") 2 java.math.RoundingMode/HALF_UP)))) ; rm_setscale
  (is (= "2" (str (.setScale (bigdec "2.5") 0 java.math.RoundingMode/FLOOR))))          ; rm_floor
  (is (= "3" (str (.setScale (bigdec "2.5") 0 java.math.RoundingMode/CEILING))))        ; rm_ceiling
  (is (= "2" (str (.setScale (bigdec "2.5") 0 java.math.RoundingMode/HALF_EVEN))))      ; rm_half_even
  (is (= "-3" (str (.setScale (bigdec "-2.5") 0 java.math.RoundingMode/UP)))))          ; rm_up_neg

(deftest rounding-division-takes-either-vocabulary
  (is (= "3.33" (str (.divide (bigdec "10") (bigdec "3") 2 java.math.RoundingMode/HALF_UP)))) ; div_scale_mode
  (is (= "3" (str (.divide (bigdec "10") (bigdec "4") java.math.RoundingMode/HALF_UP))))      ; div_mode
  (is (= "3.33" (str (.divide (bigdec "10") (bigdec "3") 2 BigDecimal/ROUND_HALF_UP)))))      ; div_mode_int

(deftest pow-remainder-and-integral-division
  (is (= "1024" (str (.pow (bigdec "2") 10))))                                ; bd_pow
  (is (= "1" (str (.pow (bigdec "5") 0))))                                    ; bd_pow0
  (is (= "1" (str (.remainder (bigdec "10") (bigdec "3")))))                  ; bd_remainder
  (is (= "1.5" (str (.remainder (bigdec "10.5") (bigdec "3")))))              ; bd_rem_scale
  (testing "the remainder takes the DIVIDEND's sign"
    (is (= "-1" (str (.remainder (bigdec "-10") (bigdec "3"))))))             ; bd_rem_neg
  (testing "an exact division still leaves the operand scale on the zero"
    (is (= "0.0" (str (.remainder (bigdec "7.5") (bigdec "2.5"))))))          ; bd_rem_zero
  (is (= "3" (str (.divideToIntegralValue (bigdec "10") (bigdec "3")))))      ; bd_divint
  (is (= "3.0" (str (.divideToIntegralValue (bigdec "10.5") (bigdec "3")))))) ; bd_divint_sc

;; D-439 — scaleByPowerOfTen is a PURE scale shift: unlike movePoint* it keeps
;; a negative result-scale, so a shifted integer prints scientific
(deftest scale-by-power-of-ten-ulp-and-divide-and-remainder
  (is (= "123" (str (.scaleByPowerOfTen (bigdec "1.23") 2))))       ; bd_sbpt
  (is (= "0.123" (str (.scaleByPowerOfTen (bigdec "1.23") -1))))    ; bd_sbpt_neg
  (is (= "1.2E+4" (str (.scaleByPowerOfTen (bigdec "12") 3))))      ; bd_sbpt_sci
  (testing "ulp is an unscaled 1 at the receiver's scale"
    (is (= "0.01" (str (.ulp (bigdec "1.23")))))                    ; bd_ulp
    (is (= "1" (str (.ulp (bigdec "100")))))                        ; bd_ulp_int
    (is (= "0.1" (str (.ulp (bigdec "12.0"))))))                    ; bd_ulp_one
  (testing "divideAndRemainder returns both halves in one array"
    (is (= "[3M 2M]" (str (vec (.divideAndRemainder (bigdec "17") (bigdec "5"))))))        ; bd_divrem
    (is (= "[4M 0.7M]" (str (vec (.divideAndRemainder (bigdec "17.5") (bigdec "4.2")))))))) ; bd_divrem_sc

(deftest comparison-is-by-value-but-equals-is-by-scale
  (is (= "2" (str (.max (bigdec "1") (bigdec "2")))))       ; bd_max
  (is (= "1" (str (.min (bigdec "1") (bigdec "2")))))       ; bd_min
  (is (= 0 (.compareTo (bigdec "1.0") (bigdec "1.00"))))    ; bd_compareto_eq
  (is (= 1 (.compareTo (bigdec "2") (bigdec "1"))))         ; bd_compareto_gt
  (is (= -1 (.compareTo (bigdec "1") (bigdec "2"))))        ; bd_compareto_lt
  (testing "1.0 and 1.00 compare 0 yet are NOT .equals — they differ in scale"
    (is (false? (.equals (bigdec "1.0") (bigdec "1.00"))))  ; bd_equals_scale
    (is (true? (.equals (bigdec "1.0") (bigdec "1.0"))))))  ; bd_equals_same

(deftest the-primitive-narrowing-accessors-truncate
  (is (= 42 (.intValue (bigdec "42.9"))))       ; bd_intvalue
  (is (= 42 (.longValue (bigdec "42.9"))))      ; bd_longvalue
  (is (= 1.5 (.doubleValue (bigdec "1.5")))))   ; bd_doublevalue

;; D-511 — java.math.MathContext pairs a PRECISION (significant digits) with a
;; rounding mode, where setScale takes a SCALE (digits after the point)
(deftest mathcontext-rounds-to-a-precision
  (is (= "123.5" (str (.round (bigdec "123.456") (java.math.MathContext. 4)))))                              ; mc_round
  (is (= "123.4" (str (.round (bigdec "123.456") (java.math.MathContext. 4 java.math.RoundingMode/FLOOR))))) ; mc_round_mode
  (testing "a carry can shorten the result past the requested precision"
    (is (= "10" (str (.round (bigdec "9.95") (java.math.MathContext. 2))))))                                 ; mc_round_carry
  (testing "and it makes a non-terminating divide terminate"
    (is (= "0.33333" (str (.divide (bigdec "1") (bigdec "3") (java.math.MathContext. 5)))))                   ; mc_divide
    (is (= "3.3" (str (.divide (bigdec "10") (bigdec "3")
                               (java.math.MathContext. 2 java.math.RoundingMode/FLOOR)))))))                  ; mc_div_mode

(deftest a-mathcontext-reports-its-own-settings
  (is (= 7 (.getPrecision (java.math.MathContext. 7))))                        ; mc_precision
  (is (= "HALF_UP" (str (.getRoundingMode (java.math.MathContext. 7)))))       ; mc_mode
  (is (= "precision=4 roundingMode=HALF_UP" (str (java.math.MathContext. 4)))) ; mc_tostr
  (is (= "precision=4 roundingMode=FLOOR"
         (str (java.math.MathContext. 4 java.math.RoundingMode/FLOOR)))))      ; mc_tostr_mode

(deftest the-standard-mathcontext-constants
  (is (= "precision=16 roundingMode=HALF_EVEN" (str java.math.MathContext/DECIMAL64))) ; mc_decimal64
  (is (= 7 (.getPrecision java.math.MathContext/DECIMAL32)))                           ; mc_decimal32
  (is (= 34 (.getPrecision java.math.MathContext/DECIMAL128)))                         ; mc_decimal128
  (testing "UNLIMITED is precision 0 — the mode never fires"
    (is (= "precision=0 roundingMode=HALF_UP" (str java.math.MathContext/UNLIMITED)))) ; mc_unlimited
  (is (= "0.3333333" (str (.divide (bigdec "1") (bigdec "3") java.math.MathContext/DECIMAL32))))) ; mc_dec_round

(deftest the-string-and-int-constructors
  (is (= "1.5" (str (java.math.BigDecimal. "1.5"))))         ; ctor_str
  (is (= "3.14159" (str (java.math.BigDecimal. "3.14159")))) ; ctor_str2
  (is (= "5" (str (java.math.BigDecimal. 5))))               ; ctor_int
  (testing "the result is a real scale-bearing BigDecimal"
    (is (= "3" (str (.setScale (java.math.BigDecimal. "2.5") 0 java.math.RoundingMode/HALF_UP)))))) ; ctor_use

(deftest the-two-arg-ctor-rounds-on-construct
  (is (= "3.14" (str (java.math.BigDecimal. "3.14159" (java.math.MathContext. 3)))))          ; ctor_mc
  (is (= "3.14159" (str (java.math.BigDecimal. "3.14159" java.math.MathContext/DECIMAL32))))  ; ctor_mc_id
  (is (= "1.23E+4" (str (java.math.BigDecimal. 12345 (java.math.MathContext. 3)))))           ; ctor_mc_int
  (is (= "10" (str (java.math.BigDecimal. "9.95" (java.math.MathContext. 2)))))               ; ctor_mc_carry
  (is (= "123.4" (str (java.math.BigDecimal. "123.456"
                                             (java.math.MathContext. 4 java.math.RoundingMode/FLOOR))))) ; ctor_mc_mode
  (is (= "3.14159" (str (java.math.BigDecimal. "3.14159" java.math.MathContext/UNLIMITED))))) ; ctor_mc_unlim

;; D-511 — (BigDecimal. double) is the EXACT binary value, not `bigdec`'s
;; shortest round-trip. This is the JVM footgun, reproduced deliberately.
(deftest the-double-ctor-is-exact-not-shortest-round-trip
  (is (= "0.1000000000000000055511151231257827021181583404541015625"
         (str (java.math.BigDecimal. 0.1))))                        ; bd_dbl_tenth
  (is (= "-0.1000000000000000055511151231257827021181583404541015625"
         (str (java.math.BigDecimal. -0.1))))                       ; bd_dbl_neg
  (testing "a value that IS exact in binary stays short"
    (is (= "0.5" (str (java.math.BigDecimal. 0.5))))               ; bd_dbl_half
    (is (= "2" (str (java.math.BigDecimal. 2.0))))                 ; bd_dbl_two
    (is (= "100" (str (java.math.BigDecimal. 100.0))))             ; bd_dbl_hundred
    (is (= "0" (str (java.math.BigDecimal. 0.0)))))                ; bd_dbl_zero
  (is (= 55 (.scale (java.math.BigDecimal. 0.1))))                 ; bd_dbl_scale
  (testing "a non-finite double has no decimal expansion at all"
    (is (thrown? Throwable (java.math.BigDecimal. (/ 1.0 0.0)))))) ; bd_dbl_inf
