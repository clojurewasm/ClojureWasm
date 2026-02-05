;; Upstream: clojure/test/clojure/test_clojure/vectors.clj
;; Upstream lines: 492
;; CLJW markers: 16

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this distribution.

; Author: Stuart Halloway, Daniel Solano Gómez

(ns clojure.test-clojure.vectors
  (:use clojure.test)) ;; CLJW: removed Java imports (Collection, Spliterator, Consumer, Collectors)

;; CLJW: test-reversed-vec — SKIP (vector-of, JVM .rseq/.index/.first/.next/.count)
;; CLJW: test-vecseq — SKIP (vector-of, JVM .chunkedNext/.empty/.cons/.count/.equiv)
;; CLJW: test-primitive-subvector-reduce — SKIP (vector-of :long)

(deftest test-vec-compare
  ;; CLJW: removed vector-of :int/:long, testing only regular vectors
  (let [nums      (range 1 100)
        rand-replace  (fn [val]
                        (let [r (rand-int 99)]
                          (concat (take r nums) [val] (drop (inc r) nums))))
        num-seqs      {:standard       nums
                       :empty          '()
                       :longer         (concat nums [100])
                       :shorter        (drop-last nums)
                       :first-greater  (concat [100] (next nums))
                       :last-greater   (concat (drop-last nums) [100])
                       :rand-greater-1 (rand-replace 100)
                       :rand-greater-2 (rand-replace 100)
                       :rand-greater-3 (rand-replace 100)
                       :first-lesser   (concat [0] (next nums))
                       :last-lesser    (concat (drop-last nums) [0])
                       :rand-lesser-1  (rand-replace 0)
                       :rand-lesser-2  (rand-replace 0)
                       :rand-lesser-3  (rand-replace 0)}
        regular-vecs  (zipmap (keys num-seqs)
                              (map #(into [] %1) (vals num-seqs)))
        ref-vec       (:standard regular-vecs)]
    (testing "compare"
      (testing "identical"
        (is (= 0 (compare ref-vec ref-vec))))
      (testing "equivalent"
        (are [x y] (= 0 (compare x y))
          ref-vec (:standard regular-vecs)))
      (testing "lesser"
        (are [x] (= -1 (compare ref-vec x))
          (:longer regular-vecs)
          (:first-greater regular-vecs)
          (:last-greater regular-vecs)
          (:rand-greater-1 regular-vecs)
          (:rand-greater-2 regular-vecs)
          (:rand-greater-3 regular-vecs))
        (are [x] (= -1 (compare x ref-vec))
          nil
          (:empty regular-vecs)
          (:shorter regular-vecs)
          (:first-lesser regular-vecs)
          (:last-lesser regular-vecs)
          (:rand-lesser-1 regular-vecs)
          (:rand-lesser-2 regular-vecs)
          (:rand-lesser-3 regular-vecs)))
      (testing "greater"
        (are [x] (= 1 (compare ref-vec x))
          nil
          (:empty regular-vecs)
          (:shorter regular-vecs)
          (:first-lesser regular-vecs)
          (:last-lesser regular-vecs)
          (:rand-lesser-1 regular-vecs)
          (:rand-lesser-2 regular-vecs)
          (:rand-lesser-3 regular-vecs))
        (are [x] (= 1 (compare x ref-vec))
          (:longer regular-vecs)
          (:first-greater regular-vecs)
          (:last-greater regular-vecs)
          (:rand-greater-1 regular-vecs)
          (:rand-greater-2 regular-vecs)
          (:rand-greater-3 regular-vecs))))))

;; CLJW: test-vec-associative — SKIP .containsKey/.entryAt/MapEntry (JVM interop)
;; Ported only contains? tests
(deftest test-vec-contains
  (let [v (vec (range 1 6))]
    (testing "contains?"
      (are [x] (contains? v x)
        0 2 4)
      (are [x] (not (contains? v x))
        -1 -100 nil "" 5 100)
      (are [x] (not (contains? [] x))
        0 1))))

;; CLJW: test-vec-creation — SKIP (vector-of, clojure.core.Vec, clojure.lang.IPersistentVector)

(deftest empty-vector-equality
  ;; CLJW: removed vector-of :long
  (let [colls [[] '()]]
    (doseq [c1 colls, c2 colls]
      (is (= c1 c2)))))

(defn =vec
  [expected v] (and (vector? v) (= expected v)))

(deftest test-mapv
  (are [r c1] (=vec r (mapv + c1))
    [1 2 3] [1 2 3])
  (are [r c1 c2] (=vec r (mapv + c1 c2))
    [2 3 4] [1 2 3] (repeat 1))
  (are [r c1 c2 c3] (=vec r (mapv + c1 c2 c3))
    [3 4 5] [1 2 3] (repeat 1) (repeat 1))
  (are [r c1 c2 c3 c4] (=vec r (mapv + c1 c2 c3 c4))
    [4 5 6] [1 2 3] [1 1 1] [1 1 1] [1 1 1]))

(deftest test-filterv
  (are [r c1] (=vec r (filterv even? c1))
    [] [1 3 5]
    [2 4] [1 2 3 4 5]))

(deftest test-subvec
  (let [v1 (vec (range 100))
        v2 (subvec v1 50 57)]
    ;; CLJW: replaced IndexOutOfBoundsException with Exception
    (is (thrown? Exception (v2 -1)))
    (is (thrown? Exception (v2 7)))
    (is (= (v1 50) (v2 0)))
    (is (= (v1 56) (v2 6)))))

(deftest test-vec
  (is (= [1 2] (vec (first {1 2}))))
  (is (= [0 1 2 3] (vec [0 1 2 3])))
  (is (= [0 1 2 3] (vec (list 0 1 2 3))))
  (is (= [0 1 2 3] (vec (sorted-set 0 1 2 3))))
  (is (= [[1 2] [3 4]] (vec (sorted-map 1 2 3 4))))
  (is (= [0 1 2 3] (vec (range 4))))
  (is (= [\a \b \c \d] (vec "abcd"))))
  ;; CLJW: removed object-array, eduction, reify tests (JVM interop)

(deftest test-reduce-kv-vectors
  (is (= 25 (reduce-kv + 10 [2 4 6])))
  (is (= 25 (reduce-kv + 10 (subvec [0 2 4 6] 1)))))

(deftest test-vector-eqv-to-non-counted-types
  (is (not= (range) [0 1 2]))
  (is (not= [0 1 2] (range)))
  (is (= [0 1 2] (take 3 (range))))
  ;; CLJW: removed java.util.ArrayList test (JVM interop)
  (is (not= [1 2] (take 1 (cycle [1 2])))))
  ;; CLJW: removed eduction test

;; CLJW: SKIP test-empty-vector-spliterator (JVM Spliterator/Consumer)
;; CLJW: SKIP test-spliterator-tryadvance-then-forEach (JVM Spliterator)
;; CLJW: SKIP test-spliterator-trySplit (JVM Spliterator)
;; CLJW: SKIP test-vector-parallel-stream (JVM Stream/parallelStream)

(run-tests)
