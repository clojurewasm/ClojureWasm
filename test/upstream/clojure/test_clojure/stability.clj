;; CLJW-ADD: Long-run stability tests
;; Many evaluations, large data, repeated GC pressure

(ns clojure.test-clojure.stability
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== repeated evaluations ==========

(deftest test-many-evaluations
  (testing "1000 map operations"
    (is (= 1000
           (count (doall (map (fn [i] (assoc {} :i i :s (str i)))
                              (range 1000)))))))
  (testing "1000 vector builds"
    (is (= 1000
           (count (reduce (fn [acc i] (conj acc i)) [] (range 1000))))))
  (testing "1000 string concatenations"
    (let [sb (StringBuilder.)]
      (doseq [i (range 1000)]
        (.append sb (str i)))
      (is (> (.length sb) 2000))))
  (testing "1000 atom swaps"
    (let [a (atom 0)]
      (doseq [_ (range 1000)]
        (swap! a inc))
      (is (= 1000 @a)))))

;; ========== large collections ==========

(deftest test-large-collections
  (testing "large vector"
    (let [v (vec (range 10000))]
      (is (= 10000 (count v)))
      (is (= 0 (first v)))
      (is (= 9999 (last v)))))
  (testing "large map"
    (let [m (zipmap (range 1000) (range 1000))]
      (is (= 1000 (count m)))
      (is (= 500 (get m 500)))))
  (testing "large set"
    (let [s (set (range 5000))]
      (is (= 5000 (count s)))
      (is (contains? s 4999)))))

;; ========== nested computation ==========

(deftest test-nested-computation
  (testing "deep reduce chains"
    (is (= 499000
           (->> (range 1000)
                (filter even?)
                (map #(* % 2))
                (reduce +)))))
  (testing "nested maps"
    (let [data (reduce (fn [acc i]
                         (assoc acc (keyword (str "k" i)) i))
                       {} (range 100))]
      (is (= 100 (count data)))
      (is (= 50 (:k50 data)))))
  (testing "repeated transducer application"
    (let [xf (comp (map inc) (filter even?) (take 10))]
      (dotimes [_ 100]
        (is (= 10 (count (into [] xf (range 100)))))))))

;; ========== lazy seq realization ==========

(deftest test-lazy-realization
  (testing "realize large lazy seq"
    (is (= 4999 (last (take 5000 (iterate inc 0))))))
  (testing "chained lazy operations"
    (is (= 100
           (count (take 100 (filter even? (map inc (range))))))))
  (testing "multiple lazy seq walks"
    (let [s (map inc (range 1000))]
      ;; realize the same lazy seq multiple times
      (is (= 1000 (count s)))
      (is (= 1 (first s)))
      (is (= 1000 (last s))))))

;; ========== recursive functions ==========

(deftest test-recursion
  (testing "deep recursion with loop/recur"
    (is (= 100000
           (loop [i 0]
             (if (= i 100000) i (recur (inc i)))))))
  (testing "fibonacci with memoize"
    (let [fib (memoize (fn fib [n]
                         (cond
                           (<= n 0) 0
                           (= n 1) 1
                           :else (+ (fib (dec n)) (fib (- n 2))))))]
      (is (= 55 (fib 10)))
      (is (= 6765 (fib 20))))))

(run-tests)
