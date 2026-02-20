;; CLJW-ADD: Tests for destructuring
;; sequential, associative, nested, :keys, :strs, :as, :or

(ns clojure.test-clojure.destructuring
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== sequential ==========

(deftest test-sequential-destructuring
  (testing "basic vector destructuring"
    (let [[a b c] [1 2 3]]
      (is (= 1 a))
      (is (= 2 b))
      (is (= 3 c))))
  (testing "rest binding"
    (let [[a & rest] [1 2 3 4]]
      (is (= 1 a))
      (is (= [2 3 4] (vec rest)))))
  (testing ":as binding"
    (let [[a b :as all] [1 2 3]]
      (is (= 1 a))
      (is (= 2 b))
      (is (= [1 2 3] all))))
  (testing "fewer elements"
    (let [[a b c] [1 2]]
      (is (= 1 a))
      (is (= 2 b))
      (is (nil? c))))
  (testing "nested sequential"
    (let [[[a b] [c d]] [[1 2] [3 4]]]
      (is (= 1 a))
      (is (= 4 d)))))

;; ========== associative ==========

(deftest test-associative-destructuring
  (testing "basic map destructuring"
    (let [{a :a b :b} {:a 1 :b 2}]
      (is (= 1 a))
      (is (= 2 b))))
  (testing ":keys shorthand"
    (let [{:keys [x y z]} {:x 1 :y 2 :z 3}]
      (is (= 1 x))
      (is (= 2 y))
      (is (= 3 z))))
  (testing ":strs shorthand"
    (let [{:strs [a b]} {"a" 1 "b" 2}]
      (is (= 1 a))
      (is (= 2 b))))
  (testing ":or defaults"
    (let [{:keys [a b] :or {b 99}} {:a 1}]
      (is (= 1 a))
      (is (= 99 b))))
  (testing ":as binding"
    (let [{:keys [a] :as m} {:a 1 :b 2}]
      (is (= 1 a))
      (is (= {:a 1 :b 2} m))))
  (testing "missing keys are nil"
    (let [{:keys [x]} {:a 1}]
      (is (nil? x)))))

;; ========== fn args ==========

(deftest test-fn-destructuring
  (testing "fn with sequential destructuring"
    (let [f (fn [[a b]] (+ a b))]
      (is (= 3 (f [1 2])))))
  (testing "fn with map destructuring"
    (let [f (fn [{:keys [x y]}] (+ x y))]
      (is (= 3 (f {:x 1 :y 2})))))
  (testing "defn with destructuring"
    (letfn [(add-pair [[a b]] (+ a b))]
      (is (= 5 (add-pair [2 3]))))))

;; ========== nested ==========

(deftest test-nested-destructuring
  (testing "map inside vector"
    (let [[a {:keys [b c]}] [1 {:b 2 :c 3}]]
      (is (= 1 a))
      (is (= 2 b))
      (is (= 3 c))))
  (testing "vector inside map"
    (let [{[a b] :pair} {:pair [10 20]}]
      (is (= 10 a))
      (is (= 20 b)))))

;; ========== loop destructuring ==========

(deftest test-loop-destructuring
  (testing "loop with sequential"
    (is (= 6
           (loop [[x & xs] [1 2 3]
                  acc 0]
             (if x
               (recur xs (+ acc x))
               acc)))))
  (testing "loop with map"
    (is (= 3
           (loop [{:keys [a b]} {:a 1 :b 2}]
             (+ a b))))))

(run-tests)
