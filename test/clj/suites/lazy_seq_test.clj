;; Lazy-seq Layer-2 cycle 3 (Phase 14 §9.16 row 14.13.5, ADR-0054 D2/D4).
;;
;; concat / mapcat / drop are lazy `.clj` (the -drop-eager leaf is gone), the
;; 0-arg `(range)` is an infinite lazy seq, and `=` force-walks a `.lazy_seq`
;; operand (the equal.zig sequential arm).
;;
;; Migrated from test/e2e/phase14_lazy_seq_cycle3.sh; each assertion keeps its
;; bash case name. Every case that touches an infinite producer is BOUNDED by
;; take/first, as it was in the script.
(ns suites.lazy-seq-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest zero-arg-range-is-infinite-and-lazy
  (is (= 0 (first (range))))                                ; range0_first
  (is (= [0 1 2 3 4] (into [] (take 5 (range))))))          ; range0_take

(deftest drop-is-lazy
  (is (= '(3 4 5) (drop 2 [1 2 3 4 5])))                    ; drop_print
  (is (= [3 4 5] (into [] (drop 2 [1 2 3 4 5]))))           ; drop_into
  (is (= 7 (first (drop 0 [7 8]))))                         ; drop_zero
  (testing "dropping past the end yields empty, not an error"
    (is (= [] (into [] (drop 9 [1 2 3])))))                 ; drop_overrun
  (testing "and it composes with an infinite source"
    (is (= 100 (first (drop 100 (range)))))))               ; drop_inf_first

(deftest concat-and-mapcat-are-lazy
  (is (= '(1 2 3 4) (concat [1 2] [3 4])))                  ; concat_print
  (is (= 9 (first (concat [] [9]))))                        ; concat_first
  (is (= [1 2 0 1 2] (into [] (take 5 (concat [1 2] (range)))))) ; concat_inf
  (is (= '(1 1 2 2 3 3) (mapcat (fn* [x] [x x]) [1 2 3])))  ; mapcat_print
  (is (= [0 0 1 1] (into [] (take 4 (mapcat (fn* [x] [x x]) (range))))))) ; mapcat_inf

;; `=` must force-walk a lazy operand on either side, and against any
;; sequential representation
(deftest equality-forces-a-lazy-operand
  (is (true? (= (map inc [1 2 3]) (list 2 3 4))))           ; eq_lazy_list
  (is (true? (= (list 2 3 4) (map inc [1 2 3]))))           ; eq_list_lazy
  (is (true? (= (map inc [1 2]) [2 3])))                    ; eq_lazy_vec
  (is (true? (= (map inc [1 2]) (map inc [1 2]))))          ; eq_lazy_lazy
  (testing "length still discriminates in both directions"
    (is (false? (= (map inc [1 2 3]) (list 2 3))))          ; eq_lazy_short
    (is (false? (= (map inc [1 2]) (list 2 3 4)))))         ; eq_lazy_long
  (testing "across the lazy producers"
    (is (true? (= (filter odd? [1 2 3 4 5]) (list 1 3 5)))) ; eq_filter_list
    (is (true? (= (drop 2 [1 2 3 4]) (list 3 4))))          ; eq_drop_list
    (is (true? (= (concat [1] [2 3]) (list 1 2 3)))))       ; eq_concat_list
  (testing "a non-sequential operand is false, not an error"
    (is (false? (= (map inc [1 2]) 5)))))                   ; eq_lazy_num
