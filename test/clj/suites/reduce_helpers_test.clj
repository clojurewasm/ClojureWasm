;; test/e2e/phase14_reduce_helpers.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 5. max-key / min-key /
;; flatten / reductions. Pattern A over reduce / conj / last / into /
;; sequential? / >= / <=. (sort/sort-by deferred — need a compare op +
;; sort algorithm.) reductions is the 3-arg [f init coll] form.
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_reduce_helpers.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.reduce-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest reduce-helpers-cases
  (is (= "[1 2 3]" (pr-str (max-key count [1] [1 2 3] [1 2]))) "max_key")
  (is (= "[1]" (pr-str (min-key count [1 2 3] [1] [1 2]))) "min_key")
  (is (= "[1 2 3 4 5]" (pr-str (into [] (flatten [1 [2 [3 4]] 5])))) "flatten")
  (is (= "[1 2 3]" (pr-str (into [] (flatten [1 2 3])))) "flatten_flat")
  (is (= "(1 2 3)" (pr-str (flatten [1 [2] 3]))) "flatten_seq")
  (is (= "true" (pr-str (seq? (flatten [1 2])))) "flatten_isseq")
  (is (= "[0 1 3 6]" (pr-str (into [] (reductions + 0 [1 2 3])))) "reductions"))

(deftest reduce-kv-indexed-cases
  (is (= 46 (reduce-kv (fn [acc i x] (+ acc (* i x))) 0 [4 5 7 9])))
  (is (= 9 (reduce-kv (fn [acc i x] (+ acc i x)) 0 (subvec [50 1 2 3 100] 1 4))))
  (is (= 42 (reduce-kv (fn [acc _ _] (throw (Exception. "unreachable"))) 42 [])))
  (let [calls (atom 0)]
    (is (= 9 (reduce-kv (fn [acc i x] (swap! calls inc) (reduced (+ acc i x))) 5 [4 10 20])))
    (is (= 1 @calls)))
  (is (= 3 (reduce-kv (fn [acc _ v] (+ acc v)) 0 {:a 1 :b 2})))
  ;; A MapEntry is `vector?` but not a vector cell: indexed as [k v].
  (is (= [[0 :a] [1 1]] (reduce-kv (fn [acc i x] (conj acc [i x])) [] (first {:a 1}))))
  (is (= :a (reduce-kv (fn [_ _ x] (reduced x)) nil (first {:a 1}))) "mapentry_reduced"))

;; Edges of the Zig indexed path, each checked against JVM Clojure 1.12.
(deftest reduce-kv-indexed-edges
  (is (= [] (reduce-kv (fn [acc k _] (conj acc k)) [] nil)) "nil_coll")
  (is (= 6 (reduce-kv (fn [acc _ x] (+ acc x)) 0 (with-meta [1 2 3] {:m 1}))) "meta_vector")
  (is (= :init (reduce-kv (fn [_ _ _] :no) :init (subvec [1 2] 1 1))) "empty_subvec")
  (is (= [[0 2] [1 3]] (reduce-kv (fn [acc i x] (conj acc [i x])) []
                                  (subvec (subvec [0 1 2 3 4] 1 4) 1 3))) "subvec_of_subvec")
  (let [calls (atom 0)]
    (is (= [1 1 2] (reduce-kv (fn [acc i x] (swap! calls inc)
                                (if (= i 1) (reduced [acc i x]) (+ acc x)))
                              0 (subvec [50 1 2 3 100] 1 4))) "subvec_reduced_keys_from_zero")
    (is (= 2 @calls) "subvec_reduced_stops"))
  ;; One layer of reduced is stripped, as clj's kv-reduce does: a doubly
  ;; reduced result comes back still reduced.
  (let [r (reduce-kv (fn [_ _ x] (reduced (reduced x))) 0 [1 2])]
    (is (reduced? r) "nested_reduced_one_layer")
    (is (= 1 @r) "nested_reduced_inner"))
  (is (reduced? (reduce-kv (fn [acc _ _] acc) (reduced 7) [])) "reduced_init_untouched")
  (is (= 0 (reduce-kv nil 0 [])) "nil_f_empty_never_called")
  (is (thrown? Exception (reduce-kv nil 0 [1])) "nil_f_called")
  (is (thrown? Exception (reduce-kv (fn [acc _ _] acc) 0 (transient [1 2]))) "transient_rejected")
  (is (= 4999950000 (reduce-kv (fn [acc i _] (+ acc i)) 0 (vec (range 100000)))) "wide_trie")
  (is (= 20000 (count (reduce-kv (fn [acc i x] (conj acc (str i x))) [] (vec (range 20000)))))
      "allocating_callback_survives_gc"))
