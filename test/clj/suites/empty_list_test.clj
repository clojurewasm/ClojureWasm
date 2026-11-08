;; The empty list `()` is a DISTINCT interned Value (D-164 / clj-parity C1).
;;
;; Migrated from `test/e2e/phase14_empty_list.sh` (one cljw process per case)
;; into one in-process clojure.test suite. Because the bash tier asserted the
;; PRINTED form of each result, the `()`-vs-`nil` cases assert `pr-str` as well
;; as value equality: `(= () [])` is true, so a bare `(= () x)` would not pin
;; the printed shape the bash pinned.
(ns suites.empty-list-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- `()` self-evaluates to the distinct empty list, not nil ---
(deftest empty-list-self-evaluates
  (testing "every producing position yields the printed `()`"
    (is (= "()" (pr-str ())))                    ; el_eval
    (is (= "()" (pr-str ((fn* [] ())))))         ; el_in_fn
    (is (= "()" (pr-str (let [x ()] x))))        ; el_let
    (is (= "()" (pr-str (quote ()))))))          ; el_quote

;; --- Distinct from nil; equal to other empty spellings + the empty vector ---
(deftest empty-list-equality
  (is (false? (= () nil)))                       ; el_ne_nil
  (is (true? (= () (list))))                     ; el_eq_list
  (is (true? (= () (quote ()))))                 ; el_eq_quote
  (is (true? (= () []))))                        ; el_eq_vec

;; --- Predicates key on the `.list` tag, so they hold for `()` ---
(deftest empty-list-predicates
  (is (true? (list? ())))                        ; el_list_q
  (is (true? (seq? ())))                         ; el_seq_q
  (is (true? (empty? ())))                       ; el_empty_q
  (is (= 0 (count ()))))                         ; el_count

;; --- seq / first / next of empty → nil; rest → () (the RT.more asymmetry) ---
(deftest empty-seq-more-next-asymmetry
  (testing "seq / first / next of `()` are nil"
    (is (nil? (seq ())))                         ; el_seq
    (is (nil? (first ())))                       ; el_first
    (is (nil? (next ()))))                       ; el_next
  (testing "rest of `()` is `()`"
    (is (= "()" (pr-str (rest ())))))            ; el_rest
  (testing "rest of a 1-elem coll / nil / vector is `()`; next is nil"
    (is (= "()" (pr-str (rest (quote (1))))))    ; el_rest1
    (is (= "()" (pr-str (rest nil))))            ; el_rest_nil
    (is (= "()" (pr-str (rest [1]))))            ; el_rest_vec
    (is (nil? (next (quote (1)))))               ; el_next1
    (is (true? (list? (rest (quote (1))))))))    ; el_rest_isl

;; --- `(list)` → () (PersistentList/EMPTY), distinct from `& xs` → nil ---
(deftest empty-list-constructors
  (is (= "()" (pr-str (list))))                  ; el_list0
  (is (nil? ((fn* [& xs] xs))))                  ; el_fn_rest0
  (is (= "()" (pr-str (apply list [])))))        ; el_apply

;; --- Empty results of the seq pipeline print `()`, not nil ---
(deftest empty-seq-pipeline-results
  (is (= "()" (pr-str (filter even? [1 3]))))    ; el_filter
  (is (= "()" (pr-str (map inc nil))))           ; el_map_nil
  (is (= "()" (pr-str (take 0 [1 2]))))          ; el_take0
  (is (= "()" (pr-str (distinct []))))           ; el_distinct
  (is (= "()" (pr-str (sort []))))               ; el_sort
  (is (= "()" (pr-str (range 0))))               ; el_range0
  (is (= "()" (pr-str (concat))))                ; el_concat0
  (is (= "(1)" (pr-str (conj () 1)))))           ; el_conj

;; --- butlast of ≤1 elem → nil (JVM `(seq ret)`); >1 → the prefix list ---
(deftest butlast-empty-collapses-to-nil
  (is (nil? (butlast [1])))                      ; el_butlast1
  (is (= "(1 2)" (pr-str (butlast [1 2 3])))))   ; el_butlast3
