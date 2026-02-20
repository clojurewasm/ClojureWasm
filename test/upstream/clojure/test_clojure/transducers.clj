;; CLJW-ADD: Tests for transducers
;; map, filter, remove, take, drop, etc. in transducer mode

(ns clojure.test-clojure.transducers
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== basic transducers ==========

(deftest test-map-xf
  (testing "map transducer"
    (is (= [2 4 6] (into [] (map #(* 2 %)) [1 2 3]))))
  (testing "map with transduce"
    (is (= 12 (transduce (map #(* 2 %)) + [1 2 3])))))

(deftest test-filter-xf
  (testing "filter transducer"
    (is (= [2 4] (into [] (filter even?) [1 2 3 4 5]))))
  (testing "remove transducer"
    (is (= [1 3 5] (into [] (remove even?) [1 2 3 4 5])))))

(deftest test-take-drop-xf
  (testing "take transducer"
    (is (= [1 2 3] (into [] (take 3) [1 2 3 4 5]))))
  (testing "drop transducer"
    (is (= [4 5] (into [] (drop 3) [1 2 3 4 5]))))
  (testing "take-while transducer"
    (is (= [1 2 3] (into [] (take-while #(< % 4)) [1 2 3 4 5]))))
  (testing "drop-while transducer"
    (is (= [4 5] (into [] (drop-while #(< % 4)) [1 2 3 4 5])))))

;; ========== comp transducers ==========

(deftest test-comp-xf
  (testing "composed transducers"
    (is (= [4 8]
           (into [] (comp (filter even?) (map #(* 2 %))) [1 2 3 4 5]))))
  (testing "three transducers"
    (is (= [4]
           (into [] (comp (filter even?) (map #(* 2 %)) (take 1)) [1 2 3 4 5])))))

;; ========== mapcat xf ==========

(deftest test-mapcat-xf
  (testing "mapcat transducer"
    (is (= [1 1 2 2 3 3]
           (into [] (mapcat #(vector % %)) [1 2 3])))))

;; ========== dedupe / distinct ==========

(deftest test-dedupe-distinct-xf
  (testing "dedupe transducer"
    (is (= [1 2 3 2 1]
           (into [] (dedupe) [1 1 2 2 2 3 3 2 1 1]))))
  (testing "distinct transducer"
    (is (= [1 2 3]
           (into [] (distinct) [1 2 1 3 2 3 1])))))

;; ========== partition-by / partition-all ==========

(deftest test-partition-xf
  (testing "partition-by transducer"
    (is (= [[1 1] [2 2 2] [3]]
           (into [] (partition-by identity) [1 1 2 2 2 3]))))
  (testing "partition-all transducer"
    (is (= [[1 2] [3 4] [5]]
           (into [] (partition-all 2) [1 2 3 4 5])))))

;; ========== transduce ==========

(deftest test-transduce
  (testing "with init"
    (is (= 6 (transduce (map inc) + 0 [0 1 2]))))
  (testing "without init"
    (is (= 6 (transduce (map inc) + [0 1 2]))))
  (testing "into with xf"
    (is (= #{2 4 6} (into #{} (map #(* 2 %)) [1 2 3])))))

;; ========== sequence with xf ==========

(deftest test-sequence-xf
  (testing "sequence produces lazy seq"
    (is (= '(2 4 6) (sequence (map #(* 2 %)) [1 2 3]))))
  (testing "sequence with filter"
    (is (= '(2 4) (sequence (filter even?) [1 2 3 4 5])))))

;; ========== eduction ==========

(deftest test-eduction
  (testing "basic eduction"
    (let [ed (eduction (map inc) (filter even?) [1 2 3 4 5])]
      (is (= [2 4 6] (into [] ed)))))
  (testing "eduction is re-iterable"
    (let [ed (eduction (map inc) [1 2 3])]
      (is (= [2 3 4] (into [] ed)))
      (is (= [2 3 4] (into [] ed))))))

(run-tests)
