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

;; Threading macro variants

(defmacro doto [x & forms]
  (let [gx '__doto_val__]
    (cons 'let
          (cons [gx x]
                (concat
                 (map (fn [f]
                        (if (seq? f)
                          (cons (first f) (cons gx (rest f)))
                          (list f gx)))
                      forms)
                 (list gx))))))

(defmacro as-> [expr name & forms]
  `(let [~name ~expr
         ~@(mapcat (fn [form] [name form]) forms)]
     ~name))

(defmacro some-> [expr & forms]
  (if (seq forms)
    (let [f (first forms)
          more (rest forms)
          step (if (seq? f)
                 (cons (first f) (cons '__some_val__ (rest f)))
                 (list f '__some_val__))]
      (if (seq more)
        (cons 'let
              (list ['__some_val__ expr]
                    (cons 'if
                          (list '(nil? __some_val__)
                                nil
                                (cons 'some-> (cons step more))))))
        (cons 'let
              (list ['__some_val__ expr]
                    (cons 'if
                          (list '(nil? __some_val__)
                                nil
                                step))))))
    expr))

(defmacro some->> [expr & forms]
  (if (seq forms)
    (let [f (first forms)
          more (rest forms)
          step (if (seq? f)
                 (concat (list (first f)) (rest f) (list '__some_val__))
                 (list f '__some_val__))]
      (if (seq more)
        (cons 'let
              (list ['__some_val__ expr]
                    (cons 'if
                          (list '(nil? __some_val__)
                                nil
                                (cons 'some->> (cons step more))))))
        (cons 'let
              (list ['__some_val__ expr]
                    (cons 'if
                          (list '(nil? __some_val__)
                                nil
                                step))))))
    expr))

(defmacro cond-> [expr & clauses]
  (let [pairs (partition 2 clauses)]
    (reduce (fn [acc pair]
              (let [test (first pair)
                    form (first (rest pair))
                    step (if (seq? form)
                           (cons (first form) (cons '__cond_val__ (rest form)))
                           (list form '__cond_val__))]
                (list 'let ['__cond_val__ acc]
                      (list 'if test step '__cond_val__))))
            expr
            pairs)))

(defmacro cond->> [expr & clauses]
  (let [pairs (partition 2 clauses)]
    (reduce (fn [acc pair]
              (let [test (first pair)
                    form (first (rest pair))
                    step (if (seq? form)
                           (concat (list (first form)) (rest form) (list '__cond_val__))
                           (list form '__cond_val__))]
                (list 'let ['__cond_val__ acc]
                      (list 'if test step '__cond_val__))))
            expr
            pairs)))

;; Lazy sequence constructors

(defn iterate [f x]
  (lazy-seq (cons x (iterate f (f x)))))

(defn repeat
  ([x] (lazy-seq (cons x (repeat x))))
  ([n x]
   (take n (repeat x))))

(defn repeatedly
  ([f] (lazy-seq (cons (f) (repeatedly f))))
  ([n f] (take n (repeatedly f))))

(defn lazy-cat-helper [colls]
  (when (seq colls)
    (lazy-seq
     (let [c (first colls)]
       (if (seq c)
         (cons (first c) (lazy-cat-helper (cons (rest c) (rest colls))))
         (lazy-cat-helper (rest colls)))))))

(defn cycle [coll]
  (when (seq coll)
    (lazy-seq
     (lazy-cat-helper (repeat coll)))))

;; Additional HOFs

(defn remove [pred coll]
  (filter (complement pred) coll))

(defn map-indexed [f coll]
  (loop [s (seq coll) i 0 acc (list)]
    (if s
      (recur (next s) (+ i 1) (cons (f i (first s)) acc))
      (reverse acc))))

(defn keep [f coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (let [v (f (first s))]
        (if (nil? v)
          (recur (next s) acc)
          (recur (next s) (cons v acc))))
      (reverse acc))))

(defn keep-indexed [f coll]
  (loop [s (seq coll) i 0 acc (list)]
    (if s
      (let [v (f i (first s))]
        (if (nil? v)
          (recur (next s) (+ i 1) acc)
          (recur (next s) (+ i 1) (cons v acc))))
      (reverse acc))))

;; Vector-returning variants

(defn mapv [f coll]
  (vec (map f coll)))

(defn filterv [pred coll]
  (vec (filter pred coll)))

(defn partition-all [n coll]
  (loop [s (seq coll) acc (list)]
    (let [chunk (take n s)]
      (if (seq chunk)
        (recur (drop n s) (cons chunk acc))
        (reverse acc)))))

(defn take-while [pred coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (if (pred (first s))
        (recur (next s) (cons (first s) acc))
        (reverse acc))
      (reverse acc))))

(defn drop-while [pred coll]
  (loop [s (seq coll)]
    (if s
      (if (pred (first s))
        (recur (next s))
        s)
      (list))))

(defn reduce-kv [f init m]
  (let [ks (keys m)]
    (loop [s (seq ks) acc init]
      (if s
        (let [k (first s)]
          (recur (next s) (f acc k (get m k))))
        acc))))

;; Convenience accessors

(defn last [coll]
  (loop [s (seq coll)]
    (if s
      (if (next s)
        (recur (next s))
        (first s))
      nil)))

(defn butlast [coll]
  (loop [s (seq coll) acc (list)]
    (if s
      (if (next s)
        (recur (next s) (cons (first s) acc))
        (if (seq acc) (reverse acc) nil))
      nil)))

(defn second [coll]
  (first (next coll)))

(defn fnext [coll]
  (first (next coll)))

(defn nfirst [coll]
  (next (first coll)))

;; Predicate/function utilities

(defn not-empty [coll]
  (when (seq coll) coll))

(defn every-pred
  ([p] (fn [x] (p x)))
  ([p1 p2]
   (fn [x]
     (and (p1 x) (p2 x)))))

(defn some-fn
  ([p] (fn [x] (p x)))
  ([p1 p2]
   (fn [x]
     (or (p1 x) (p2 x)))))

(defn fnil [f default]
  (fn [x]
    (f (if (nil? x) default x))))

;; Control flow macros

(defmacro case [expr & clauses]
  (let [pairs (partition 2 clauses)
        default (if (= (* 2 (count pairs)) (count clauses))
                  nil
                  (last clauses))
        gexpr '__case_val__]
    `(let [~gexpr ~expr]
       (cond
         ~@(mapcat (fn [pair]
                     (list (list '= gexpr (first pair))
                           (first (rest pair))))
                   pairs)
         ~@(if default
             (list true default)
             nil)))))

(defmacro condp [pred expr & clauses]
  (let [pairs (partition 2 clauses)
        default (if (= (* 2 (count pairs)) (count clauses))
                  nil
                  (last clauses))
        gexpr '__condp_val__]
    (cons 'let
          (list [gexpr expr]
                (cons 'cond
                      (concat
                       (mapcat (fn [pair]
                                 (list (list pred (first pair) gexpr)
                                       (first (rest pair))))
                               pairs)
                       (if default
                         (list true default)
                         (list))))))))

(defmacro declare [& names]
  (cons 'do (map (fn [n] (list 'def n)) names)))

;; Imperative iteration

(defmacro while [test & body]
  `(loop []
     (when ~test
       ~@body
       (recur))))

(defmacro doseq [bindings & body]
  (let [sym (first bindings)
        coll (first (rest bindings))]
    `(loop [s# (seq ~coll)]
       (when s#
         (let [~sym (first s#)]
           ~@body)
         (recur (next s#))))))

(defn dorun [coll]
  (loop [s (seq coll)]
    (when s
      (recur (next s)))))

(defn doall [coll]
  (dorun coll)
  coll)

;; Delayed evaluation

(defmacro delay [& body]
  `{:__delay true
    :thunk (fn [] ~@body)
    :value (atom nil)
    :realized (atom false)})

(defn force [x]
  (if (if (map? x) (:__delay x) false)
    (if (deref (:realized x))
      (deref (:value x))
      (let [v ((:thunk x))]
        (reset! (:value x) v)
        (reset! (:realized x) true)
        v))
    x))

(defn realized? [x]
  (if (if (map? x) (:__delay x) false)
    (deref (:realized x))
    false))

;; Basic predicates

(defn boolean [x]
  (if x true false))

(defn true? [x]
  (= x true))

(defn false? [x]
  (= x false))

(defn some? [x]
  (not (nil? x)))

(defn any? [x]
  true)

;; Exception helpers

(defn ex-info
  ([msg data] {:__ex_info true :message msg :data data :cause nil})
  ([msg data cause] {:__ex_info true :message msg :data data :cause cause}))

(defn ex-data [ex]
  (when (map? ex) (:data ex)))

(defn ex-message [ex]
  (when (map? ex) (:message ex)))
