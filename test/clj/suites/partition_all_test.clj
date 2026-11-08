;; test/e2e/phase14_partition_all.sh
;;
;; D-134 — partition-all (lazy, keeps the final short partition; unlike
;; partition which drops it) + splitv-at (vector split-at). Pattern A
;; .clj over take/drop/lazy-seq (ride the AOT blob). Runs are realized
;; via mapv vec (nested lazy-seqs print as #<lazy_seq>, ADR-0054).

;; Migrated from test/e2e/phase14_partition_all.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.partition-all-test
  (:require [clojure.test :refer [deftest is]]))

(deftest partition-all-cases
  (is (= "[[1 2] [3 4] [5]]" (pr-str (mapv vec (partition-all 2 [1 2 3 4 5])))) "pa_partial")
  (is (= "[[1 2 3] [4 5 6]]" (pr-str (mapv vec (partition-all 3 [1 2 3 4 5 6])))) "pa_even")
  (is (= "3" (pr-str (count (partition-all 2 [1 2 3 4 5])))) "pa_count")
  (is (= "[[1 2] [5 6]]" (pr-str (mapv vec (partition-all 2 4 [1 2 3 4 5 6 7])))) "pa_step")
  (is (= "0" (pr-str (count (partition-all 2 [])))) "pa_empty")
  (is (= "[[1 2] (3 4 5)]" (pr-str (splitv-at 2 [1 2 3 4 5]))) "sv_at")
  (is (= "[[] (1 2 3)]" (pr-str (splitv-at 0 [1 2 3]))) "sv_zero")
  (is (= "[[1 2] ()]" (pr-str (splitv-at 9 [1 2]))) "sv_over"))
