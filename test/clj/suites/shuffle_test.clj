;; test/e2e/phase14_shuffle.sh — D-134 shuffle (Fisher-Yates random permutation
;; -> vector). Non-deterministic, so assertions are permutation invariants.

;; Migrated from test/e2e/phase14_shuffle.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.shuffle-test
  (:require [clojure.test :refer [deftest is]]))

(deftest shuffle-cases
  (is (= "(1 2 3 4 5)" (pr-str (sort (shuffle [3 1 2 5 4])))) "sh_perm")
  (is (= "true" (pr-str (= (set (shuffle [:a :b :c])) #{:a :b :c}))) "sh_set")
  (is (= "7" (pr-str (count (shuffle [1 2 3 4 5 6 7])))) "sh_count")
  (is (= "[42]" (pr-str (shuffle [42]))) "sh_single")
  (is (= "[]" (pr-str (shuffle []))) "sh_empty")
  (is (= "true" (pr-str (vector? (shuffle (list 1 2 3))))) "sh_vector"))
