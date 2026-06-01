;; clojure.data — `(diff a b)` recursive data diff (D-data-diff sweep).
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` after clojure.set (this file
;; calls `clojure.set/union` / `difference` / `intersection` fully-qualified,
;; so it must load once those vars exist). JVM clojure.data dispatches via the
;; EqualityPartition + Diff protocols over Java interfaces (Set/List/Map); cw
;; v1 has no such interfaces, so the partition is a `cond` over the cljw
;; predicates (set?/map?/sequential?) and `diff-similar` a `cond` to the same
;; three shapes — observably equivalent (F-011), simpler mechanism.
;;
;; Pattern A (`(def name (fn* ...))`); `diff` is forward-declared two-step so
;; the helpers' mutual recursion through it resolves (cw v1 has no `declare`).

(ns clojure.data (:refer-clojure))

;; forward declaration — diff-associative-key recurses through diff.
(def diff nil)

;; `(diff a b)` for non-collections: equal → [nil nil a], else [a b nil].
(def atom-diff (fn* [a b] (if (= a b) [nil nil a] [a b nil])))

;; Convert a sparse {index → value} map back to a vector, nil-filling gaps.
;; Length is max-index+1 so every key indexes in-bounds (JVM relies on
;; assoc-at-count append; the +1 form avoids depending on that).
(def vectorize
  (fn* [m]
    (if (seq m)
      (reduce (fn* [result kv] (assoc result (nth kv 0) (nth kv 1)))
              (vec (repeat (inc (apply max (keys m))) nil))
              m)
      nil)))

;; Diff associative a and b at a single key k → [in-a-only in-b-only in-both],
;; each a singleton map {k _} or nil. Recurses into the values via diff.
(def diff-associative-key
  (fn* [a b k]
    (let* [va (get a k)
           vb (get b k)
           d (diff va vb)
           a* (nth d 0)
           b* (nth d 1)
           ab (nth d 2)
           in-a (contains? a k)
           in-b (contains? b k)
           same (and in-a in-b (or (not (nil? ab)) (and (nil? va) (nil? vb))))]
      [(when (and in-a (or (not (nil? a*)) (not same))) {k a*})
       (when (and in-b (or (not (nil? b*)) (not same))) {k b*})
       (when same {k ab})])))

;; Diff a and b over the keys ks, merging the per-key triples.
(def diff-associative
  (fn* [a b ks]
    (reduce (fn* [d1 d2] (map merge d1 d2))
            [nil nil nil]
            (map (fn* [k] (diff-associative-key a b k)) ks))))

;; Diff two sequentials by index (treated as associative), results vectorized.
(def diff-sequential
  (fn* [a b]
    (vec (map vectorize
              (diff-associative (if (vector? a) a (vec a))
                                (if (vector? b) b (vec b))
                                (range (max (count a) (count b))))))))

;; Clojure's equality-partition: which of the four diff shapes x belongs to.
(def equality-partition
  (fn* [x]
    (cond (nil? x) :atom
          (set? x) :set
          (map? x) :map
          (sequential? x) :sequential
          :else :atom)))

;; Diff two like-partitioned values. Sets are never subdiffed.
(def diff-similar
  (fn* [a b]
    (let* [ep (equality-partition a)]
      (cond
        (= ep :set)
        (let* [av (if (set? a) a (set a))
               bv (if (set? b) b (set b))]
          [(not-empty (clojure.set/difference av bv))
           (not-empty (clojure.set/difference bv av))
           (not-empty (clojure.set/intersection av bv))])
        (= ep :sequential) (diff-sequential a b)
        (= ep :map) (diff-associative a b (clojure.set/union (set (keys a)) (set (keys b))))
        :else (atom-diff a b)))))

;; `(diff a b)` → [things-only-in-a things-only-in-b things-in-both].
(def diff
  (fn* [a b]
    (if (= a b)
      [nil nil a]
      (if (= (equality-partition a) (equality-partition b))
        (diff-similar a b)
        (atom-diff a b)))))
