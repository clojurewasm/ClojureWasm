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

(defn reduce
  ([f coll]
   (let [s (seq coll)]
     (if s
       (reduce f (first s) (next s))
       (f))))
  ([f init coll]
   (loop [acc init s (seq coll)]
     (if (reduced? acc)
       (unreduced acc)
       (if s
         (recur (f acc (first s)) (next s))
         acc)))))

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

;; Namespace declaration
;; UPSTREAM-DIFF: Simplified ns macro; no :import, no docstring, no :gen-class

(defmacro ns [name & references]
  (let [process-ref (fn [ref-form]
                      (let [kw (first ref-form)
                            args (rest ref-form)]
                        (cond
                          (= kw :require)
                          (map (fn [arg] `(require '~arg)) args)

                          (= kw :use)
                          (map (fn [arg] `(use '~arg)) args)

                          :else nil)))
        ref-forms (apply concat (map process-ref references))]
    `(do (in-ns '~name) ~@ref-forms)))

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

(defn update
  ([m k f]
   (assoc m k (f (get m k))))
  ([m k f x]
   (assoc m k (f (get m k) x)))
  ([m k f x y]
   (assoc m k (f (get m k) x y)))
  ([m k f x y z]
   (assoc m k (f (get m k) x y z)))
  ([m k f x y z & more]
   (assoc m k (apply f (get m k) x y z more))))

(defn update-in
  ([m ks f]
   (let [k (first ks)
         ks-rest (next ks)]
     (if ks-rest
       (assoc m k (update-in (get m k) ks-rest f))
       (assoc m k (f (get m k))))))
  ([m ks f & args]
   (let [k (first ks)
         ks-rest (next ks)]
     (if ks-rest
       (assoc m k (apply update-in (get m k) ks-rest f args))
       (assoc m k (apply f (get m k) args))))))

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
  ([f] f)
  ([f arg1]
   (fn
     ([] (f arg1))
     ([x] (f arg1 x))
     ([x y] (f arg1 x y))
     ([x y z] (f arg1 x y z))
     ([x y z & args] (apply f arg1 x y z args))))
  ([f arg1 arg2]
   (fn
     ([] (f arg1 arg2))
     ([x] (f arg1 arg2 x))
     ([x y] (f arg1 arg2 x y))
     ([x y z] (f arg1 arg2 x y z))
     ([x y z & args] (apply f arg1 arg2 x y z args))))
  ([f arg1 arg2 arg3]
   (fn
     ([] (f arg1 arg2 arg3))
     ([x] (f arg1 arg2 arg3 x))
     ([x y] (f arg1 arg2 arg3 x y))
     ([x y z] (f arg1 arg2 arg3 x y z))
     ([x y z & args] (apply f arg1 arg2 arg3 x y z args))))
  ([f arg1 arg2 arg3 & more]
   (fn [& args] (apply f arg1 arg2 arg3 (concat more args)))))

(defn comp
  ([] identity)
  ([f] f)
  ([f g]
   (fn
     ([] (f (g)))
     ([x] (f (g x)))
     ([x y] (f (g x y)))
     ([x y z] (f (g x y z)))
     ([x y z & args] (f (apply g x y z args)))))
  ([f g & fs]
   (reduce comp (list* f g fs))))

(defn juxt
  ([f]
   (fn
     ([] [(f)])
     ([x] [(f x)])
     ([x y] [(f x y)])
     ([x y z] [(f x y z)])
     ([x y z & args] [(apply f x y z args)])))
  ([f g]
   (fn
     ([] [(f) (g)])
     ([x] [(f x) (g x)])
     ([x y] [(f x y) (g x y)])
     ([x y z] [(f x y z) (g x y z)])
     ([x y z & args] [(apply f x y z args) (apply g x y z args)])))
  ([f g h]
   (fn
     ([] [(f) (g) (h)])
     ([x] [(f x) (g x) (h x)])
     ([x y] [(f x y) (g x y) (h x y)])
     ([x y z] [(f x y z) (g x y z) (h x y z)])
     ([x y z & args] [(apply f x y z args) (apply g x y z args) (apply h x y z args)])))
  ([f g h & fs]
   (let [fs (list* f g h fs)]
     (fn
       ([] (reduce #(conj %1 (%2)) [] fs))
       ([x] (reduce #(conj %1 (%2 x)) [] fs))
       ([x y] (reduce #(conj %1 (%2 x y)) [] fs))
       ([x y z] (reduce #(conj %1 (%2 x y z)) [] fs))
       ([x y z & args] (reduce #(conj %1 (apply %2 x y z args)) [] fs))))))

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
  ([p]
   (fn ep1
     ([] true)
     ([x] (boolean (p x)))
     ([x y] (boolean (and (p x) (p y))))
     ([x y z] (boolean (and (p x) (p y) (p z))))
     ([x y z & args] (boolean (and (ep1 x y z)
                                   (every? p args))))))
  ([p1 p2]
   (fn ep2
     ([] true)
     ([x] (boolean (and (p1 x) (p2 x))))
     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y))))
     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z))))
     ([x y z & args] (boolean (and (ep2 x y z)
                                   (every? #(and (p1 %) (p2 %)) args))))))
  ([p1 p2 p3]
   (fn ep3
     ([] true)
     ([x] (boolean (and (p1 x) (p2 x) (p3 x))))
     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y))))
     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z))))
     ([x y z & args] (boolean (and (ep3 x y z)
                                   (every? #(and (p1 %) (p2 %) (p3 %)) args))))))
  ([p1 p2 p3 & ps]
   (let [ps (list* p1 p2 p3 ps)]
     (fn epn
       ([] true)
       ([x] (every? #(% x) ps))
       ([x y] (every? #(and (% x) (% y)) ps))
       ([x y z] (every? #(and (% x) (% y) (% z)) ps))
       ([x y z & args] (boolean (and (epn x y z)
                                     (every? #(every? % args) ps))))))))

(defn some-fn
  ([p]
   (fn sp1
     ([] nil)
     ([x] (p x))
     ([x y] (or (p x) (p y)))
     ([x y z] (or (p x) (p y) (p z)))
     ([x y z & args] (or (sp1 x y z)
                         (some p args)))))
  ([p1 p2]
   (fn sp2
     ([] nil)
     ([x] (or (p1 x) (p2 x)))
     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y)))
     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z)))
     ([x y z & args] (or (sp2 x y z)
                         (some #(or (p1 %) (p2 %)) args)))))
  ([p1 p2 p3]
   (fn sp3
     ([] nil)
     ([x] (or (p1 x) (p2 x) (p3 x)))
     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y)))
     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z)))
     ([x y z & args] (or (sp3 x y z)
                         (some #(or (p1 %) (p2 %) (p3 %)) args)))))
  ([p1 p2 p3 & ps]
   (let [ps (list* p1 p2 p3 ps)]
     (fn spn
       ([] nil)
       ([x] (some #(% x) ps))
       ([x y] (some #(or (% x) (% y)) ps))
       ([x y z] (some #(or (% x) (% y) (% z)) ps))
       ([x y z & args] (or (spn x y z)
                           (some #(some % args) ps)))))))

(defn fnil
  ([f x]
   (fn
     ([a] (f (if (nil? a) x a)))
     ([a b] (f (if (nil? a) x a) b))
     ([a b c] (f (if (nil? a) x a) b c))
     ([a b c & ds] (apply f (if (nil? a) x a) b c ds))))
  ([f x y]
   (fn
     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) c))
     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) c ds))))
  ([f x y z]
   (fn
     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c)))
     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) ds)))))

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

(defn delay? [x]
  (if (map? x) (if (:__delay x) true false) false))

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

;; Type introspection

(defn instance? [t x]
  (= t (type x)))

(defn isa? [child parent]
  (= child parent))

;; Exception helpers

(defn ex-info
  ([msg data] {:__ex_info true :message msg :data data :cause nil})
  ([msg data cause] {:__ex_info true :message msg :data data :cause cause}))

(defn ex-data [ex]
  (when (map? ex) (:data ex)))

(defn ex-message [ex]
  (when (map? ex) (:message ex)))

(defmacro defonce [name expr]
  (list 'when-not (list 'bound? (list 'quote name))
        (list 'def name expr)))

;; Metadata utilities

(defn vary-meta
  [obj f & args]
  (with-meta obj (apply f (meta obj) args)))

;; Nil-safe conditionals

(defmacro if-some [bindings then else]
  (let [sym (first bindings)
        val (first (rest bindings))]
    `(let [temp# ~val]
       (if (nil? temp#)
         ~else
         (let [~sym temp#] ~then)))))

(defmacro when-some [bindings & body]
  (let [sym (first bindings)
        val (first (rest bindings))]
    `(let [temp# ~val]
       (if (nil? temp#)
         nil
         (let [~sym temp#] ~@body)))))

;; Volatile swap macro

(defmacro vswap! [vol f & args]
  `(vreset! ~vol (~f (deref ~vol) ~@args)))

;; Function combinators — memoize and trampoline

(defn memoize [f]
  (let [mem (atom {})]
    (fn [& args]
      (if-let [e (find (deref mem) args)]
        (val e)
        (let [ret (apply f args)]
          (swap! mem assoc args ret)
          ret)))))

(defn trampoline
  ([f]
   (let [ret (f)]
     (if (fn? ret)
       (recur ret)
       ret)))
  ([f & args]
   (trampoline (fn [] (apply f args)))))

;; Key comparison — max-key, min-key

(defn max-key
  ([k x] x)
  ([k x y] (if (> (k x) (k y)) x y))
  ([k x y & more]
   (reduce (fn [best item]
             (if (>= (k item) (k best)) item best))
           (max-key k x y) more)))

(defn min-key
  ([k x] x)
  ([k x y] (if (< (k x) (k y)) x y))
  ([k x y & more]
   (reduce (fn [best item]
             (if (<= (k item) (k best)) item best))
           (min-key k x y) more)))

;; UPSTREAM-DIFF: no transient/persistent!, no with-meta
(defn update-vals
  [m f]
  (reduce-kv (fn [acc k v] (assoc acc k (f v)))
             {} m))

;; UPSTREAM-DIFF: no transient/persistent!, no with-meta
(defn update-keys
  [m f]
  (reduce-kv (fn [acc k v] (assoc acc (f k) v))
             {} m))

(defn ffirst [x] (first (first x)))

(defn nnext [x] (next (next x)))

;; UPSTREAM-DIFF: uses take instead of 2-arg map (multi-coll map not supported)
(defn drop-last
  ([coll] (drop-last 1 coll))
  ([n coll]
   (let [s (seq coll)
         cnt (count s)]
     (take (max 0 (- cnt n)) s))))

(defn split-at [n coll]
  [(take n coll) (drop n coll)])

(defn split-with [pred coll]
  [(take-while pred coll) (drop-while pred coll)])
