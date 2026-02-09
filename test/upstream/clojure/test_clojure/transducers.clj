;; Upstream: clojure/test/clojure/test_clojure/transducers.clj
;; Upstream lines: 410
;; CLJW markers: 10

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Alex Miller

(ns clojure.test-clojure.transducers
  ;; CLJW: removed clojure.test.check imports (property-based testing not available)
  (:require [clojure.string :as s]
            [clojure.test :refer :all]))

;; CLJW: skipped seq-and-transducer test — requires clojure.test.check (property-based testing)

;; CLJW: skipped test-transduce — requires JVM arrays (into-array, Integer/TYPE, etc.) and vector-of

(deftest test-dedupe
  (are [x y] (= (transduce (dedupe) conj x) y)
    [] []
    [1] [1]
    [1 2 3] [1 2 3]
    [1 2 3 1 2 2 1 1] [1 2 3 1 2 1]
    [1 1 1 2] [1 2]
    [1 1 1 1] [1]

    "" []
    "a" [\a]
    "aaaa" [\a]
    "aabaa" [\a \b \a]
    "abba" [\a \b \a]

    [nil nil nil] [nil]
             ;; CLJW: removed 1.0M (BigDecimal) and 1N (BigInt) — not supported
    [0.5 0.5] [0.5]))

(deftest test-cat
  (are [x y] (= (transduce cat conj x) y)
    [] []
    [[1 2]] [1 2]
    [[1 2] [3 4]] [1 2 3 4]
    [[] [3 4]] [3 4]
    [[1 2] []] [1 2]
    [[] []] []
    [[1 2] [3 4] [5 6]] [1 2 3 4 5 6]))

(deftest test-partition-all
  (are [n coll y] (= (transduce (partition-all n) conj coll) y)
    2 [1 2 3] '((1 2) (3))
    2 [1 2 3 4] '((1 2) (3 4))
    2 [] ()
    1 [] ()
    1 [1 2 3] '((1) (2) (3))
    5 [1 2 3] '((1 2 3))))

(deftest test-take
  (are [n y] (= (transduce (take n) conj [1 2 3 4 5]) y)
    1 '(1)
    3 '(1 2 3)
    5 '(1 2 3 4 5)
    9 '(1 2 3 4 5)
    0 ()
    -1 ()
    -2 ()))

(deftest test-drop
  (are [n y] (= (transduce (drop n) conj [1 2 3 4 5]) y)
    1 '(2 3 4 5)
    3 '(4 5)
    5 ()
    9 ()
    0 '(1 2 3 4 5)
    -1 '(1 2 3 4 5)
    -2 '(1 2 3 4 5)))

(deftest test-take-nth
  (are [n y] (= (transduce (take-nth n) conj [1 2 3 4 5]) y)
    1 '(1 2 3 4 5)
    2 '(1 3 5)
    3 '(1 4)
    4 '(1 5)
    5 '(1)
    9 '(1)))

(deftest test-take-while
  (are [coll y] (= (transduce (take-while pos?) conj coll) y)
    [] ()
    [1 2 3 4] '(1 2 3 4)
    [1 2 3 -1] '(1 2 3)
    [1 -1 2 3] '(1)
    [-1 1 2 3] ()
    [-1 -2 -3] ()))

(deftest test-drop-while
  (are [coll y] (= (transduce (drop-while pos?) conj coll) y)
    [] ()
    [1 2 3 4] ()
    [1 2 3 -1] '(-1)
    [1 -1 2 3] '(-1 2 3)
    [-1 1 2 3] '(-1 1 2 3)
    [-1 -2 -3] '(-1 -2 -3)))

(deftest test-re-reduced
  (is (= [:a] (transduce (take 1) conj [:a])))
  (is (= [:a] (transduce (comp (take 1) (take 1)) conj [:a])))
  (is (= [:a] (transduce (comp (take 1) (take 1) (take 1)) conj [:a])))
  (is (= [:a] (transduce (comp (take 1) (take 1) (take 1) (take 1)) conj [:a])))
  (is (= [[:a]] (transduce (comp (partition-by keyword?) (take 1)) conj [] [:a])))
  (is (= [[:a]] (sequence (comp (partition-by keyword?) (take 1)) [:a])))
  (is (= [[[:a]]] (sequence (comp (partition-by keyword?) (take 1)  (partition-by keyword?) (take 1)) [:a])))
  (is (= [[0]] (transduce (comp (take 1) (partition-all 3) (take 1)) conj [] (range 15))))
  ;; CLJW: removed long-array test — JVM interop
  )

;; CLJW: skipped test-sequence-multi-xform — requires TransformerIterator.createMulti (JVM)

;; CLJW: eduction now implemented via sequence (eager), tests revived
(deftest test-eduction
  (testing "one xform"
    (is (= [1 2 3 4 5]
           (eduction (map inc) (range 5)))))
  (testing "multiple xforms"
    (is (= ["2" "4"]
           (eduction (map inc) (filter even?) (map str) (range 5)))))
  (testing "materialize at the end"
    (is (= [1 1 1 1 2 2 2 3 3 4]
           (->> (range 5)
                (eduction (mapcat range) (map inc))
                sort)))
    ;; CLJW: to-array is JVM interop; use vec directly
    (is (= [1 1 2 1 2 3 1 2 3 4]
           (vec (->> (range 5)
                     (eduction (mapcat range) (map inc))))))
    (is (= {1 4, 2 3, 3 2, 4 1}
           (->> (range 5)
                (eduction (mapcat range) (map inc))
                frequencies)))
    (is (= ["drib" "god" "hsif" "kravdraa" "tac"]
           (->> ["cat" "dog" "fish" "bird" "aardvark"]
                (eduction (map clojure.string/reverse))
                (sort-by first)))))
  (testing "expanding transducer with nils"
    (is (= '(1 2 3 nil 4 5 6 nil)
           (eduction cat [[1 2 3 nil] [4 5 6 nil]])))))

(deftest test-eduction-completion
  (testing "eduction completes inner xformed reducing fn"
    (is (= [[0 1 2] [3 4 5] [6 7]]
           (into []
                 (comp cat (partition-all 3))
                 (eduction (partition-all 5) (range 8))))))
  (testing "outer reducing fn completed only once"
    (let [counter (atom 0)
          ;; outer rfn
          rf      (completing conj #(do (swap! counter inc)
                                        (vec %)))
          coll    (eduction  (map inc) (range 5))
          res     (transduce (map str) rf [] coll)]
      (is (= 1 @counter))
      (is (= ["1" "2" "3" "4" "5"] res)))))

(deftest test-run!
  (is (nil? (run! identity [1])))
  (is (nil? (run! reduced (range)))))

(deftest test-distinct
  (are [out in] (= out (sequence (distinct) in))
    [] []
    (range 10) (range 10)
    [0] (repeat 10 0)
    [0 1 2] [0 0 1 1 2 2 1 1 0 0]
       ;; CLJW: removed 1N test — BigInt not supported
    ))

(deftest test-interpose
  (are [out in] (= out (sequence (interpose :s) in))
    [] (range 0)
    [0] (range 1)
    [0 :s 1] (range 2)
    [0 :s 1 :s 2] (range 3))
  (testing "Can end reduction on separator or input"
    (let [expected (interpose :s (range))]
      (dotimes [i 10]
        (is (= (take i expected)
               (sequence (comp (interpose :s) (take i))
                         (range))))))))

(deftest test-map-indexed
  (is (= []
         (sequence (map-indexed vector) [])))
  (is (= [[0 1] [1 2] [2 3] [3 4]]
         (sequence (map-indexed vector) (range 1 5)))))

(deftest test-into+halt-when
  (is (= :anomaly (into [] (comp (filter some?) (halt-when #{:anomaly}))
                        [1 2 3 :anomaly 4])))
  (is (= {:anomaly :oh-no!,
          :partial-results [1 2]}
         (into []
               (halt-when :anomaly #(assoc %2 :partial-results %1))
               [1 2 {:anomaly :oh-no!} 3 4]))))

;; CLJW-ADD: test runner invocation
(run-tests)
