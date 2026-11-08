;; test/e2e/composition_unlock_a1.sh
;;
;; Phase 6.16.a-1 EXIT smoke — core glue fundamentals
;; (count / seq / first / rest / cons / empty) per ADR-0033 D6.
;;
;; After this cycle lands, user composition unlocks the first round
;; of Pattern A recipes that depend on these six (e.g. `(rest [1 2 3])`,
;; `(cons 0 [1 2])`). Phase 6.16.a-2 unlocks more via conj/disj/etc.

;; Migrated from test/e2e/composition_unlock_a1.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.composition-unlock-a1-test
  (:require [clojure.test :refer [deftest is]]))

(deftest composition-unlock-a1-cases
  (is (= "3" (pr-str (count [1 2 3]))) "count_vector_3")
  (is (= "4" (pr-str (count "café"))) "count_string_4")
  (is (= "0" (pr-str (count nil))) "count_nil_0")
  (is (= "3" (pr-str (count (hash-set 1 2 3)))) "count_set_3")
  (is (= "nil" (pr-str (seq []))) "seq_empty_nil")
  (is (= "(1 2)" (pr-str (seq [1 2]))) "seq_vec_2")
  (is (= "nil" (pr-str (seq nil))) "seq_nil_nil")
  (is (= "1" (pr-str (first [1 2 3]))) "first_vec_1")
  (is (= "nil" (pr-str (first nil))) "first_nil_nil")
  (is (= "(2 3)" (pr-str (rest [1 2 3]))) "rest_vec_2_3")
  (is (= "()" (pr-str (rest nil))) "rest_nil_nil")
  (is (= "(0)" (pr-str (cons 0 nil))) "cons_x_nil")
  (is (= "(0 1 2)" (pr-str (cons 0 [1 2]))) "cons_x_vec")
  (is (= "[]" (pr-str (empty [1 2 3]))) "empty_vec_empty")
  (is (= "#{}" (pr-str (empty (hash-set 1 2)))) "empty_set_empty")
  (is (= "nil" (pr-str (empty nil))) "empty_nil_nil")
  (is (= "2" (pr-str (first (rest [1 2 3])))) "first_of_rest")
  (is (= "3" (pr-str (count (cons 0 [1 2])))) "count_of_cons"))
