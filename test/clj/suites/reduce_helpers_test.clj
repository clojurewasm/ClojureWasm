;; test/e2e/phase14_reduce_helpers.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 5. max-key / min-key /
;; flatten / reductions. Pattern A over reduce / conj / last / into /
;; sequential? / >= / <=. (sort/sort-by deferred — need a compare op +
;; sort algorithm.) reductions is the 3-arg [f init coll] form.
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_reduce_helpers.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.reduce-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest reduce-helpers-cases
  (is (= "[1 2 3]" (pr-str (max-key count [1] [1 2 3] [1 2]))) "max_key")
  (is (= "[1]" (pr-str (min-key count [1 2 3] [1] [1 2]))) "min_key")
  (is (= "[1 2 3 4 5]" (pr-str (into [] (flatten [1 [2 [3 4]] 5])))) "flatten")
  (is (= "[1 2 3]" (pr-str (into [] (flatten [1 2 3])))) "flatten_flat")
  (is (= "(1 2 3)" (pr-str (flatten [1 [2] 3]))) "flatten_seq")
  (is (= "true" (pr-str (seq? (flatten [1 2])))) "flatten_isseq")
  (is (= "[0 1 3 6]" (pr-str (into [] (reductions + 0 [1 2 3])))) "reductions"))
