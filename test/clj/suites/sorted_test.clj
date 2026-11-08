;; sorted-map / sorted-set (ADR-0057, persistent LLRB red-black tree, default
;; valueCompare): build / get / contains? / count / keys / vals / seq (in key
;; order) / assoc / conj / sorted? (cycle A) + dissoc / disj (LLRB delete,
;; cycle B1) + custom -by comparators (B2) + rseq / reversible? / subseq /
;; rsubseq (C).
;;
;; Migrated verbatim from test/e2e/phase14_sorted.sh — same expressions, same
;; expected values, now run in-process instead of one `cljw -e` per case.
(ns suites.sorted-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- sorted-map: ordered keys/vals regardless of insertion order ---
(deftest sorted-map-basics
  (testing "keys / vals come back in key order"
    (is (= '(:a :b :c) (keys (sorted-map :c 3 :a 1 :b 2))))       ; keys_ord
    (is (= '(1 2 3) (vals (sorted-map :c 3 :a 1 :b 2)))))         ; vals_ord
  (testing "get / count / contains?"
    (is (= 2 (get (sorted-map :a 1 :b 2) :b)))                    ; get
    (is (= 3 (count (sorted-map :a 1 :b 2 :c 3))))                ; count
    (is (true? (contains? (sorted-map :a 1) :a)))                 ; cont_t
    (is (false? (contains? (sorted-map :a 1) :z))))               ; cont_f
  (testing "numeric keys order numerically"
    (is (= '(1 2 3) (keys (sorted-map 3 :c 1 :a 2 :b)))))         ; num_ord
  (testing "a duplicate key in the ctor — last value wins, count 1"
    (is (= 2 (get (sorted-map :a 1 :a 2) :a)))                    ; dup_val
    (is (= 1 (count (sorted-map :a 1 :a 2)))))                    ; dup_cnt
  (testing "assoc keeps the ordering"
    (is (= '(:a :m :z) (keys (assoc (sorted-map :z 26) :a 1 :m 13))))) ; assoc
  (testing "into 20 reverse-ordered pairs — full LLRB rebalance"
    (is (= [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20]
           (vec (keys (into (sorted-map) (map (fn [i] [(- 20 i) i]) (range 20)))))))) ; into20
  (testing "print form + map-as-fn"
    (is (= "{:a 1, :b 2}" (str (sorted-map :b 2 :a 1))))          ; print_map
    (is (= 2 ((sorted-map :a 1 :b 2) :b)))))                      ; as_fn

;; --- sorted-set ---
(deftest sorted-set-basics
  (is (= '(1 2 3 4 5) (seq (sorted-set 5 3 1 4 2))))              ; set_seq
  (is (true? (contains? (sorted-set 1 2 3) 2)))                   ; set_cont
  (is (= '(1 2 3) (seq (conj (sorted-set 1 3) 2))))               ; set_conj
  (is (= 3 (count (sorted-set 1 2 2 3))))                         ; set_dup
  (is (= "#{1 2 3}" (str (sorted-set 3 1 2)))))                   ; set_print

;; CLJW-SORT-NAN: NaN compares .eq to every number -> treated as a duplicate
;; key on LLRB insert (no native-compare panic); the tie's value wins
;; insert-order (clj parity).
(deftest sorted-nan
  (is (= "#{1.0}" (str (sorted-set 1.0 ##NaN))))                  ; set_nan
  (is (= '(1.0 2.0) (seq (sorted-set 1.0 ##NaN 2.0))))            ; set_nan2
  (is (= "{1.0 :b}" (str (sorted-map 1.0 :a ##NaN :b)))))         ; map_nan

;; --- sorted? ---
(deftest sorted-predicate
  (is (true? (sorted? (sorted-map))))                             ; sortedQ_m
  (is (true? (sorted? (sorted-set))))                             ; sortedQ_s
  (is (false? (sorted? {}))))                                     ; sortedQ_n

;; --- dissoc / disj — LLRB delete (cycle B1), ordering preserved ---
(deftest sorted-delete
  (testing "dissoc"
    (is (= '(:a :c) (keys (dissoc (sorted-map :a 1 :b 2 :c 3) :b))))      ; dissoc
    (is (= 2 (count (dissoc (sorted-map :a 1 :b 2 :c 3) :b))))           ; dissoc_cnt
    (is (= '(:a :c) (keys (dissoc (sorted-map :a 1 :b 2 :c 3 :d 4) :b :d)))) ; dissoc_multi
    (is (= 1 (count (dissoc (sorted-map :a 1) :z))))                     ; dissoc_miss
    (is (= 0 (count (dissoc (sorted-map :a 1) :a)))))                    ; dissoc_empty
  (testing "disj"
    (is (= '(1 2 4 5) (seq (disj (sorted-set 1 2 3 4 5) 3))))            ; disj
    (is (= 2 (count (disj (sorted-set 1 2 3) 2))))                       ; disj_cnt
    (is (= 0 (count (disj (disj (sorted-set 1 2) 1) 2)))))               ; disj_drain
  (testing "repeated delete keeps the remaining keys in order"
    (is (= [0 2 4 5 6 8]
           (vec (keys (reduce dissoc
                              (into (sorted-map) (map (fn [i] [i i]) (range 10)))
                              [3 7 1 9])))))))                           ; dissoc_reorder

;; --- sorted-map-by / sorted-set-by — custom comparator (cycle B2) ---
(deftest sorted-by-comparator
  (is (= '(5 4 3 2 1) (seq (sorted-set-by > 1 5 3 2 4))))                ; set_by_gt
  (is (= '(1 2 3 4 5) (seq (sorted-set-by < 5 3 1 4 2))))                ; set_by_lt
  (is (= '(3 2 1) (keys (sorted-map-by > 1 :a 3 :c 2 :b))))              ; map_by_gt
  (is (= :b (get (sorted-map-by > 1 :a 2 :b) 2)))                        ; by_get
  (is (= '(5 4 2 1) (seq (disj (sorted-set-by > 1 2 3 4 5) 3))))         ; by_disj
  (is (= 2 ((sorted-set-by > 1 2 3) 2)))                                 ; by_as_fn
  (testing "an int-returning comparator fn, not just a boolean predicate"
    (is (= '(3 2 1) (seq (sorted-set-by (fn [a b] (- b a)) 1 2 3))))     ; by_numeric
    (is (= ["a" "bb" "ccc"]
           (vec (sorted-set-by (fn [a b] (- (count a) (count b)))
                               "ccc" "a" "bb"))))))                      ; by_str_len

;; --- rseq / reversible? (cycle C) ---
(deftest reverse-seq
  (is (= '([:c 3] [:b 2] [:a 1]) (rseq (sorted-map :a 1 :b 2 :c 3))))    ; rseq_smap
  (is (= '(3 2 1) (rseq (sorted-set 3 1 2))))                            ; rseq_sset
  (is (= '(3 2 1) (rseq [1 2 3])))                                       ; rseq_vec
  (is (nil? (rseq (sorted-set))))                                        ; rseq_empty
  (is (= '(1 2 3) (rseq (sorted-set-by > 1 2 3))))                       ; rseq_by
  (is (true? (reversible? (sorted-map))))                                ; rev_smap
  (is (true? (reversible? (sorted-set))))                                ; rev_sset
  (is (false? (reversible? (list 1 2)))))                                ; rev_list

;; --- subseq / rsubseq — range queries (cycle C2) ---
(deftest range-queries
  (is (= '(3 4 5) (subseq (sorted-set 1 2 3 4 5) > 2)))                  ; subseq_gt
  (is (= '(3 4 5) (subseq (sorted-set 1 2 3 4 5) >= 3)))                 ; subseq_gte
  (is (= '(1 2) (subseq (sorted-set 1 2 3 4 5) < 3)))                    ; subseq_lt
  (is (= '(2 3 4 5) (subseq (sorted-set 1 2 3 4 5 6 7) >= 2 <= 5)))      ; subseq_rng
  (is (= '([3 :c] [4 :d]) (subseq (sorted-map 1 :a 2 :b 3 :c 4 :d) > 2))) ; subseq_map
  (is (nil? (subseq (sorted-set 1 2 3) > 99)))                           ; subseq_none
  (is (= '(5 4 3) (rsubseq (sorted-set 1 2 3 4 5) > 2)))                 ; rsubseq_gt
  (is (= '(5 4 3) (rsubseq (sorted-set 1 2 3 4 5 6 7) > 2 < 6)))         ; rsubseq_rng
  (testing "subseq against a descending comparator follows THAT order"
    (is (= '(2 1) (subseq (sorted-set-by > 1 2 3 4 5) > 3)))))           ; subseq_by
