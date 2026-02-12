;; clojure.walk — generic tree walker with replacement
;;
;; Based on upstream clojure.walk by Stuart Sierra.
;;
(ns clojure.walk)

(defn walk
  "Traverses form, an arbitrary data structure. inner and outer are
  functions. Applies inner to each element of form, building up a
  data structure of the same type, then applies outer to the result.
  Recognizes all Clojure data structures. Consumes seqs as with doall."
  [inner outer form]
  (cond
    (list? form) (outer (with-meta (apply list (map inner form)) (meta form)))
    ;; UPSTREAM-DIFF: no IMapEntry branch — CW map entries are plain vectors,
    ;; so the coll? branch handles them correctly via (into (empty form) ...).
    (seq? form) (outer (with-meta (doall (map inner form)) (meta form)))
    ;; UPSTREAM-DIFF: skip :__reify_type entry (CW record implementation detail)
    (record? form) (outer (reduce (fn [r x] (if (= (key x) :__reify_type) r (conj r (inner x)))) form form))
    (coll? form) (outer (into (empty form) (map inner form)))
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

(defn postwalk-demo
  "Demonstrates the behavior of postwalk by printing each form as it is
  walked. Returns form."
  {:added "1.1"}
  [form]
  (postwalk (fn [x] (print "Walked: ") (prn x) x) form))

(defn prewalk-demo
  "Demonstrates the behavior of prewalk by printing each form as it is
  walked. Returns form."
  {:added "1.1"}
  [form]
  (prewalk (fn [x] (print "Walked: ") (prn x) x) form))

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

(defn keywordize-keys
  "Recursively transforms all map keys from strings to keywords."
  [m]
  (let [f (fn [[k v]] (if (string? k) [(keyword k) v] [k v]))]
    (postwalk (fn [x] (if (map? x) (into {} (map f x)) x)) m)))

(defn stringify-keys
  "Recursively transforms all map keys from keywords to strings."
  [m]
  (let [f (fn [[k v]] (if (keyword? k) [(name k) v] [k v]))]
    (postwalk (fn [x] (if (map? x) (into {} (map f x)) x)) m)))

(defn macroexpand-all
  "Recursively performs all possible macroexpansions in form."
  [form]
  (prewalk (fn [x] (if (seq? x) (macroexpand x) x)) form))
