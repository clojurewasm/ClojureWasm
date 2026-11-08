;; test/e2e/phase14_accessors.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 6. second / ffirst / not-empty
;; / take-last / drop-last. Trivial Pattern A over first/rest/empty?/take/
;; reverse/butlast (no compare dependency). (sort/sort-by deferred behind
;; D-137 — compare is numeric-only.)
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_accessors.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.seq-accessors-test
  (:require [clojure.test :refer [deftest is]]))

(deftest seq-accessors-cases
  (is (= "2" (pr-str (second [1 2 3]))) "second")
  (is (= "nil" (pr-str (second [1]))) "second_short")
  (is (= "1" (pr-str (ffirst [[1 2] [3]]))) "ffirst")
  (is (= "nil" (pr-str (not-empty []))) "not_empty_e")
  (is (= "[1]" (pr-str (not-empty [1]))) "not_empty_ne")
  (is (= "[2 3]" (pr-str (into [] (take-last 2 [1 2 3])))) "take_last")
  (is (= "[1 2]" (pr-str (into [] (drop-last [1 2 3])))) "drop_last")
  (is (= "[1 2]" (pr-str (into [] (drop-last 2 [1 2 3 4])))) "drop_last_n")
  (is (= "[1 2 3]" (pr-str (into [] (drop-last 0 [1 2 3])))) "drop_last_n0"))
