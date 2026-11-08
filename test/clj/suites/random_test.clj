;; test/e2e/phase14_random.sh
;;
;; ADR-0106 / D-289 — java.util.Random as a stateful native instance
;; (host_instance general container). A seeded `(java.util.Random. n)` reproduces
;; the JVM 48-bit-LCG sequence (F-011) so clojure.data.generators / test.check are
;; deterministic. Oracle-confirmed values (seed 42, fresh generator per method).

;; Migrated from test/e2e/phase14_random.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.random-test
  (:require [clojure.test :refer [deftest is]]))

(deftest random-cases
  (is (= "-1170105035" (pr-str (.nextInt (java.util.Random. 42)))) "nextInt")
  (is (= "-5025562857975149833" (pr-str (.nextLong (java.util.Random. 42)))) "nextLong")
  (is (= "0.7275636800328681" (pr-str (.nextDouble (java.util.Random. 42)))) "nextDouble")
  (is (= "true" (pr-str (.nextBoolean (java.util.Random. 42)))) "nextBoolean")
  (is (= "30" (pr-str (.nextInt (java.util.Random. 42) 100))) "nextInt_100")
  (is (= "360" (pr-str (.nextInt (java.util.Random. 0) 1000))) "seed0_int1000")
  (is (= "[-1170105035 234785527 -1360544799]" (pr-str (let [r (java.util.Random. 42)] [(.nextInt r) (.nextInt r) (.nextInt r)]))) "nextInt_seq")
  (is (= "-1170105035" (pr-str (let [r (java.util.Random. 1)] (.nextInt r) (.setSeed r 42) (.nextInt r)))) "setSeed")
  (is (= "true" (pr-str (integer? (.nextLong (java.util.Random. 42))))) "nextLong_is_long")
  (is (= "java.util.Random" (pr-str (class (java.util.Random. 0)))) "class")
  (is (= "true" (pr-str (instance? java.util.Random (java.util.Random. 0)))) "instance_pos")
  (is (= "false" (pr-str (instance? java.util.Random 5))) "instance_neg")
  (is (= "\"#<java.util.Random>\"" (pr-str (pr-str (java.util.Random. 0)))) "print_opaque")
  (is (= "true" (pr-str (let [n (.nextInt (java.util.Random.) 10)] (and (>= n 0) (< n 10))))) "0arg_in_range"))
