;; test/e2e/phase14_vector_keys.sh — vector keys compared/hashed BY VALUE
;; (D-092). Fixes `(frequencies [[1] [1] [2]])` → was {[1] 1, [1] 1, [2] 1}
;; (identity-keyed bug), now {[1] 2, [2] 1}. Unblocks vector-keyed maps,
;; group-by / distinct / set over vectors. (Lists / cross-type vec≡list
;; keys are a residual.)

;; Migrated from test/e2e/phase14_vector_keys.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.vector-keys-test
  (:require [clojure.test :refer [deftest is]]))

(deftest vector-keys-cases
  (is (= ":a" (pr-str (get {[1 2] :a} [1 2]))) "get")
  (is (= "true" (pr-str (contains? {[1 2] :a} [1 2]))) "contains")
  (is (= "nil" (pr-str (get {[1 2] :a} [1 3]))) "get_miss")
  (is (= "1" (pr-str (count (assoc {[1] :a} [1] :b)))) "assoc_rep")
  (is (= "2" (pr-str (get (frequencies [[1] [1] [2]]) [1]))) "freq")
  (is (= "2" (pr-str (count (frequencies [[1] [1] [2]])))) "freq_cnt")
  (is (= "2" (pr-str (count (distinct [[1] [1] [2] [2] [2]])))) "distinct")
  (is (= "2" (pr-str (count (set [[1] [1] [2]])))) "set")
  (is (= "true" (pr-str (contains? (set [[1] [2]]) [1]))) "set_in")
  (is (= ":x" (pr-str (get {[[1] 2] :x} [[1] 2]))) "nested")
  (is (= "7" (pr-str (get (into {} (map (fn [i] [[i] i]) (range 20))) [7]))) "hamt")
  (is (= "true" (pr-str (= (set [[1 2] [3 4]]) (set [[3 4] [1 2]])))) "distinct2"))
