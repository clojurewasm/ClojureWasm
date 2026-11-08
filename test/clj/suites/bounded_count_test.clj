;; test/e2e/phase14_bounded_count.sh — bounded-count: FULL count for a counted?
;; coll (clj parity — a vector/range is O(1) counted, n is ignored); else walk at
;; most n (terminates on infinite seqs). Pattern A .clj loop, AOT blob.

;; Migrated from test/e2e/phase14_bounded_count.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.bounded-count-test
  (:require [clojure.test :refer [deftest is]]))

(deftest bounded-count-cases
  (is (= "5" (pr-str (bounded-count 3 [1 2 3 4 5]))) "bc_counted")
  (is (= "3" (pr-str (bounded-count 10 [1 2 3]))) "bc_full")
  (is (= "3" (pr-str (bounded-count 0 [1 2 3]))) "bc_zero_n")
  (is (= "0" (pr-str (bounded-count 5 []))) "bc_empty")
  (is (= "3" (pr-str (bounded-count 3 (map inc (range 100))))) "bc_lazy")
  (is (= "4" (pr-str (bounded-count 4 (range)))) "bc_inf"))
