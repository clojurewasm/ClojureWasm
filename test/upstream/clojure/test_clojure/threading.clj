;; CLJW-ADD: Tests for threading macros and control flow
;; ->, ->>, as->, some->, some->>, cond->, cond->>

(ns clojure.test-clojure.threading
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== -> (thread first) ==========

(deftest test-thread-first
  (testing "basic thread first"
    (is (= 3 (-> 5 (- 2))))
    (is (= "HELLO" (-> "hello" .toUpperCase))))
  (testing "multi-step"
    (is (= 3 (-> [1 2 3 4 5]
                 (nth 2)))))
  (testing "no forms"
    (is (= 42 (-> 42))))
  (testing "with string ops"
    (is (= "bc" (-> "abc" (subs 1))))))

;; ========== ->> (thread last) ==========

(deftest test-thread-last
  (testing "basic thread last"
    (is (= [2 4 6] (->> [1 2 3] (map #(* 2 %))))))
  (testing "multi-step"
    (is (= 6 (->> (range 1 4) (reduce +)))))
  (testing "filter + map"
    (is (= [2 4] (->> (range 1 6)
                      (filter even?)
                      (into []))))))

;; ========== as-> ==========

(deftest test-as-thread
  (testing "basic as->"
    (is (= 3 (as-> 5 x (- x 2)))))
  (testing "mixed position"
    (is (= [1 2 3]
           (as-> {} m
             (assoc m :a [1 2 3])
             (:a m))))))

;; ========== some-> ==========

(deftest test-some-thread
  (testing "all non-nil"
    (is (= 3 (some-> {:a {:b 3}} :a :b))))
  (testing "nil short-circuit"
    (is (nil? (some-> {:a nil} :a :b))))
  (testing "nil at start"
    (is (nil? (some-> nil :a)))))

;; ========== some->> ==========

(deftest test-some-thread-last
  (testing "all non-nil"
    (is (= 6 (some->> [1 2 3] (reduce +)))))
  (testing "nil short-circuit"
    (is (nil? (some->> nil (map inc))))))

;; ========== cond-> ==========

(deftest test-cond-thread
  (testing "conditional threading"
    (is (= 3 (cond-> 1
               true (+ 1)
               false (* 10)
               true (+ 1)))))
  (testing "all false"
    (is (= 1 (cond-> 1
               false (+ 1)
               false (* 10))))))

;; ========== cond->> ==========

(deftest test-cond-thread-last
  (testing "conditional thread last"
    (is (= [2 3 4] (cond->> [1 2 3]
                     true (map inc)
                     false (filter even?))))))

(run-tests)
