;; Sequence-helper coverage migrated from test/e2e/phase14_seq_helpers2.sh,
;; test/e2e/phase14_seq_core_batch.sh, and
;; test/e2e/phase14_reductions_splitat.sh, plus doseq coverage from
;; test/e2e/phase14_doseq.sh and for coverage from
;; test/e2e/phase14_for.sh + test/e2e/phase15_for_while.sh.
;; These are value/runtime assertions, so the native clojure.test runner gives
;; the same coverage in one cljw process without repeated shell/CLI startup.
(ns suites.seq-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest empty-predicate
  (is (true? (empty? [])))
  (is (false? (empty? [1])))
  (is (true? (empty? nil))))

(deftest interpose-values
  (is (= [1 :s 2 :s 3] (into [] (interpose :s [1 2 3]))))
  (is (= [1] (into [] (interpose :s [1]))))
  (is (= [] (into [] (interpose :s [])))))

(deftest interpose-realization-is-lazy
  (let [calls (atom 0)
        xs (interpose :s (take 3 (repeatedly #(swap! calls inc))))]
    (is (= 0 @calls))
    (is (= 1 (first xs)))
    (is (= 1 @calls))
    (is (= :s (second xs)))
    (is (= 2 @calls))
    (is (= 2 (nth xs 2)))
    (is (= 2 @calls)))
  (is (= [:x :s :x :s :x]
         (into [] (take 5 (interpose :s (repeat :x)))))))

(deftest sequence-helper-transducers
  (is (= [1 0 2 0 3] (into [] (interpose 0) [1 2 3])))
  (is (= [3 4] (into [] (drop-while neg?) [-1 -2 3 4])))
  (is (= [3] (into [] (comp (drop-while neg?) (take 1)) [-1 3 4 5]))))

(deftest fnil-arities
  (is (= 1 ((fnil inc 0) nil)))
  (is (= 6 ((fnil inc 0) 5)))
  (is (= 0 ((fnil + 0 0) nil nil)))
  (is (= 15 ((fnil + 10 20) nil 5)))
  (is (= [1 2 3]
         ((fnil (fn [a b c] [a b c]) 1 2 3) nil nil nil)))
  (is (= 6 ((fnil + 0) nil 1 2 3))))

(deftest zipmap-semantics
  (is (= 2 (get (zipmap [:a :b] [1 2]) :b)))
  (is (= {:a 2} (zipmap [:a :a] [1 2])))
  (is (= 5000 (count (zipmap (range 5000) (range 5000))))))

(deftest interleave-semantics
  (is (= [1 :a 2 :b] (into [] (interleave [1 2] [:a :b]))))
  (is (= [1 :a 2 :b] (into [] (interleave [1 2 3] [:a :b]))))
  (is (= 100000 (count (interleave (range 50000) (range 50000)))))
  (is (= '(1 3 5 2 4 6) (interleave [1 2] [3 4] [5 6])))
  (is (= '(1 2) (interleave [1 2])))
  (is (true? (seq? (interleave [1] [2])))))

(deftest split-with-semantics
  (is (= [[1 2] [3 4 1]]
         (mapv vec (split-with #(< % 3) [1 2 3 4 1]))))
  (is (= [[1 2] []]
         (mapv vec (split-with #(< % 9) [1 2]))))
  (let [calls (atom 0)
        parts (split-with (fn [x]
                            (swap! calls inc)
                            (< x 3))
                          [1 2 3 4])]
    (is (= 0 @calls))
    (is (= 1 (first (first parts))))
    (is (= 1 @calls))
    (is (= 3 (first (second parts))))
    ;; The two lazy halves traverse independently, like JVM Clojure.
    (is (= 4 @calls))))

(deftest take-nth-semantics
  (is (= '(1 3 5) (take-nth 2 [1 2 3 4 5 6])))
  (is (= '(0 3 6) (take-nth 3 [0 1 2 3 4 5 6])))
  (let [calls (atom 0)
        xs (take-nth 2 (take 5 (repeatedly #(swap! calls inc))))]
    (is (= 0 @calls))
    (is (= 1 (first xs)))
    (is (= 1 @calls))
    (is (= 3 (second xs)))
    (is (= 3 @calls)))
  ;; JVM's collection arity repeats the first item forever when n <= 0:
  ;; `(drop n s)` returns s unchanged.
  (is (= '(1 1 1 1) (take 4 (take-nth 0 [1 2]))))
  (is (= '(1 1 1 1) (take 4 (take-nth -2 [1 2])))))

(deftest list-star-semantics
  (is (= '(1 2 3) (list* [1 2 3])))
  (is (= '(1 2 3 4) (list* 1 [2 3 4])))
  (is (= '(1 2 3 4) (list* 1 2 [3 4])))
  (is (= '(a b c) (list* 'a '(b c))))
  (is (= '(1 2 3 4 5 6 7) (list* 1 2 3 4 5 [6 7])))
  #_{:clj-kondo/ignore [:invalid-arity]}
  (is (thrown? Throwable (list*))))

(deftest reductions-semantics
  (is (= [1 3 6] (vec (reductions + [1 2 3]))))
  (is (= [1 2 6 24] (vec (reductions * [1 2 3 4]))))
  (is (= [0] (vec (reductions + []))))
  (is (= [10 11 13 16] (vec (reductions + 10 [1 2 3]))))
  (is (= [0 1 3 6 10 15] (vec (take 6 (reductions + (range))))))
  (is (= [0 1 3 6 6]
         (vec (reductions (fn [acc x]
                            (if (> acc 5)
                              (reduced acc)
                              (+ acc x)))
                          0
                          [1 2 3 4 5 6])))))

(deftest reductions-realization-is-lazy
  (let [calls (atom 0)
        xs (reductions + (take 3 (repeatedly #(swap! calls inc))))
        before @calls
        value-0 (first xs)
        after-0 @calls
        value-1 (second xs)
        after-1 @calls
        value-2 (nth xs 2)
        after-2 @calls]
    (is (= [0 1 1 3 2 6 3]
           [before value-0 after-0 value-1 after-1 value-2 after-2]))))

(deftest split-at-semantics
  (is (= [[1 2] [3 4]] (mapv vec (split-at 2 [1 2 3 4]))))
  (is (= [[] [1 2 3]] (mapv vec (split-at 0 [1 2 3]))))
  (is (= [[1 2 3] []] (mapv vec (split-at 10 [1 2 3]))))
  #_{:clj-kondo/ignore [:type-mismatch]}
  (is (= [[] [1 2 3]] (mapv vec (split-at -1 [1 2 3]))))
  (let [[left right] (split-at 2 [1 2 3 4])]
    (is (= [1 2] (vec left)))
    (is (= [3 4] (vec right))))
  (let [calls (atom 0)
        parts (split-at 2 (take 4 (repeatedly #(swap! calls inc))))
        before @calls
        left-first (first (first parts))
        after-left @calls
        right-first (first (second parts))
        after-right @calls]
    (is (= [0 1 1 3 3]
           [before left-first after-left right-first after-right]))))

(deftest doseq-semantics
  (let [seen (atom [])
        ret (doseq [x [1 2 3]]
              (swap! seen conj x))]
    (is (nil? ret))
    (is (= [1 2 3] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2 3 4] :when (odd? x)]
      (swap! seen conj x))
    (is (= [1 3] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2 3 4] :while (< x 3)]
      (swap! seen conj x))
    (is (= [1 2] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2 3] :let [y (* x 10)]]
      (swap! seen conj y))
    (is (= [10 20 30] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2] y [3 4]]
      (swap! seen conj (+ x y)))
    (is (= [4 5 5 6] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2 3] :when (odd? x) y [0 1]]
      (swap! seen conj (+ x y)))
    (is (= [1 2 3 4] @seen)))
  (let [seen (atom [])]
    (doseq [x []]
      (swap! seen conj x))
    (is (= [] @seen)))
  (let [seen (atom [])]
    (doseq [x [1 2] y [10 20] :while (< y 15)]
      (swap! seen conj [x y]))
    (is (= [[1 10] [2 10]] @seen)))
  (let [seen (atom [])]
    (doseq [[a b] [[1 2] [3 4]]]
      (swap! seen conj (+ a b)))
    (is (= [3 7] @seen)))
  (is (thrown? Throwable
               (eval '(doseq [x] (print x))))))

(deftest for-semantics
  (is (= [1 4 9] (vec (for [x [1 2 3]] (* x x)))))
  (is (= [1 3] (vec (for [x [1 2 3 4] :when (odd? x)] x))))
  (is (= [10 20 30] (vec (for [x [1 2 3] :let [y (* x 10)]] y))))
  (is (= [20 30]
         (vec (for [x [1 2 3] :let [y (* x 10)] :when (> y 15)] y))))
  (is (= [[1 :a] [1 :b] [2 :a] [2 :b]]
         (vec (for [x [1 2] y [:a :b]] [x y]))))
  (is (= [1 2 3 4]
         (vec (for [x [1 2 3] :when (odd? x) y [0 1]] (+ x y)))))
  (is (= [3 7] (vec (for [[a b] [[1 2] [3 4]]] (+ a b)))))
  (is (= [0 1 4 9] (vec (take 4 (for [x (range)] (* x x))))))
  (is (= [0 2 4] (vec (for [x (range 5) :when (even? x)] x))))
  (is (= [] (vec (for [x []] x))))
  (is (= [1 2] (vec (for [x [1 2 3 4 5] :while (< x 3)] x))))
  (is (= [1 3]
         (vec (for [x (range 10) :while (< x 4) :when (odd? x)] x))))
  (is (= [1]
         (vec (for [x [1 2] :let [y x] :while (< y 2)] y))))
  (is (= [1]
         (vec (for [a (range 5) :when (> a 0) :while (odd? a)] a))))
  (is (= [1 3]
         (vec (for [a (range 5) :when (odd? a) :while (< a 4)] a))))
  (is (= [[0 0] [1 2]]
         (vec (for [x (range 5)
                   :let [a (* x 2)]
                   :while (< a 4)]
                [x a]))))
  (is (= [[1 0] [3 0]]
         (vec (for [x (range 4)
                   :when (odd? x)
                   y (range 2)
                   :while (odd? (+ x y))]
                [x y]))))
  (is (= [[0 0] [0 1] [1 0] [1 1] [2 0] [2 1]]
         (vec (for [x (range 3) y (range 2)] [x y]))))
  (is (= [0 2 4 6]
         (vec (take 4 (for [x (range) :when (even? x)] x))))))

(deftest for-realization-is-lazy
  (let [source-calls (atom 0)
        xs (for [x (take 3 (repeatedly #(swap! source-calls inc)))]
             (* x x))
        before @source-calls
        value-0 (first xs)
        after-0 @source-calls
        value-1 (second xs)
        after-1 @source-calls]
    (is (= [0 1 1 4 2]
           [before value-0 after-0 value-1 after-1])))
  (let [predicate-calls (atom 0)
        xs (for [x (list 0 1 2 3 4)
                :when (do (swap! predicate-calls inc) (odd? x))]
             x)
        before @predicate-calls
        value-0 (first xs)
        after-0 @predicate-calls
        value-1 (second xs)
        after-1 @predicate-calls]
    (is (= [0 1 2 3 4]
           [before value-0 after-0 value-1 after-1]))))
