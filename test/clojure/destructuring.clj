;; destructuring.clj - Tests for destructuring in for/doseq

(ns clojure.destructuring
  (:require [clojure.test :refer [deftest is testing]]))

(deftest for-vector-destructuring
  (testing "for + vector destructuring"
    (is (= [3 7] (vec (for [[a b] [[1 2] [3 4]]] (+ a b)))))))

(deftest for-map-destructuring
  (testing "for + map :keys destructuring"
    (is (= [3] (vec (for [{:keys [x y]} [{:x 1 :y 2}]] (+ x y)))))))

(deftest for-syms-destructuring
  (testing "for + :syms destructuring"
    (is (= [1 2] (vec (for [{:syms [a]} [{'a 1} {'a 2}]] a))))))

(deftest for-nested-destructuring
  (testing "for + nested destructuring"
    (is (= [6] (vec (for [[a [b c]] [[1 [2 3]]]] (+ a b c)))))))

(deftest for-as-binding
  (testing "for + :as binding"
    (is (= [[1 [1 2 3]]] (vec (for [[a :as all] [[1 2 3]]] [a all]))))))

(deftest for-with-when
  (testing "for + destructuring combined with :when"
    (is (= [3 7 11] (vec (for [[a b] [[1 2] [3 4] [5 6]] :when (odd? a)] (+ a b)))))))

(deftest doseq-map-destructuring
  (testing "doseq + map destructuring"
    (let [result (atom [])]
      (doseq [{:keys [a]} [{:a 1} {:a 2}]]
        (swap! result conj a))
      (is (= [1 2] @result)))))
