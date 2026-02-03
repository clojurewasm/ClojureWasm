;; clojure.walk — generic tree walker with replacement
;;
;; Based on upstream clojure.walk by Stuart Sierra.
;; Simplified version without metadata support.
;;
;; UPSTREAM-DIFF: No metadata preservation (with-meta), no IMapEntry/IRecord handling.

(ns clojure.walk)

(defn walk
  "Traverses form, an arbitrary data structure. inner and outer are
  functions. Applies inner to each element of form, building up a
  data structure of the same type, then applies outer to the result."
  [inner outer form]
  (cond
    (list? form) (outer (apply list (map inner form)))
    (vector? form) (outer (vec (map inner form)))
    (map? form) (outer (into {} (map (fn [[k v]] [(inner k) (inner v)]) form)))
    (set? form) (outer (set (map inner form)))
    (seq? form) (outer (doall (map inner form)))
    :else (outer form)))

(defn postwalk
  "Performs a depth-first, post-order traversal of form. Calls f on
  each sub-form, uses f's return value in place of the original."
  [f form]
  (walk (partial postwalk f) f form))

(defn prewalk
  "Like postwalk, but does pre-order traversal."
  [f form]
  (walk (partial prewalk f) identity (f form)))

(defn postwalk-replace
  "Recursively transforms form by replacing keys in smap with their
  values. Does replacement at the leaves of the tree first."
  [smap form]
  (postwalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

(defn prewalk-replace
  "Recursively transforms form by replacing keys in smap with their
  values. Does replacement at the root of the tree first."
  [smap form]
  (prewalk (fn [x] (if (contains? smap x) (get smap x) x)) form))
