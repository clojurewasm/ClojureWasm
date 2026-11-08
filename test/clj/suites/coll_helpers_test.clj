;; test/e2e/phase14_coll_helpers.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 1. High-frequency clojure.core
;; collection helpers that a 2026-05-29 probe found missing: update / vec /
;; mapv / filterv / reverse / last. Pure Pattern A eager defns over
;; reduce / conj / assoc / get / into / apply (no lazy-seq dependency).
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_coll_helpers.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.coll-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest coll-helpers-cases
  (is (= "[:a]" (pr-str (vec (keys {:a 1})))) "vec_coerce")
  (is (= "[2 3 4]" (pr-str (mapv inc [1 2 3]))) "mapv_inc")
  (is (= "[11 22 33]" (pr-str (mapv + [1 2 3] [10 20 30]))) "mapv_2coll")
  (is (= "[[1 :a true] [2 :b false]]" (pr-str (mapv vector [1 2] [:a :b] [true false]))) "mapv_3coll")
  (is (= "[2 4]" (pr-str (filterv (fn* [x] (= 0 (rem x 2))) [1 2 3 4]))) "filterv_even")
  (is (= "2" (pr-str (get (update {:a 1} :a inc) :a))) "update_inc")
  (is (= "11" (pr-str (get (update {:a 1} :a + 10) :a))) "update_args")
  (is (= "[3 2 1]" (pr-str (into [] (reverse [1 2 3])))) "reverse_vec")
  (is (= "3" (pr-str (last [1 2 3]))) "last_vec")
  (is (= "nil" (pr-str (last []))) "last_empty"))
