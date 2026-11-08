;; test/e2e/phase14_dedup_group.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 3 (unblocked by D-136 universal
;; `=`). dedupe / distinct / frequencies / group-by. Pattern A over reduce
;; / conj / assoc / get(3-arg) / some / =. distinct uses `=` linear scan
;; (structural, so strings dedupe); frequencies/group-by key via map
;; assoc/get (bit-pattern keyEq → number/keyword keys; structural keys
;; await D-092).
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_dedup_group.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.dedup-group-test
  (:require [clojure.test :refer [deftest is]]))

(deftest dedup-group-cases
  (is (= "[1 2 3 1]" (pr-str (into [] (dedupe [1 1 2 2 3 1])))) "dedupe_runs")
  (is (= "[1 2 3]" (pr-str (into [] (distinct [1 2 1 3 2])))) "distinct_int")
  (is (= "5000" (pr-str (count (dedupe (range 5000))))) "dedupe_large")
  (is (= "2000" (pr-str (count (distinct (concat (range 2000) (range 2000)))))) "distinct_large")
  (is (= "[\"a\" \"b\"]" (pr-str (into [] (distinct ["a" "b" "a"])))) "distinct_str")
  (is (= "2" (pr-str (get (frequencies [1 1 2]) 1))) "frequencies_int")
  (is (= "2" (pr-str (get (frequencies [:a :a :b]) :a))) "frequencies_kw")
  (is (= "[2 4]" (pr-str (into [] (get (group-by (fn* [x] (rem x 2)) [1 2 3 4]) 0)))) "group_by_even")
  (is (= "(1 2 1)" (pr-str (dedupe [1 1 2 2 1]))) "dedupe_seq")
  (is (= "(1 2 3)" (pr-str (distinct [1 1 2 3 3]))) "distinct_seq")
  (is (= "true" (pr-str (seq? (distinct [1 2])))) "distinct_isseq"))
