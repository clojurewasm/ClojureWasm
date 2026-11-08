(ns suites.sequence-boundaries-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest cons-empty-tail-identity
  (doseq [tail [nil "" '() #{} {} []]]
    (let [s (cons 1 tail)]
      (is (= [1] (vec s)))
      (is (= 1 (count s)))
      (is (= (nil? tail) (list? s)))
      (is (nil? (next s))))))

(deftest list-construction-from-seqables
  (doseq [source [nil [0 1 2] (range 3) (map identity (range 3))
                  "ab" (with-meta '(0 1 2) {:source true})]]
    (let [result (apply list source)]
      (is (list? result))
      (is (= (vec source) (vec result)))
      (is (nil? (meta result)))))
  (let [source '(0 1 2)]
    (is (false? (identical? source (apply list source)))))
  (let [seen (atom [])
        result (apply list (map (fn [x] (swap! seen conj x) x) (range 4)))]
    (is (list? result))
    (is (= [0 1 2 3] @seen))))

(deftest concat-and-mapcat-realization
  (let [s (concat)]
    (is (false? (realized? s)))
    (is (empty? s))
    (is (true? (realized? s))))
  (is (= [\h \i] (vec (concat "hi"))))
  (is (= [\h \i] (vec (mapcat identity ["hi"]))))
  (is (= [1 2] (vec (concat (int-array [1 2])))))
  (is (= [0 1 2 3 4] (vec (take 5 (apply concat (map vector (iterate inc 0)))))))
  (let [seen (atom [])
        s (mapcat (fn [x] (swap! seen conj x) [x]) (iterate inc 0))]
    (is (= [0 1 2 3] @seen))
    (is (= [0 1 2 3 4] (vec (take 5 s)))))
  (is (thrown? Exception (mapcat 1 [2])))
  (is (thrown? Exception (mapcat vector 1))))

(deftest apply-bounded-prefix-and-method-selection
  (let [f (fn ([] :zero) ([a] [:one a]) ([a b] [:two a b])
            ([a b & xs] [:many a b (vec (take 2 xs))]))]
    (is (= [:zero [:one 0] [:two 0 1] [:many 0 1 [2]] [:many 0 1 [2 3]]]
           (mapv #(apply f (take % (iterate inc 0))) (range 5))))
    (is (= [:two 1 2] (apply f 1 2 nil))))
  (let [seen (atom [])
        result (apply (fn [a b & xs] [a b (first xs)])
                      (map (fn [x] (swap! seen conj x) x) (iterate inc 0)))]
    (is (= [0 1 2] result))
    (is (= [0 1 2 3] @seen)))
  (let [seen (atom 0)]
    (is (= 1 (apply (fn [a & xs] a) 1 2 3
                    (map (fn [x] (swap! seen inc) x) (iterate inc 0)))))
    (is (= 0 @seen)))
  (is (= [1 [2 3] true] (apply (fn [a & xs] [a (vec xs) (seq? xs)]) [1 2 3])))
  (is (= [[0] [1] [2]]
         (apply (fn [a b & xs] (System/gc) [a b (first xs)])
                (map (fn [x] (System/gc) [x]) (iterate inc 0))))))

(deftest sequence-invocation-boundaries
  (is (= [:x :x] (vec (repeat 2.9 :x))))
  (is (thrown? Exception (repeat :bad :x)))
  (is (thrown? Exception (cycle 1)))
  (is (= [1 2 1 2 1] (vec (take 5 (cycle [1 2])))))
  (is (nil? (nthnext nil nil)))
  (is (= {} (select-keys 1 [])))
  (is (= {} (select-keys #{1} nil)))
  (is (thrown? Exception (shuffle nil)))
  (is (thrown? ClassCastException (shuffle "abc")))
  (is (= #{1 2 3} (set (shuffle #{1 2 3}))))
  (is (thrown? NullPointerException (subvec nil 0 0)))
  (is (thrown? ClassCastException (subvec '(1 2) 0 1)))
  (is (= [2] (subvec [0 1 2] 2.72 3.14))))
