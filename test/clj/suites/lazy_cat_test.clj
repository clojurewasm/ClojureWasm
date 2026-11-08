;; test/e2e/phase14_lazy_cat.sh — D-134 lazy-cat macro: (concat (lazy-seq c0)
;; (lazy-seq c1) …) — lazily concatenates, deferring each coll until consumed.

;; Migrated from test/e2e/phase14_lazy_cat.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.lazy-cat-test
  (:require [clojure.test :refer [deftest is]]))

(deftest lazy-cat-cases
  (is (= "[1 2 3 4]" (pr-str (vec (lazy-cat [1 2] [3 4])))) "lc_two")
  (is (= "[1 2 3]" (pr-str (vec (lazy-cat [1] [2] [3])))) "lc_three")
  (is (= "[]" (pr-str (vec (lazy-cat)))) "lc_empty")
  (is (= "[:a :b :c]" (pr-str (vec (lazy-cat [:a] (list :b :c))))) "lc_mixed")
  (is (= "[1 2 0 1 2]" (pr-str (vec (take 5 (lazy-cat [1 2] (range)))))) "lc_lazy"))
