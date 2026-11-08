;; Ratio literals wider than i64 (CLJW-BIG-RATIO-LITERAL).
;;
;; clj's reader reads each side of `n/d` as a Long when it fits one and as a
;; BigInt otherwise, then divides them with `Numbers.divide`, so a ratio literal
;; is exactly the value `(/ n d)` answers. Classes are compared as values, never
;; by printed name (AD-003). Every assertion here also holds under clj.
(ns suites.big-ratio-literal-test
  (:require [clojure.edn :as edn]
            [clojure.test :refer [deftest is testing]]))

(defn- same-number?
  "True when `a` and `b` are `=` and of one class."
  [a b]
  (and (= a b) (= (class a) (class b))))

(deftest collapse-divides
  (testing "den divides num: the value is the quotient, not the numerator"
    (is (same-number? 3 6/2))
    (is (same-number? -3 -6/2))
    (is (same-number? 0 0/5))
    (is (same-number? 3 (read-string "+6/2")))
    (is (same-number? 4 (read-string "08/2")))))

(deftest collapse-past-i48-stays-long
  (is (same-number? 18014398509481984 36028797018963968/2))
  (is (same-number? -18014398509481984 -36028797018963968/2))
  (is (same-number? 9223372036854775807 (read-string "9223372036854775807/1")))
  (is (same-number? -9223372036854775807 (read-string "-9223372036854775807/1"))))

(deftest collapse-past-i64-is-bigint
  (is (same-number? 17636684144620811271604938270N
                    (read-string "123456789012345678901234567890/7")))
  (is (same-number? -17636684144620811271604938270N
                    (read-string "-123456789012345678901234567890/7")))
  (is (same-number? 4611686018427387904N (read-string "36893488147419103232/8")))
  (is (same-number? 9223372036854775808N (read-string "9223372036854775808/1")))
  (testing "a BigInt operand makes a BigInt even when the quotient is small"
    (is (same-number? 1N (read-string "36893488147419103232/36893488147419103232"))))
  (testing "Long/MIN_VALUE takes the BigInt arm of the division"
    (is (same-number? -9223372036854775808N (read-string "-9223372036854775808/1")))
    (is (same-number? -4611686018427387904N (read-string "-9223372036854775808/2")))))

(deftest literal-is-the-division
  (testing "a ratio literal is the value `/` answers on the same two integers"
    (doseq [[s n d] [["6/2" 6 2]
                     ["4/6" 4 6]
                     ["36028797018963968/2" 36028797018963968 2]
                     ["-9223372036854775808/1" -9223372036854775808 1]
                     ["-9223372036854775808/2" -9223372036854775808 2]
                     ["-9223372036854775808/3" -9223372036854775808 3]
                     ["36893488147419103232/36893488147419103232"
                      36893488147419103232 36893488147419103232]
                     ["24691357802469135781/2" 24691357802469135781 2]]]
      (is (same-number? (/ n d) (read-string s)) s))))

(deftest divide-hands-long-min-to-bigint
  (testing "`/` with a Long/MIN_VALUE operand answers a BigInt, as clj's LongOps does"
    (is (same-number? -9223372036854775808N (/ -9223372036854775808 1)))
    (is (same-number? 9223372036854775808N (/ -9223372036854775808 -1)))
    (is (same-number? 1N (/ -9223372036854775808 -9223372036854775808)))
    (is (same-number? -9223372036854775807 (/ -9223372036854775807 1)))))

(deftest wide-ratio-reads
  (is (ratio? 24691357802469135781/2))
  (is (= "24691357802469135781/2" (pr-str 24691357802469135781/2)))
  (is (= "-24691357802469135781/2" (pr-str (read-string "-24691357802469135781/2"))))
  (is (= "1/24691357802469135781" (pr-str (read-string "1/24691357802469135781"))))
  (is (= "1/2" (pr-str (read-string "18446744073709551616/36893488147419103232"))))
  (is (= 24691357802469135781 (numerator 24691357802469135781/2)))
  (is (= 24691357802469135781 (denominator 1/24691357802469135781)))
  (is (same-number? 24691357802469135781N (* 2 24691357802469135781/2))))

(deftest round-trip
  (doseq [s ["24691357802469135781/2" "-24691357802469135781/2"
             "1/24691357802469135781" "3/4"]]
    (let [v (read-string s)]
      (is (= v (read-string (pr-str v))))
      (is (= s (pr-str v))))))

(deftest quoted-and-edn-paths
  (is (= "24691357802469135781/2" (pr-str '24691357802469135781/2)))
  (is (= "[18014398509481984 3]" (pr-str '[36028797018963968/2 6/2])))
  (is (= "24691357802469135781/2" (pr-str (edn/read-string "24691357802469135781/2"))))
  (is (same-number? 18014398509481984 (edn/read-string "36028797018963968/2")))
  (is (same-number? 17636684144620811271604938270N
                    (edn/read-string "123456789012345678901234567890/7")))
  (is (same-number? 3 (edn/read-string "6/2"))))

(defmacro ^:private wide-ratio [] (/ 24691357802469135781N 2))

(deftest macro-expansion-path
  (testing "a wide ratio a macro returns survives the trip back into code"
    (is (= 24691357802469135781/2 (wide-ratio)))
    (is (ratio? (wide-ratio)))))

(deftest zero-denominator-throws
  (is (thrown? ArithmeticException (read-string "1/0")))
  (is (thrown? ArithmeticException (read-string "24691357802469135781/0")))
  (is (thrown? ArithmeticException (edn/read-string "1/0"))))
