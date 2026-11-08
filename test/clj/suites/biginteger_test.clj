;; clojure.core/biginteger and the BigInteger instance-method surface —
;; D-265 / D-514 / D-532, and the AD-016 divergence pin.
;;
;; cljw has NO separate java.math.BigInteger type: F-005 collapses clj's
;; `clojure.lang.BigInt` and `java.math.BigInteger` into one `.big_int`, so
;; `(biginteger x)` yields exactly what `(bigint x)` yields. That is an
;; ACCEPTED divergence (AD-016), and the first deftest below is its pin — if a
;; future change makes cljw match clj here, or diverge differently, it fails
;; and forces a conscious decision rather than a silent drift.
;;
;; Every assertion whose expected value carries the `N` suffix compares the
;; PRINTED form on purpose. `N` is the type claim, and `=` erases it —
;; `(= 7 7N)` is true — so a value assertion could not tell a BigInt result
;; from a Long one, which is the whole point of these cases.
;;
;; Migrated from test/e2e/phase14_biginteger.sh; each assertion keeps its bash
;; case name.
(ns suites.biginteger-test
  (:require [clojure.test :refer [deftest is testing]]))

;; AD-016 PIN — cljw's intentional value, NOT clj's
(deftest biginteger-is-bigint-the-ad-016-divergence
  (testing "clj prints 5; cljw prints 5N, because it IS a BigInt"
    (is (= "5N" (pr-str (biginteger 5)))))                      ; biginteger_prints_N
  (testing "and clj's class is java.math.BigInteger; cljw's is BigInt"
    (is (= "BigInt" (pr-str (class (biginteger 5))))))          ; biginteger_class_bigint
  (testing "a genuinely-large value past i64 collapses the same way"
    (is (= "999999999999999999999N" (pr-str (biginteger "999999999999999999999"))))) ; biginteger_large_prints_N
  (testing "and it truncates toward zero like bigint, still printing N"
    (is (= "3N" (pr-str (biginteger 3.9))))))                   ; biginteger_truncates_float

(deftest the-unary-and-number-theoretic-methods
  (is (= "7N" (pr-str (.abs (biginteger -7)))))                        ; bi_abs
  (is (= "-7N" (pr-str (.negate (biginteger 7)))))                     ; bi_negate
  (testing "signum is a plain int, so it has no N"
    (is (= -1 (.signum (biginteger -3)))))                             ; bi_signum
  (is (= "4N" (pr-str (.gcd (biginteger 12) (biginteger 8)))))         ; bi_gcd
  (is (= "1024N" (pr-str (.pow (biginteger 2) 10))))                   ; bi_pow
  (is (= "2N" (pr-str (.mod (biginteger 17) (biginteger 5)))))         ; bi_mod
  (testing ".mod is the FLOORED remainder, so a negative dividend stays positive"
    (is (= "3N" (pr-str (.mod (biginteger -17) (biginteger 5))))))     ; bi_mod_neg
  (testing "and .sqrt is the integer floor sqrt"
    (is (= "4N" (pr-str (.sqrt (biginteger 17)))))))                   ; bi_sqrt

(deftest the-arithmetic-methods
  (is (= "13N" (pr-str (.add (biginteger 10) (biginteger 3)))))        ; bi_add
  (is (= "7N" (pr-str (.subtract (biginteger 10) (biginteger 3)))))    ; bi_subtract
  (is (= "30N" (pr-str (.multiply (biginteger 10) (biginteger 3)))))   ; bi_multiply
  (is (= "3N" (pr-str (.divide (biginteger 7) (biginteger 2)))))       ; bi_divide
  (testing ".divide truncates toward zero — -7/2 is -3, not floor's -4"
    (is (= "-3N" (pr-str (.divide (biginteger -7) (biginteger 2)))))))  ; bi_divide_neg

(deftest the-domain-errors-raise-rather-than-return-a-sentinel
  (is (thrown? Throwable (.divide (biginteger 1) (biginteger 0))))     ; bi_divide_zero
  (is (thrown? Throwable (.sqrt (biginteger -1)))))                    ; bi_sqrt_neg

(deftest modpow-and-bitlength
  (is (= "1N" (pr-str (.modPow (biginteger 3) (biginteger 4) (biginteger 5)))))        ; bi_modpow
  (is (= "24N" (pr-str (.modPow (biginteger 2) (biginteger 10) (biginteger 1000)))))   ; bi_modpow2
  (is (= "1N" (pr-str (.modPow (biginteger -3) (biginteger 3) (biginteger 7)))))       ; bi_modpow_neg
  (testing "square-and-multiply, not a materialised power"
    (is (= "652541198N" (pr-str (.modPow (biginteger 123456789)
                                         (biginteger 987654321)
                                         (biginteger 1000000007))))))                 ; bi_modpow_big
  (is (= 8 (.bitLength (biginteger 255))))                             ; bi_bitlen
  (is (= 9 (.bitLength (biginteger 256))))                             ; bi_bitlen2
  (is (= 0 (.bitLength (biginteger 0))))                               ; bi_bitlen0
  (testing "bitLength is of the MAGNITUDE, excluding the sign bit"
    (is (= 8 (.bitLength (biginteger -256))))))                        ; bi_bitlen_neg

;; deterministic Miller-Rabin — 561 is a Carmichael number, which a naive
;; Fermat test would call prime
(deftest is-probable-prime
  (is (true? (.isProbablePrime (biginteger 2) 20)))                    ; bi_prime_2
  (is (true? (.isProbablePrime (biginteger 97) 20)))                   ; bi_prime_97
  (is (false? (.isProbablePrime (biginteger 4) 20)))                   ; bi_prime_4
  (is (false? (.isProbablePrime (biginteger 561) 20)))                 ; bi_prime_561
  (is (true? (.isProbablePrime (biginteger 7919) 20)))                 ; bi_prime_7919
  (is (true? (.isProbablePrime (biginteger 1000003) 20)))              ; bi_prime_1m3
  (is (false? (.isProbablePrime (biginteger 1000004) 20)))             ; bi_prime_1m4
  (is (false? (.isProbablePrime (biginteger 0) 20))))                  ; bi_prime_0
