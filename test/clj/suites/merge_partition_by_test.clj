;; test/e2e/phase14_merge_partition_by.sh
;;
;; D-134 missing-core batch — merge-with + partition-by. Pattern A `.clj`.
;; partition-by runs are realized via `mapv vec` for the assertion (the
;; runs are take-while lazy_seqs; nested lazy-seqs print as #<lazy_seq>,
;; ADR-0054). partition-by uses a lazy_seq run (NOT a raw cons-onto-lazy,
;; which would mis-count — D-153).

;; Migrated from test/e2e/phase14_merge_partition_by.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.merge-partition-by-test
  (:require [clojure.test :refer [deftest is]]))

(deftest merge-partition-by-cases
  (is (= "{:a 1, :b 5, :c 4}" (pr-str (merge-with + {:a 1 :b 2} {:b 3 :c 4}))) "mw_overlap")
  (is (= "{:x 16}" (pr-str (merge-with + {:x 10} {:x 5} {:x 1}))) "mw_combine3")
  (is (= "{:a 1, :b 2}" (pr-str (merge-with + {:a 1} {:b 2}))) "mw_no_overlap")
  (is (= "{:a 3}" (pr-str (merge-with + {:a 1} nil {:a 2}))) "mw_nil_skip")
  (is (= "[[1 1] [2 2] [3 3]]" (pr-str (mapv vec (partition-by odd? [1 1 2 2 3 3])))) "pb_runs")
  (is (= "[[1 1 1]]" (pr-str (mapv vec (partition-by identity [1 1 1])))) "pb_single")
  (is (= "[[1 2] [3 4] [1]]" (pr-str (mapv vec (partition-by (fn* [x] (> x 2)) [1 2 3 4 1])))) "pb_alt")
  (is (= "3" (pr-str (count (partition-by odd? [1 1 2 2 3 3])))) "pb_count")
  (is (= "((1 1) (2 2) (3))" (pr-str (partition-by odd? [1 1 2 2 3]))) "pb_print")
  (is (= "[(1 1) (2 2) (3)]" (pr-str (into [] (partition-by odd? [1 1 2 2 3])))) "pb_into_print")
  (is (= "[(1 2) (3 4)]" (pr-str (split-at 2 [1 2 3 4]))) "split_print"))
