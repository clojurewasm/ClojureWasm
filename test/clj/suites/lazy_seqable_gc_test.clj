;; Native sequence callback-GC contracts. Allocation-every-1 probes live in
;; test/clj/torture/lazy_seqable.clj; nREPL workers skip that trigger.
(ns suites.lazy-seqable-gc-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.data.csv :as csv]))

(deftype LazyGcSeq [n]
  clojure.lang.ISeq
  (first [_] (System/gc) (str "item-" n))
  (next [_] (System/gc) (when (> n 1) (LazyGcSeq. (dec n))))
  (more [this] (or (next this) ()))
  (cons [this x] (clojure.core/cons x this))
  (count [_] n)
  (empty [_] ())
  (equiv [this other] (= (vec this) other))
  (seq [this] (System/gc) this))

(deftest custom-sequence-callbacks-survive-gc
  (let [expected (mapv #(str "item-" %) (range 8 0 -1))]
    (is (= expected (vec (lazy-seq (LazyGcSeq. 8)))))
    (is (= 8 (count (lazy-seq (LazyGcSeq. 8)))))
    (is (= (apply str expected) (apply str (lazy-seq (LazyGcSeq. 8)))))
    (is (= (pr-str (seq expected)) (pr-str (lazy-seq (LazyGcSeq. 8))))))
  (is (= ["a" "b"]
         (vec (lazy-seq
                (reify clojure.lang.Seqable
                  (seq [_] (System/gc) (seq (to-array ["a" "b"])))))))))

(deftest custom-coercion-keeps-fresh-backing-alive
  ;; The allocation-every-1 equivalent lives in torture/lazy_seqable.clj.
  ;; Registered nREPL workers skip allocation torture, unlike the CLI thread.
  (let [source (reify clojure.lang.Seqable
                 (seq [_] (seq (to-array ["a" "b" "c"]))))]
    (is (= ["b" "c"] (vec (next source))))
    (is (= ["b" "c"] (vec (rest source))))))

(deftest iterator-retains-head-across-custom-next
  (let [iter (.iterator (lazy-seq (LazyGcSeq. 2)))]
    (is (= "item-2" (.next iter)))
    (is (= "item-1" (.next iter)))
    (is (false? (.hasNext iter)))))

(deftest lazy-coercion-retains-fresh-body
  (is (= ["a" "b"]
         (vec (lazy-seq
                (reify clojure.lang.Seqable
                  (seq [_] (seq (to-array ["a" "b"])))))))))

(deftest iterator-retains-fresh-cursor
  (let [iter (.iterator (java.util.ArrayList. ["a" "b"]))]
    (is (= "a" (.next iter)))
    (is (= "b" (.next iter)))
    (is (false? (.hasNext iter)))))

(deftest csv-retains-cursors-across-lazy-callbacks
  (let [writer (java.io.StringWriter.)]
    (csv/write-csv writer [(lazy-seq (System/gc) ["a" "b"])
                           (lazy-seq (System/gc) ["c" "d"])])
    (is (= "a,b\nc,d\n" (str writer))))
  (let [writer (java.io.StringWriter.)]
    (csv/write-csv writer [(LazyGcSeq. 3) (LazyGcSeq. 2)])
    (is (= "item-3,item-2,item-1\nitem-2,item-1\n" (str writer)))))

(defn- gc-entry-seq [n step]
  (when (<= 1 n 3)
    ;; LazySeq supplies the Sequential marker used by JVM subseq destructuring.
    (lazy-seq
      (reify clojure.lang.ISeq
        ;; Each first returns a fresh entry that this cursor does not retain.
        (first [_] [n (str "v" n)])
        (next [_] (gc-entry-seq (+ n step) step))
        (more [this] (or (next this) ()))
        (cons [this x] (clojure.core/cons x this))
        (count [_] (if (pos? step) (- 4 n) n))
        (empty [_] ())
        (equiv [_ _] false)
        (seq [this] this)))))

(defn- gc-sorted []
  (reify clojure.lang.Sorted
    (comparator [_] (fn [a b] (System/gc) (compare a b)))
    (entryKey [_ entry] (first entry))
    (seq [_ ascending]
      (System/gc)
      (gc-entry-seq (if ascending 1 3) (if ascending 1 -1)))
    (seqFrom [_ k ascending]
      (System/gc)
      (gc-entry-seq k (if ascending 1 -1)))))

(deftest sorted-bounds-retain-fresh-cursors-and-entries
  (let [sc (gc-sorted)]
    (is (= [[1 "v1"] [2 "v2"]] (vec (subseq sc < 3))))
    (is (= [[3 "v3"] [2 "v2"]] (vec (rsubseq sc > 1))))
    (is (= [[2 "v2"] [3 "v3"]] (vec (subseq sc >= 2))))
    (is (= [[2 "v2"] [1 "v1"]] (vec (rsubseq sc <= 2))))
    (is (= [[3 "v3"]] (vec (subseq sc > 2))))
    (is (= [[1 "v1"]] (vec (rsubseq sc < 2))))
    (is (= [[1 "v1"] [2 "v2"]] (vec (subseq sc >= 1 < 3))))
    (is (= [[2 "v2"] [3 "v3"]] (vec (subseq sc > 1 <= 3))))
    (is (= [[3 "v3"] [2 "v2"]] (vec (rsubseq sc > 1 <= 3))))
    (is (= [[2 "v2"] [1 "v1"]] (vec (rsubseq sc >= 1 < 3))))))

(deftest equality-retains-heads-across-custom-advance
  (let [expected '("item-3" "item-2" "item-1")]
    (is (= expected (lazy-seq (LazyGcSeq. 3))))
    (is (= (lazy-seq (LazyGcSeq. 3)) expected))
    (is (= (lazy-seq (LazyGcSeq. 3)) (lazy-seq (LazyGcSeq. 3))))))
