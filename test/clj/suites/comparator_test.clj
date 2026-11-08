;; test/e2e/phase14_comparator.sh — comparator (3-way compare fn from a
;; 2-arg boolean pred). Corpus gap sweep P0. core.clj defn.
;; NOTE: `(sort comparator-fn coll)` is a separate gap (cljw sort's 2-arg
;; form treats the fn as a 1-arg key-fn, not a 2-arg comparator) — D-159.

;; Migrated from test/e2e/phase14_comparator.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.comparator-test
  (:require [clojure.test :refer [deftest is]]))

(deftest comparator-cases
  (is (= "-1" (pr-str ((comparator <) 1 2))) "cmp_lt")
  (is (= "1" (pr-str ((comparator <) 2 1))) "cmp_gt")
  (is (= "0" (pr-str ((comparator <) 1 1))) "cmp_eq")
  (is (= "1" (pr-str ((comparator (fn [a b] (< (count a) (count b)))) "aa" "b"))) "cmp_str"))
