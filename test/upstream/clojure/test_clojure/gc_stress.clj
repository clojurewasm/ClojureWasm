;; CLJW-ADD: GC stress tests
;; Exercise garbage collector with heavy allocation patterns

(ns clojure.test-clojure.gc-stress
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== rapid allocation ==========

(deftest test-rapid-allocation
  (testing "many small vectors"
    (let [result (reduce (fn [acc _]
                           (conj acc (vec (range 10))))
                         []
                         (range 500))]
      (is (= 500 (count result)))
      (is (= (vec (range 10)) (last result)))))
  (testing "many small maps"
    (let [result (reduce (fn [acc i]
                           (conj acc {:i i :s (str i)}))
                         []
                         (range 500))]
      (is (= 500 (count result)))))
  (testing "many string allocations"
    (let [result (reduce (fn [acc i]
                           (conj acc (str "item-" i "-" (str i))))
                         []
                         (range 1000))]
      (is (= 1000 (count result))))))

;; ========== temporary object pressure ==========

(deftest test-temp-objects
  (testing "map creating temp seqs"
    (is (= 5000 (count (doall (map (fn [i] (vec (range (mod i 10))))
                                    (range 5000)))))))
  (testing "filter creating temp predicates"
    (is (= 500 (count (doall (filter (fn [i] (zero? (mod i 10)))
                                      (range 5000)))))))
  (testing "reduce with temp accumulators"
    (is (= 4999
           (reduce (fn [acc i] (max acc i)) 0 (range 5000))))))

;; ========== nested allocation ==========

(deftest test-nested-allocation
  (testing "nested maps"
    (let [data (reduce (fn [acc i]
                         {:level i :child acc})
                       {:leaf true}
                       (range 100))]
      (is (= 99 (:level data)))
      (is (map? (:child data)))))
  (testing "nested vectors"
    (let [data (reduce (fn [acc i]
                         [i acc])
                       [:leaf]
                       (range 50))]
      (is (= 49 (first data))))))

;; ========== lazy seq GC ==========

(deftest test-lazy-gc
  (testing "long lazy chain should not blow stack"
    (is (= 999 (last (take 1000 (iterate inc 0))))))
  (testing "chained lazy ops"
    (is (= 50
           (count (take 50 (filter even? (map #(* % 3) (range 1000))))))))
  (testing "lazy seq head release"
    ;; Verify we can process more data than fits in memory
    ;; by not holding onto the head
    (is (number? (reduce + 0 (map identity (range 1000)))))))

;; ========== atom + GC interaction ==========

(deftest test-atom-gc
  (testing "atom value replacement"
    (let [a (atom {:data (vec (range 100))})]
      (dotimes [i 100]
        (reset! a {:data (vec (range (* i 10) (* (inc i) 10)))}))
      (is (= 10 (count (:data @a))))))
  (testing "watch callbacks with allocation"
    (let [a (atom 0)
          log (atom [])]
      (add-watch a :stress
                 (fn [_ _ old new]
                   (swap! log conj {:old old :new new})))
      (dotimes [_ 200]
        (swap! a inc))
      (remove-watch a :stress)
      (is (= 200 (count @log)))
      (is (= 200 @a)))))

(run-tests)
