;; test/e2e/phase14_compare.sh
;;
;; Phase 14 §9.16 — D-137. General 3-way `compare` (= clojure.lang.Util.compare),
;; was numeric-only. ADR-0053. nil lowest; numbers cross the tower; strings
;; lexicographic; bool false<true; keywords/symbols ns-then-name; vectors
;; length-first then element-wise; uncomparable pairs raise.
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_compare.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.compare-test
  (:require [clojure.test :refer [deftest is]]))

(deftest compare-cases
  (is (= "-1" (pr-str (compare 1 2))) "num_lt")
  (is (= "0" (pr-str (compare 2 2))) "num_eq")
  (is (= "1" (pr-str (compare 3 1))) "num_gt")
  (is (= "0" (pr-str (compare 1 1.0))) "num_cross")
  (is (= "-1" (pr-str (compare 1.5 2))) "num_float")
  (is (= "0" (pr-str (compare nil nil))) "nil_nil")
  (is (= "-1" (pr-str (compare nil 5))) "nil_lt")
  (is (= "1" (pr-str (compare 5 nil))) "nil_gt")
  (is (= "-1" (pr-str (compare :a :b))) "kw_lt")
  (is (= "0" (pr-str (compare :a :a))) "kw_eq")
  (is (= "-1" (pr-str (compare "a" "b"))) "str_lt")
  (is (= "0" (pr-str (compare "abc" "abc"))) "str_eq")
  (is (= "-1" (pr-str (compare [1 2] [1 3]))) "vec_elem")
  (is (= "-1" (pr-str (compare [1] [1 2]))) "vec_len")
  (is (= "0" (pr-str (compare [1 2] [1 2]))) "vec_eq")
  (is (= "-1" (pr-str (compare false true))) "bool_lt")
  (is (= "1" (pr-str (compare true false))) "bool_gt"))
