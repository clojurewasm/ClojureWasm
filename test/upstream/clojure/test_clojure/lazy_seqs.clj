;; CLJW-ADD: Tests for lazy sequences
;; lazy-seq, iterate, repeat, cycle, range, concat

(ns clojure.test-clojure.lazy-seqs
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== lazy-seq basics ==========

(deftest test-lazy-seq-basic
  (testing "lazy-seq is lazy"
    (let [realized (atom false)
          s (lazy-seq (reset! realized true) [1 2 3])]
      (is (false? @realized))
      (first s)
      (is (true? @realized))))
  (testing "lazy-seq with cons"
    (is (= [1 2 3]
           (take 3 ((fn step [n]
                      (lazy-seq (cons n (step (inc n))))) 1))))))

;; ========== iterate ==========

(deftest test-iterate
  (testing "basic iterate"
    (is (= [0 1 2 3 4] (take 5 (iterate inc 0)))))
  (testing "iterate with multiplication"
    (is (= [1 2 4 8 16] (take 5 (iterate #(* 2 %) 1))))))

;; ========== repeat ==========

(deftest test-repeat
  (testing "infinite repeat"
    (is (= [42 42 42] (take 3 (repeat 42)))))
  (testing "finite repeat"
    (is (= [1 1 1 1 1] (repeat 5 1))))
  (testing "zero repeat"
    (is (= [] (repeat 0 :x)))))

;; ========== cycle ==========

(deftest test-cycle
  (testing "basic cycle"
    (is (= [1 2 3 1 2 3 1] (take 7 (cycle [1 2 3])))))
  (testing "single element cycle"
    (is (= [42 42 42] (take 3 (cycle [42]))))))

;; ========== range ==========

(deftest test-range
  (testing "no args"
    (is (= [0 1 2 3 4] (take 5 (range)))))
  (testing "end only"
    (is (= [0 1 2 3 4] (range 5))))
  (testing "start and end"
    (is (= [2 3 4] (range 2 5))))
  (testing "with step"
    (is (= [0 2 4 6 8] (range 0 10 2))))
  (testing "negative step"
    (is (= [5 4 3 2 1] (range 5 0 -1))))
  (testing "empty range"
    (is (empty? (range 5 0)))))

;; ========== concat ==========

(deftest test-concat
  (testing "basic concat"
    (is (= [1 2 3 4] (concat [1 2] [3 4]))))
  (testing "empty sequences"
    (is (= [1 2] (concat [] [1] [] [2] []))))
  (testing "lazy concat"
    (is (= [1 2 3 4 5 6] (concat [1 2] [3 4] [5 6])))))

;; ========== interleave / interpose ==========

(deftest test-interleave-interpose
  (testing "interleave"
    (is (= [1 :a 2 :b 3 :c] (interleave [1 2 3] [:a :b :c]))))
  (testing "interleave unequal lengths"
    (is (= [1 :a 2 :b] (interleave [1 2 3] [:a :b]))))
  (testing "interpose"
    (is (= [1 0 2 0 3] (interpose 0 [1 2 3])))
    (is (= [] (interpose 0 [])))))

;; ========== take / drop variants ==========

(deftest test-take-drop
  (testing "take-nth"
    (is (= [0 3 6 9] (take-nth 3 (range 10)))))
  (testing "take-last"
    (is (= [3 4 5] (take-last 3 (range 6)))))
  (testing "drop-last"
    (is (= [0 1 2] (drop-last 3 (range 6)))))
  (testing "split-at"
    (is (= [[0 1 2] [3 4]] (split-at 3 (range 5)))))
  (testing "split-with"
    (is (= [[1 2 3] [4 5 6]] (split-with #(<= % 3) [1 2 3 4 5 6])))))

(run-tests)
