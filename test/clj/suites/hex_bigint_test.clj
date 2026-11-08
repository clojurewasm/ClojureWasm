;; test/e2e/phase14_hex_bigint.sh
;;
;; D-297 — a hex integer literal whose magnitude exceeds i64 auto-promotes to
;; BigInt, matching clj (which reads the literal's unsigned magnitude:
;; 0xffffffffffffffff => 18446744073709551615N, NOT -1). Decimal already
;; promoted; this routes hex overflow through the same base-N mul/add BigInt path.
;; Needed by hashing / RNG / crypto libs (test.check splitmix uses 0xbf58…).

;; Migrated from test/e2e/phase14_hex_bigint.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.hex-bigint-test
  (:require [clojure.test :refer [deftest is]]))

(deftest hex-bigint-cases
  (is (= "255" (pr-str 0xff)) "hex_small")
  (is (= "9223372036854775807" (pr-str 0x7fffffffffffffff)) "hex_i64_max")
  (is (= "13787848793156543929N" (pr-str 0xbf58476d1ce4e5b9)) "hex_splitmix")
  (is (= "18446744073709551615N" (pr-str 0xffffffffffffffff)) "hex_u64_max")
  (is (= "-13787848793156543929N" (pr-str -0xbf58476d1ce4e5b9)) "hex_neg_big")
  (is (= "18446744073709551616N" (pr-str (+ 0xffffffffffffffff 1))) "hex_big_arith")
  (is (= "true" (pr-str (integer? 0xbf58476d1ce4e5b9))) "hex_big_integer?"))
