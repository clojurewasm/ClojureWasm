;; sort / sort-by — comparator forms, stability, and NaN handling.
;;
;; Migrated from test/e2e/phase14_sort.sh; each assertion keeps its bash case
;; name. `sort` returns a SEQ, so the cases that assert element order wrap in
;; `into []` exactly as the script did, and the two that assert the return
;; SHAPE keep their seq form.
(ns suites.sort-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest sort-orders-by-natural-comparison
  (is (= [1 2 3] (into [] (sort [3 1 2]))))                 ; sort_int
  (is (= ["a" "b" "c"] (into [] (sort ["c" "a" "b"]))))     ; sort_str
  (is (= [:a :b :c] (into [] (sort [:c :a :b]))))           ; sort_kw
  (is (= [] (into [] (sort []))))                           ; sort_empty
  (is (= [1 1 2 2] (into [] (sort [2 1 2 1])))))            ; sort_dup

(deftest sort-takes-an-explicit-comparator
  (is (= [3 2 1] (into [] (sort > [3 1 2]))))                       ; sort_gt
  (is (= [1 2 3] (into [] (sort < [3 1 2]))))                       ; sort_lt
  (testing "a numeric-difference comparator works too"
    (is (= [3 2 1] (into [] (sort (fn [a b] (- b a)) [1 2 3])))))) ; sort_numcmp

(deftest sort-by-projects-then-orders
  (is (= ["b" "aa" "ccc"] (into [] (sort-by count ["aa" "b" "ccc"]))))       ; sort_by_len
  (is (= ["ccc" "aa" "b"] (into [] (sort-by count > ["aa" "b" "ccc"]))))     ; sortby_gt
  (testing "the sort is STABLE: an all-equal key preserves input order"
    (is (= [3 1 2] (into [] (sort-by (fn* [x] 0) [3 1 2]))))))              ; sort_stable

(deftest both-return-a-seq
  (is (= '(1 2 3) (sort [3 1 2])))                          ; sort_seq
  (is (true? (seq? (sort [3 1 2]))))                        ; sort_isseq
  (is (= '(3 2 1) (sort-by - [3 1 2]))))                    ; sortby_seq

;; NaN is unordered: every comparison against it is false, so it can neither
;; sink nor rise. What must hold is that sorting does not LOSE or duplicate it.
;;
;; These assert the PRINTED form on purpose. NaN is not `=` to itself, so
;; `(= [1 ##NaN] [1 ##NaN])` is FALSE and a value assertion here would fail
;; whatever sort did — the bash compared printed text, which is what actually
;; discriminates the placement.
(deftest nan-neither-sorts-nor-disappears
  (is (= "[1 ##NaN]" (pr-str (into [] (sort [1 ##NaN])))))                 ; sort_nan_int
  (is (= "[2.0 ##NaN]" (pr-str (into [] (sort [2.0 ##NaN])))))             ; sort_nan_flt
  (is (= "[1 ##NaN]" (pr-str (into [] (sort-by identity [1 ##NaN])))))     ; sortby_nan
  (testing "and the element count survives"
    (is (= 3 (count (sort [3 ##NaN 1]))))                          ; sort_nan_cnt
    (is (= 4 (count (sort [2.0 ##NaN 1.0 3.0]))))))                ; sort_nan_fcnt

;; a size the old O(n log n)-with-a-bad-constant path choked on; this is a
;; regression guard, not a timing assertion
(deftest it-scales
  (is (= 5000 (count (sort (reverse (range 5000))))))       ; sort_large
  (is (= 0 (first (sort (reverse (range 5000))))))          ; sort_large_min
  (is (= 4999 (last (sort (reverse (range 5000)))))))       ; sort_large_max
