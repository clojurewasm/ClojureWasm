;; test/e2e/phase14_find.sh — D-134 find (map entry [k v] or nil; present-
;; nil-value distinguished via contains?). Pattern A .clj, AOT blob.

;; Migrated from test/e2e/phase14_find.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.find-test
  (:require [clojure.test :refer [deftest is]]))

(deftest find-cases
  (is (= "[:a 1]" (pr-str (find {:a 1 :b 2} :a))) "find_hit")
  (is (= "nil" (pr-str (find {:a 1} :missing))) "find_miss")
  (is (= "[:a nil]" (pr-str (find {:a nil} :a))) "find_nilval")
  (is (= "nil" (pr-str (find {} :x))) "find_empty")
  (is (= "[\"k\" 9]" (pr-str (find {"k" 9} "k"))) "find_strkey"))
