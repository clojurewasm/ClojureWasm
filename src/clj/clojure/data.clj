;; clojure.data — Non-core data functions.
;; UPSTREAM-DIFF: uses type checks instead of protocols (no Java types)

(ns clojure.data
  (:require [clojure.set :as set]))

(declare diff)

(defn- atom-diff
  [a b]
  (if (= a b) [nil nil a] [a b nil]))

(defn- vectorize
  [m]
  (when (seq m)
    (reduce
     (fn [result [k v]] (assoc result k v))
     (vec (repeat (apply max (keys m)) nil))
     m)))

(defn- diff-associative-key
  [a b k]
  (let [va (get a k)
        vb (get b k)
        [a* b* ab] (diff va vb)
        in-a (contains? a k)
        in-b (contains? b k)
        same (and in-a in-b
                  (or (not (nil? ab))
                      (and (nil? va) (nil? vb))))]
    [(when (and in-a (or (not (nil? a*)) (not same))) {k a*})
     (when (and in-b (or (not (nil? b*)) (not same))) {k b*})
     (when same {k ab})]))

(defn- diff-associative
  [a b ks]
  (vec
   (reduce
    (fn [diff1 diff2]
      (doall (map merge diff1 diff2)))
    [nil nil nil]
    (map
     (partial diff-associative-key a b)
     ks))))

(defn- diff-sequential
  [a b]
  (vec (map vectorize (diff-associative
                       (if (vector? a) a (vec a))
                       (if (vector? b) b (vec b))
                       (range (max (count a) (count b)))))))

(defn- equality-partition
  [x]
  (cond
    (nil? x)        :atom
    (map? x)        :map
    (set? x)        :set
    (sequential? x) :sequential
    :else           :atom))

(defn- diff-similar
  [a b]
  (cond
    (nil? a)        (atom-diff a b)
    (set? a)        (let [aval (if (set? a) a (into #{} a))
                          bval (if (set? b) b (into #{} b))]
                      [(not-empty (set/difference aval bval))
                       (not-empty (set/difference bval aval))
                       (not-empty (set/intersection aval bval))])
    (map? a)        (diff-associative a b (set/union (set (keys a)) (set (keys b))))
    (sequential? a) (diff-sequential a b)
    :else           (atom-diff a b)))

(defn diff
  "Recursively compares a and b, returning a tuple of
  [things-only-in-a things-only-in-b things-in-both].
  Comparison rules:

  * For equal a and b, return [nil nil a].
  * Maps are subdiffed where keys match and values differ.
  * Sets are never subdiffed.
  * All sequential things are treated as associative collections
    by their indexes, with results returned as vectors.
  * Everything else (including strings!) is treated as
    an atom and compared for equality."
  [a b]
  (if (= a b)
    [nil nil a]
    (if (= (equality-partition a) (equality-partition b))
      (diff-similar a b)
      (atom-diff a b))))
