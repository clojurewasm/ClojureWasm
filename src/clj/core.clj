;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.

(defmacro defn [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

(defmacro when [test & body]
  `(if ~test (do ~@body)))

;; Arithmetic helpers

(defn inc [x] (+ x 1))
(defn dec [x] (- x 1))

;; Higher-order functions (eager, non-lazy)

(defn next [coll]
  (seq (rest coll)))

(defn map [f coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (recur (next s) (cons (f (first s)) acc))
      (reverse acc))))

(defn filter [pred coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (if (pred (first s))
        (recur (next s) (cons (first s) acc))
        (recur (next s) acc))
      (reverse acc))))

(defn reduce [f init coll]
  (loop [acc init s (seq coll)]
    (if s
      (recur (f acc (first s)) (next s))
      acc)))

(defn take [n coll]
  (loop [i n s (seq coll) acc (list)]
    (if (if (> i 0) s nil)
      (recur (- i 1) (next s) (cons (first s) acc))
      (reverse acc))))

(defn drop [n coll]
  (loop [i n s (seq coll)]
    (if (if (> i 0) s nil)
      (recur (- i 1) (next s))
      s)))

(defn mapcat [f coll]
  (apply concat (map f coll)))

;; Core macros

(defmacro comment [& body] nil)

(defmacro cond [& clauses]
  (when (seq clauses)
    (let [test (first clauses)
          then (first (rest clauses))
          more (rest (rest clauses))]
      (if (seq more)
        `(if ~test ~then (cond ~@more))
        `(if ~test ~then)))))

(defmacro if-not [test then else]
  `(if (not ~test) ~then ~else))

(defmacro when-not [test & body]
  `(if (not ~test) (do ~@body)))

;; Utility functions

(defn identity [x] x)

(defn constantly [x]
  (fn [& args] x))

(defn complement [f]
  (fn [& args]
    (not (apply f args))))

(defmacro defn- [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

;; Threading macros

(defmacro -> [x & forms]
  (if (seq forms)
    (let [form (first forms)
          threaded (if (seq? form)
                     `(~(first form) ~x ~@(rest form))
                     `(~form ~x))]
      `(-> ~threaded ~@(rest forms)))
    x))

(defmacro ->> [x & forms]
  (if (seq forms)
    (let [form (first forms)
          threaded (if (seq? form)
                     `(~(first form) ~@(rest form) ~x)
                     `(~form ~x))]
      `(->> ~threaded ~@(rest forms)))
    x))

;; Iteration

(defmacro dotimes [bindings & body]
  (let [i (first bindings)
        n (first (rest bindings))]
    `(let [n# ~n]
       (loop [~i 0]
         (when (< ~i n#)
           ~@body
           (recur (+ ~i 1)))))))

;; and/or

(defmacro and
  [& args]
  (let [a (first args)
        more (rest args)]
    (if (seq more)
      `(let [and__val ~a]
         (if and__val (and ~@more) and__val))
      a)))

(defmacro or
  [& args]
  (let [a (first args)
        more (rest args)]
    (if (seq more)
      `(let [or__val ~a]
         (if or__val or__val (or ~@more)))
      a)))

;; Nested collection operations

(defn get-in [m ks]
  (reduce get m ks))

(defn assoc-in [m ks v]
  (let [k (first ks)
        ks-rest (next ks)]
    (if ks-rest
      (assoc m k (assoc-in (get m k) ks-rest v))
      (assoc m k v))))

(defn update [m k f]
  (assoc m k (f (get m k))))

(defn update-in [m ks f]
  (let [k (first ks)
        ks-rest (next ks)]
    (if ks-rest
      (assoc m k (update-in (get m k) ks-rest f))
      (assoc m k (f (get m k))))))

(defn select-keys [m keyseq]
  (reduce (fn [acc k]
            (let [v (get m k)]
              (if (not (nil? v))
                (assoc acc k v)
                acc)))
          {}
          keyseq))

;; Predicates and search

(defn some [pred coll]
  (loop [s (seq coll)]
    (if s
      (if (pred (first s))
        (first s)
        (recur (next s)))
      nil)))

(defn every? [pred coll]
  (loop [s (seq coll)]
    (if s
      (if (pred (first s))
        (recur (next s))
        false)
      true)))

(defn not-every? [pred coll]
  (not (every? pred coll)))

(defn not-any? [pred coll]
  (not (some pred coll)))

;; Function combinators

(defn partial
  ([f a]
   (fn [& args] (apply f (cons a args))))
  ([f a b]
   (fn [& args] (apply f (cons a (cons b args))))))

(defn comp
  ([] identity)
  ([f] f)
  ([f g]
   (fn [x] (f (g x)))))

(defn juxt
  ([f]
   (fn [& args]
     (vector (apply f args))))
  ([f g]
   (fn [& args]
     (vector (apply f args) (apply g args)))))

;; Sequence transforms

(defn partition [n coll]
  (loop [s (seq coll) acc (list)]
    (let [chunk (take n s)]
      (if (= (count chunk) n)
        (recur (drop n s) (cons chunk acc))
        (reverse acc)))))

(defn partition-by [f coll]
  (loop [s (seq coll) acc (list) cur (list) prev nil started false]
    (if s
      (let [v (first s)
            fv (f v)]
        (if (if started (= fv prev) true)
          (recur (next s) acc (cons v cur) fv true)
          (recur (next s) (cons (reverse cur) acc) (list v) fv true)))
      (if (seq cur)
        (reverse (cons (reverse cur) acc))
        (reverse acc)))))

(defn group-by [f coll]
  (reduce (fn [acc x]
            (let [k (f x)
                  v (get acc k)]
              (assoc acc k (if v (conj v x) [x]))))
          {}
          coll))

(defn flatten [coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (let [x (first s)]
        (if (coll? x)
          (recur (concat (seq x) (next s)) acc)
          (recur (next s) (cons x acc))))
      (reverse acc))))

(defn interleave [c1 c2]
  (loop [s1 (seq c1) s2 (seq c2) acc (list)]
    (if (if s1 s2 nil)
      (recur (next s1) (next s2) (cons (first s2) (cons (first s1) acc)))
      (reverse acc))))

(defn interpose [sep coll]
  (loop [s (seq coll) acc (list) started false]
    (if s
      (if started
        (recur (next s) (cons (first s) (cons sep acc)) true)
        (recur (next s) (cons (first s) acc) true))
      (reverse acc))))

(defn distinct [coll]
  (loop [s (seq coll) seen #{} acc (list)]
    (if s
      (let [x (first s)]
        (if (contains? seen x)
          (recur (next s) seen acc)
          (recur (next s) (conj seen x) (cons x acc))))
      (reverse acc))))

(defn frequencies [coll]
  (reduce (fn [acc x]
            (let [n (get acc x)]
              (assoc acc x (if n (inc n) 1))))
          {}
          coll))

;; Utility macros

(defmacro if-let [bindings then else]
  (let [sym (first bindings)
        val (first (rest bindings))]
    `(let [temp# ~val]
       (if temp#
         (let [~sym temp#] ~then)
         ~else))))

(defmacro when-let [bindings & body]
  (let [sym (first bindings)
        val (first (rest bindings))]
    `(let [temp# ~val]
       (when temp#
         (let [~sym temp#] ~@body)))))
