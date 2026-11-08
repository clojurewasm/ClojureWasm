;; test/e2e/composition_unlock_a2.sh
;;
;; Phase 6.16.a-2 EXIT smoke — collection ops
;; (conj / disj / contains? / get / nth / assoc / dissoc / keys / vals)
;; per ADR-0033 D6 + v5 §5.2.
;;
;; After this cycle lands, user composition unlocks the second round
;; of Pattern A recipes (`(reduce conj #{} ...)` etc once reduce
;; lands in Phase 6.16.a-3).

;; Migrated from test/e2e/composition_unlock_a2.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.composition-unlock-a2-test
  (:require [clojure.test :refer [deftest is]]))

(deftest composition-unlock-a2-cases
  (is (= "[1 2 3]" (pr-str (conj [1 2] 3))) "conj_vec_append")
  (is (= "#{1 2}" (pr-str (conj (hash-set 1) 2))) "conj_set_add")
  (is (= "(42)" (pr-str (conj nil 42))) "conj_nil_one_elt")
  (is (= "#{1 3}" (pr-str (disj (hash-set 1 2 3) 2))) "disj_set")
  (is (= "true" (pr-str (contains? (hash-set 1 2) 1))) "contains_set_true")
  (is (= "false" (pr-str (contains? (hash-set 1 2) 99))) "contains_set_false")
  (is (= "false" (pr-str (contains? nil 1))) "contains_nil_false")
  (is (= "1" (pr-str (get (hash-set 1 2) 1))) "get_set_present")
  (is (= "nil" (pr-str (get nil :a))) "get_nil_nil")
  (is (= "\"default\"" (pr-str (get nil :a "default"))) "get_default")
  (is (= "20" (pr-str (nth [10 20 30] 1))) "nth_vec_indexed")
  (is (= "\"oob\"" (pr-str (nth [10 20 30] 99 "oob"))) "nth_oob_default")
  (is (= "{:a 1}" (pr-str (assoc nil :a 1))) "assoc_nil_to_map")
  (is (= "[1 99 3]" (pr-str (assoc [1 2 3] 1 99))) "assoc_vec_replace")
  (is (= "{:b 2}" (pr-str (dissoc (hash-map :a 1 :b 2) :a))) "dissoc_map")
  (is (= "(:a :b)" (pr-str (keys (hash-map :a 1 :b 2)))) "keys_map")
  (is (= "(1 2)" (pr-str (vals (hash-map :a 1 :b 2)))) "vals_map")
  (is (= "3" (pr-str (count (conj [1 2] 3)))) "count_after_conj")
  (is (= ":a" (pr-str (first (keys (hash-map :a 1 :b 2))))) "first_of_keys"))
