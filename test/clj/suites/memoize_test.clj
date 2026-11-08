;; test/e2e/phase14_memoize.sh — memoize (atom-backed cache keyed by
;; (vec args); unblocked by D-092 vector-key value equality).

;; Migrated from test/e2e/phase14_memoize.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.memoize-test
  (:require [clojure.test :refer [deftest is]]))

(deftest memoize-cases
  (is (= "6" (pr-str ((memoize inc) 5))) "basic")
  (is (= "[3 3]" (pr-str (let [f (memoize +)] [(f 1 2) (f 1 2)]))) "multi")
  (is (= "[9 1]" (pr-str (let [n (atom 0) f (memoize (fn [x] (swap! n inc) (* x x)))] (f 3) (f 3) [(f 3) @n]))) "cached")
  (is (= "2" (pr-str (let [n (atom 0) f (memoize (fn [x] (swap! n inc) x))] (f 1) (f 2) (f 1) @n))) "distinct")
  (is (= "1" (pr-str (let [n (atom 0) f (memoize (fn [] (swap! n inc)))] (f) (f) @n))) "zeroarg"))
