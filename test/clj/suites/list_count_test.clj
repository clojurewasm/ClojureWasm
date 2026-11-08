;; O-057 — `(count lst)` takes the stored O(1) count for a PURE `.list` chain
;; and keeps the element walk for a MIXED chain (a `.list` cell whose rest
;; leaves `.list`).
;;
;; The optimisation is sound only because `COUNT_UNKNOWN` marks the chains
;; whose stored count would otherwise be a PREFIX length presented as a total.
;; So the property under test is not speed, it is that BOTH answers stay
;; exact — a mixed chain must never report the pure prefix.
;;
;; Migrated from test/e2e/list_count_exact.sh; each assertion keeps its bash
;; case name.
(ns suites.list-count-test
  (:require [clojure.test :refer [deftest is testing]]))

;; a chain that is .list all the way down: the stored count is the total
(deftest pure-list-chains-count-exactly
  (is (= 3 (count (list 1 2 3))))                           ; pure_list_literal
  (is (= 4 (count '(1 2 3 4))))                             ; pure_quoted
  (is (= 0 (count (list))))                                 ; pure_empty
  (is (= 0 (count '())))                                    ; pure_empty_quoted
  (is (= 3 (count (cons 1 (cons 2 (list 3))))))             ; pure_cons_chain
  (is (= 1000 (count (apply list (range 1000)))))           ; pure_apply_list
  (is (= 3 (count (conj (list 1 2) 0)))))                   ; pure_conj_list

;; a .list cell whose rest is NOT .list: the stored count would be a prefix,
;; so the walk must take over
(deftest mixed-chains-count-exactly-too
  (is (= 4 (count (cons 1 (map inc [1 2 3])))))             ; cons_over_lazy_map
  (is (= 4 (count (conj (range 3) 99))))                    ; cons_over_range
  (is (= 4 (count (cons 0 (seq [1 2 3])))))                 ; cons_over_vec_seq
  (is (= 3 (count (cons 1 (lazy-seq [2 3])))))              ; cons_over_lazy_seq
  (is (= 4 (count (cons \a (seq "bcd")))))                  ; cons_over_string
  (testing "nesting more pure cells in front does not restore the shortcut"
    (is (= 5 (count (cons 1 (cons 2 (map inc [1 2 3]))))))  ; nested_over_mixed
    (is (= 6 (count (cons 0 (cons 1 (cons 2 (seq [3 4 5]))))))))) ; deep_over_mixed

(deftest equality-is-unaffected-by-the-representation
  (is (true? (= (cons 1 (lazy-seq [2 3])) (list 1 2 3))))   ; equality_mixed_vs_pure
  (is (true? (= (list 1 2 3) (list 1 2 3))))                ; equality_pure_vs_pure
  (is (false? (= (list 1 2) (list 1 2 3)))))                ; equality_differing

(deftest the-rest-of-the-seq-surface-agrees-with-count
  (is (false? (empty? (cons 1 (map inc [1 2])))))           ; mixed_is_not_empty
  (is (= 3 (count (seq (cons 1 (map inc [1 2]))))))         ; mixed_seq_is_itself
  (is (= [1 2] (let [c (cons 1 (map inc [1 2]))]
                 [(first c) (count (rest c))]))))           ; mixed_first_rest

(deftest metadata-does-not-disturb-either-path
  (is (= 3 (count (with-meta '(1 2 3) {:a 1}))))            ; with_meta_pure
  (is (= 3 (count (with-meta (cons 1 (map inc [1 2])) {:a 1}))))) ; with_meta_mixed
