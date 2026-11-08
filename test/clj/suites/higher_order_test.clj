;; Eager higher-order surface — map / filter / take / drop / keep / remove
;; plus partial / comp / complement / constantly / juxt
;; (Phase 6.16.a-3.2 EXIT smoke, ADR-0033 D6 + v5 §5.2).
;;
;; Migrated from test/e2e/transducer_unlock_a3.sh, whose name records the v5
;; §9.2 deliverable (a transducer 先取り cycle) rather than its contents: the
;; transducer 1-arg arities landed later and live in suites/transducers_test.clj.
;; The suite is named for what it tests. Each assertion keeps its bash case name.
;;
;; Empty results assert the PRINTED form: cljw renders an empty realized seq as
;; `()`, and `=` alone would not distinguish that from nil (the D-164 overhaul).
(ns suites.higher-order-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest map-filter-take-drop
  (testing "map"
    (is (= '(2 3 4) (map inc [1 2 3])))                  ; map_inc
    (is (= "()" (pr-str (map inc [])))))                 ; map_empty
  (testing "filter"
    (is (= '(2 4) (filter pos? [-1 2 -3 4])))            ; filter_pos
    (is (= "()" (pr-str (filter pos? [-1 -2])))))        ; filter_none
  (testing "take"
    (is (= '(1 2) (take 2 [1 2 3 4 5])))                 ; take_n
    (is (= "()" (pr-str (take 0 [1 2]))))                ; take_zero
    (is (= '(1 2) (take 99 [1 2]))))                     ; take_more
  (testing "drop"
    (is (= '(3 4 5) (drop 2 [1 2 3 4 5])))               ; drop_n
    (is (= "()" (pr-str (drop 99 [1 2]))))))             ; drop_all

(deftest keep-and-remove
  (is (= '(2 4) (keep (fn* [x] (if (pos? x) x nil)) [-1 2 -3 4])))  ; keep_pos
  (is (= '(-1 -3) (remove pos? [-1 2 -3 4]))))                      ; remove_pos

(deftest constantly-ignores-every-argument
  (is (= 42 ((constantly 42))))                          ; constantly_no_args
  (is (= 42 ((constantly 42) 1 2 3))))                   ; constantly_many_args

(deftest complement-inverts-the-predicate
  (is (true? ((complement pos?) -1)))                    ; complement_neg
  (is (false? ((complement pos?) 1))))                   ; complement_pos

(deftest partial-comp-and-juxt
  (testing "partial fixes leading arguments"
    (is (= 15 ((partial + 10) 5)))                       ; partial_1arg
    (is (= 37 ((partial + 10 20) 3 4))))                 ; partial_2args
  (is (= 7 ((comp inc inc) 5)))                          ; comp_2_fns
  (is (= [6 4] ((juxt inc dec) 5))))                     ; juxt_2_fns

(deftest composed-with-the-seq-surface
  (is (= 3 (count (map inc [1 2 3]))))                             ; count_of_map
  (is (= 6 (reduce + 0 (filter pos? [-1 1 -2 2 -3 3]))))           ; reduce_filter
  (is (= '(3 4 5) (map (comp inc inc) [1 2 3]))))                  ; comp_in_map
