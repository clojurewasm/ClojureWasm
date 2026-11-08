;; range (0/1/2/3-arg) + map-indexed / keep-indexed — migrated from
;; test/e2e/phase14_range_indexed.sh (Phase 14 §9.16 row 14.13, D-134/D-168,
;; ADR-0063 + its 2026-08-28 full-i64 amendment).
;;
;; Every bash case asserted a printed VALUE, so all of them migrate. Cases the
;; bash asserted by rendering a seq (`(range 3)` -> `(0 1 2)`) keep BOTH halves:
;; the `=` value and the `pr-str` rendering, because the render is what proved
;; the result is a seq/list rather than a vector.
(ns suites.range-indexed-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- range: the finite arities ---
(deftest range-basic-arities
  (testing "1-arg / 2-arg / empty"
    (is (= [0 1 2 3] (into [] (range 4))))
    (is (= [2 3 4] (into [] (range 2 5))))
    (is (= [] (into [] (range 0))))))

;; D-168: finite-arity range is a lazy SEQ (was an eager vector). seq? is true,
;; it prints as a list, and conj prepends (vs the old vector append).
(deftest range-is-a-seq
  (testing "seq? holds for 1-arg and 2-arg"
    (is (= true (seq? (range 3))))
    (is (= true (seq? (range 2 5)))))
  (testing "renders as a list"
    (is (= '(0 1 2) (range 3)))
    (is (= "(0 1 2)" (pr-str (range 3)))))
  (testing "conj prepends"
    (is (= '(99 0 1 2) (conj (range 3) 99)))
    (is (= "(99 0 1 2)" (pr-str (conj (range 3) 99))))))

;; Laziness is observable: take over a huge range must NOT realize it all.
(deftest range-laziness
  (is (= [0 1 2 3 4] (into [] (take 5 (range 1000000000))))))

(deftest take-realization-is-lazy
  (let [calls (atom 0)
        xs (take 2 (repeatedly #(swap! calls inc)))]
    (is (= 0 @calls))
    (is (= 1 (first xs)))
    (is (= 1 @calls))
    (is (= 2 (second xs)))
    (is (= 2 @calls)))
  (let [calls (atom 0)
        xs (take 0 (repeatedly #(swap! calls inc)))]
    (is (empty? xs))
    (is (= 0 @calls))))

;; conj on any ISeq prepends (the D-168 prerequisite fix, commonised via the
;; cons primitive). Covers lazy_seq producers: range / map / filter.
(deftest conj-on-lazy-seqs
  (testing "3-arg range"
    (is (= '(99 0 2 4) (conj (range 0 6 2) 99)))
    (is (= "(99 0 2 4)" (pr-str (conj (range 0 6 2) 99)))))
  (testing "map"
    (is (= '(0 2 3 4) (conj (map inc [1 2 3]) 0)))
    (is (= "(0 2 3 4)" (pr-str (conj (map inc [1 2 3]) 0)))))
  (testing "filter"
    (is (= '(0 1 3) (conj (filter odd? [1 2 3]) 0)))
    (is (= "(0 1 3)" (pr-str (conj (filter odd? [1 2 3]) 0))))))

;; nth walks a lazy seq (range became lazy under D-168 — `(rand-nth (range n))`
;; / `(nth (range n) i)` previously threw "no -nth on lazy_seq").
(deftest nth-on-lazy-seqs
  (is (= 3 (nth (range 50) 3)))
  (is (= 21 (nth (map inc [10 20 30]) 1)))
  (is (= :none (nth (range 5) 10 :none))))

;; ADR-0063 / O-001: finite integer range is a compact `.range` value. It is
;; `=` to the list / vector of the same elements, and count / nth are O(1)
;; (a million-element count / nth returns instantly, no per-element walk).
(deftest range-compact-value
  (testing "= to the list and the vector of the same elements"
    (is (= true (= (range 5) '(0 1 2 3 4))))
    (is (= true (= (range 5) [0 1 2 3 4]))))
  (testing "O(1) count / nth over a million elements"
    (is (= 1000000 (count (range 1000000))))
    (is (= 999999 (nth (range 1000000) 999999))))
  (testing "reduce"
    (is (= 5050 (reduce + (range 101)))))
  (testing "negative step renders as a list; step 0 is the infinite edge"
    (is (= '(10 8 6 4 2) (range 10 0 -2)))
    (is (= "(10 8 6 4 2)" (pr-str (range 10 0 -2))))
    (is (= [0 0 0] (into [] (take 3 (range 0 10 0)))))))

;; 3-arg step (lazy): positive step, negative step, non-divisor end,
;; start=end empty, and the step-0 infinite edge (matches JVM not=).
(deftest range-three-arg-step
  (is (= [0 2 4 6 8] (into [] (range 0 10 2))))
  (is (= [10 8 6 4 2] (into [] (range 10 0 -2))))
  (is (= [1 4 7] (into [] (range 1 10 3))))
  (is (= [] (into [] (range 5 5 2))))
  (is (= [0 0 0] (into [] (take 3 (range 0 10 0))))))

(deftest indexed-fns
  (is (= [[0 :a] [1 :b]] (into [] (map-indexed (fn* [i x] [i x]) [:a :b]))))
  (is (= [:a :c] (into [] (keep-indexed (fn* [i x] (if (= 0 (rem i 2)) x nil)) [:a :b :c])))))

(deftest indexed-fns-are-lazy
  (let [calls (atom 0)
        xs (map-indexed (fn [i x] (swap! calls inc) [i x])
                        (take 3 (repeat :x)))]
    (is (= 0 @calls))
    (is (= [0 :x] (first xs)))
    (is (= 1 @calls))
    (is (= [1 :x] (second xs)))
    (is (= 2 @calls)))
  (let [calls (atom 0)
        xs (keep-indexed (fn [i x]
                           (swap! calls inc)
                           (when (odd? i) x))
                         (take 4 (repeat :x)))]
    (is (= 0 @calls))
    (is (= :x (first xs)))
    (is (= 2 @calls))
    (is (= :x (second xs)))
    (is (= 4 @calls)))
  (is (= [[0 :x] [1 :x] [2 :x]]
         (into [] (take 3 (map-indexed vector (repeat :x))))))
  (is (= [:x :x :x]
         (into [] (take 3 (keep-indexed (fn [i x] (when (odd? i) x))
                                        (repeat :x)))))))

;; A large range must realize without blowing the stack: the lazy-seq body is
;; walked iteratively by count/reduce/last (one thunk per step, not fn-deep
;; recursion).
(deftest range-large-no-stack-blowup
  (is (= 100000 (count (range 100000))))
  (is (= 499500 (reduce + 0 (range 1000))))
  (is (= 49999 (last (range 50000)))))

;; ADR-0063 amendment (2026-08-28) — a `.range` spans the full i64 Long domain,
;; not just the ±2^47 i48 window. Heap-Long bounds (a `big_int` origin `.long`,
;; `int?`-true) now mint a compact `.range`; its elements past i48 box as heap
;; Longs (via `promote.wrapI64`) instead of silently spilling to float. clj
;; yields the finite Long range for all of these.
(deftest range-heap-long-domain
  (let [lo (bit-shift-left 1 55)
        hi (+ 4 (bit-shift-left 1 55))]
    (testing "renders as a Long list"
      (is (= '(36028797018963968 36028797018963969 36028797018963970 36028797018963971)
             (range lo hi)))
      (is (= "(36028797018963968 36028797018963969 36028797018963970 36028797018963971)"
             (pr-str (range lo hi)))))
    (testing "nth / count / reduce"
      (is (= 36028797018963969 (nth (range lo hi) 1)))
      (is (= 4 (count (range lo hi))))
      (is (= 144115188075855878 (reduce + (range lo hi)))))
    ;; generic (chunked) seq walk — seqChunk must box elements past i48 as Longs too.
    (testing "chunked seq walk via map / into"
      (is (= '(36028797018963969 36028797018963970 36028797018963971 36028797018963972)
             (map inc (range lo hi))))
      (is (= "(36028797018963969 36028797018963970 36028797018963971 36028797018963972)"
             (pr-str (map inc (range lo hi)))))
      (is (= [36028797018963968 36028797018963969 36028797018963970 36028797018963971]
             (into [] (range lo hi)))))
    ;; a produced element is a Long (int?-true), NOT a float.
    (testing "a produced element is a Long, not a float"
      (is (= true (int? (nth (range lo hi) 0)))))))

;; elements that CROSS the i48 boundary mid-range (start fits i48, end past it):
;; 140737488355327 = i48-max, the next element is the first heap Long.
(deftest range-crosses-i48-boundary
  (is (= '(140737488355326 140737488355327 140737488355328 140737488355329)
         (range (- (bit-shift-left 1 47) 2) (+ (bit-shift-left 1 47) 2))))
  (is (= "(140737488355326 140737488355327 140737488355328 140737488355329)"
         (pr-str (range (- (bit-shift-left 1 47) 2) (+ (bit-shift-left 1 47) 2))))))

;; negative step at a large offset.
(deftest range-heap-negative-step
  (is (= '(36028797018963968 36028797018963967 36028797018963966 36028797018963965)
         (range (bit-shift-left 1 55) (- (bit-shift-left 1 55) 4) -1)))
  (is (= "(36028797018963968 36028797018963967 36028797018963966 36028797018963965)"
         (pr-str (range (bit-shift-left 1 55) (- (bit-shift-left 1 55) 4) -1)))))
