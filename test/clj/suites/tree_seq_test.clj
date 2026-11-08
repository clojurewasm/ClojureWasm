;; test/e2e/phase14_tree_seq.sh — D-134 tree-seq: lazy pre-order DFS of all
;; nodes (branch? + children). Recursive .clj def + mapcat (lazy). AOT blob.

;; Migrated from test/e2e/phase14_tree_seq.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.tree-seq-test
  (:require [clojure.test :refer [deftest is]]))

(deftest tree-seq-cases
  (is (= "[[1 [2 3]] 1 [2 3] 2 3]" (pr-str (vec (tree-seq vector? seq [1 [2 3]])))) "ts_preorder")
  (is (= "8" (pr-str (count (tree-seq vector? seq [1 [2 [3 [4]]]])))) "ts_count")
  (is (= "[42]" (pr-str (vec (tree-seq (fn* [x] false) seq 42)))) "ts_leaf")
  (is (= "[:root :a]" (pr-str (first (tree-seq vector? seq [:root :a])))) "ts_root")
  (is (= "[1 2 3 4]" (pr-str (vec (filter (complement vector?) (tree-seq vector? seq [1 [2 3] 4]))))) "ts_leaves"))
