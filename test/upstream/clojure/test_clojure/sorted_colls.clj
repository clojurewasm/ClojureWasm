;; CLJW-ADD: Tests for sorted collections
;; sorted-map, sorted-set, sorted-map-by, sorted-set-by

(ns clojure.test-clojure.sorted-colls
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== sorted-map ==========

(deftest test-sorted-map
  (testing "basic sorted-map"
    (let [m (sorted-map 3 :c 1 :a 2 :b)]
      (is (= {1 :a 2 :b 3 :c} m))
      (is (= [1 2 3] (keys m)))
      (is (= [:a :b :c] (vals m)))))
  (testing "empty sorted-map"
    (is (= {} (sorted-map)))
    (is (sorted? (sorted-map))))
  (testing "sorted? predicate"
    (is (sorted? (sorted-map 1 :a)))
    (is (not (sorted? {1 :a}))))
  (testing "assoc into sorted-map"
    (let [m (assoc (sorted-map 2 :b) 1 :a 3 :c)]
      (is (= [1 2 3] (keys m)))))
  (testing "dissoc from sorted-map"
    (let [m (dissoc (sorted-map 1 :a 2 :b 3 :c) 2)]
      (is (= [1 3] (keys m)))))
  (testing "conj sorted-map"
    (let [m (conj (sorted-map) [2 :b] [1 :a])]
      (is (= [1 2] (keys m)))))
  (testing "reduce-kv sorted order"
    ;; str of keywords includes colon: (str :a) = ":a"
    (is (= "1:a2:b3:c"
           (reduce-kv str "" (sorted-map 3 :c 1 :a 2 :b))))))

;; ========== sorted-set ==========

(deftest test-sorted-set
  (testing "basic sorted-set"
    (let [s (sorted-set 3 1 2)]
      (is (= #{1 2 3} s))
      (is (= [1 2 3] (seq s)))))
  (testing "empty sorted-set"
    (is (= #{} (sorted-set)))
    (is (sorted? (sorted-set))))
  (testing "contains?"
    (let [s (sorted-set 1 2 3)]
      (is (contains? s 2))
      (is (not (contains? s 4)))))
  (testing "conj sorted-set"
    (is (= [1 2 3 4] (seq (conj (sorted-set 3 1) 4 2)))))
  (testing "disj sorted-set"
    (is (= [1 3] (seq (disj (sorted-set 1 2 3) 2))))))

;; ========== sorted-map-by ==========

(deftest test-sorted-map-by
  (testing "reverse comparator"
    (let [m (sorted-map-by > 1 :a 3 :c 2 :b)]
      (is (= [3 2 1] (keys m)))
      (is (= [:c :b :a] (vals m)))))
  (testing "custom comparator"
    (let [m (sorted-map-by (fn [a b] (compare (str a) (str b)))
                           10 :ten 2 :two 1 :one)]
      (is (= [1 10 2] (keys m))))))

;; ========== sorted-set-by ==========

(deftest test-sorted-set-by
  (testing "reverse comparator"
    (let [s (sorted-set-by > 1 3 2)]
      (is (= [3 2 1] (seq s)))))
  (testing "string length comparator"
    (let [s (sorted-set-by #(compare (count %1) (count %2))
                           "bb" "a" "ccc")]
      (is (= ["a" "bb" "ccc"] (seq s))))))

;; ========== subseq / rsubseq ==========

(deftest test-subseq-rsubseq
  (testing "subseq on sorted-set"
    (let [s (sorted-set 1 2 3 4 5)]
      (is (= [3 4 5] (subseq s >= 3)))
      (is (= [1 2 3] (subseq s <= 3)))
      (is (= [2 3 4] (subseq s >= 2 <= 4)))))
  (testing "rsubseq on sorted-set"
    (let [s (sorted-set 1 2 3 4 5)]
      (is (= [5 4 3] (rsubseq s >= 3)))
      (is (= [3 2 1] (rsubseq s <= 3)))))
  (testing "subseq on sorted-map"
    (let [m (sorted-map 1 :a 2 :b 3 :c 4 :d)]
      (is (= [[2 :b] [3 :c] [4 :d]] (subseq m > 1))))))

(run-tests)
