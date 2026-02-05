;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.

;; Bootstrap defn — will be redefined below with docstring/metadata support
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

;; last/butlast defined early — needed by enhanced defn below
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

;; Full defn: strips docstring, attr-map, trailing attr-map
;; UPSTREAM-DIFF: No arglists metadata, no inline support, no with-meta on name
(defmacro defn [name & fdecl]
  (let [fdecl (if (string? (first fdecl))
                (next fdecl)
                fdecl)
        fdecl (if (map? (first fdecl))
                (next fdecl)
                fdecl)
        fdecl (if (vector? (first fdecl))
                (list fdecl)
                fdecl)
        fdecl (if (map? (last fdecl))
                (butlast fdecl)
                fdecl)]
    `(def ~name (fn ~name ~@fdecl))))

(defn map
  ([f]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (rf result (f input))))))
  ([f coll]
   (lazy-seq
    (let [s (seq coll)]
      (when s
        (if (chunked-seq? s)
          (let [c (chunk-first s)
                size (count c)
                b (chunk-buffer size)]
            (loop [i 0]
              (when (< i size)
                (chunk-append b (f (nth c i)))
                (recur (inc i))))
            (chunk-cons (chunk b) (map f (chunk-rest s))))
          (cons (f (first s)) (map f (rest s)))))))))

(defn filter
  ([pred]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (if (pred input)
          (rf result input)
          result)))))
  ([pred coll]
   (lazy-seq
    (let [s (seq coll)]
      (when s
        (if (chunked-seq? s)
          (let [c (chunk-first s)
                size (count c)
                b (chunk-buffer size)]
            (loop [i 0]
              (when (< i size)
                (let [v (nth c i)]
                  (when (pred v)
                    (chunk-append b v)))
                (recur (inc i))))
            (chunk-cons (chunk b) (filter pred (chunk-rest s))))
          (let [f (first s) r (rest s)]
            (if (pred f)
              (cons f (filter pred r))
              (filter pred r)))))))))

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
  (lazy-seq
   (when (pos? n)
     (let [s (seq coll)]
       (when s
         (cons (first s) (take (dec n) (rest s))))))))

(defn drop [n coll]
  (lazy-seq
   (loop [i n s (seq coll)]
     (if (if (> i 0) s nil)
       (recur (- i 1) (next s))
       s))))

(defn mapcat [f coll]
  ((fn step [cur remaining]
     (lazy-seq
      (if (seq cur)
        (cons (first cur) (step (rest cur) remaining))
        (let [s (seq remaining)]
          (when s
            (step (f (first s)) (rest s)))))))
   nil coll))

;; Core macros

(defmacro comment [& body] nil)

(defmacro cond
  "Takes a set of test/expr pairs. It evaluates each test one at a
  time.  If a test returns logical true, cond evaluates and returns
  the value of the corresponding expr and doesn't evaluate any of the
  other tests or exprs. (cond) returns nil."
  [& clauses]
  (when (seq clauses)
    (if (next clauses) ;; CLJW: upstream throws IllegalArgumentException for odd forms
      (let [test (first clauses)
            then (first (next clauses)) ;; CLJW: (second) not yet available at bootstrap
            more (next (next clauses))]
        (if more
          `(if ~test ~then (cond ~@more))
          `(if ~test ~then)))
      (throw (str "cond requires an even number of forms")))))

(defmacro if-not [test then & more]
  `(if (not ~test) ~then ~(first more)))

(defmacro when-not [test & body]
  `(if (not ~test) (do ~@body)))

;; Utility functions

(defn identity [x] x)

(defn constantly [x]
  (fn [& args] x))

(defn complement [f]
  (fn [& args]
    (not (apply f args))))

;; UPSTREAM-DIFF: No :private metadata (F78 needed for symbol meta)
(defmacro defn- [name & fdecl]
  `(defn ~name ~@fdecl))

;; Namespace declaration
;; UPSTREAM-DIFF: Simplified ns macro; no :import, no docstring, no :gen-class

(defmacro ns [name & references]
  (let [docstring (when (string? (first references)) (first references))
        references (if docstring (rest references) references)
        process-ref (fn [ref-form]
                      (let [kw (first ref-form)
                            args (rest ref-form)]
                        (cond
                          (= kw :require)
                          (map (fn [arg] `(require '~arg)) args)

                          (= kw :use)
                          (map (fn [arg] `(use '~arg)) args)

                          (= kw :refer-clojure)
                          (let [quote-vals (fn quote-vals [xs]
                                             (if (seq xs)
                                               (cons (first xs)
                                                     (cons (list 'quote (second xs))
                                                           (quote-vals (rest (rest xs)))))
                                               nil))]
                            (list (apply list 'clojure.core/refer ''clojure.core
                                         (quote-vals args))))

                          :else nil)))
        ref-forms (apply concat (map process-ref references))]
    `(do (in-ns '~name) ~@ref-forms)))

;; Threading macros

(defmacro -> [x & forms]
  (loop [x x, forms forms]
    (if forms
      (let [form (first forms)
            threaded (if (seq? form)
                       (with-meta `(~(first form) ~x ~@(next form)) (meta form))
                       (list form x))]
        (recur threaded (next forms)))
      x)))

(defmacro ->> [x & forms]
  (loop [x x, forms forms]
    (if forms
      (let [form (first forms)
            threaded (if (seq? form)
                       (with-meta `(~(first form) ~@(next form) ~x) (meta form))
                       (list form x))]
        (recur threaded (next forms)))
      x)))

;; Iteration

(defmacro dotimes
  "bindings => name n

  Repeatedly executes body (presumably for side-effects) with name
  bound to integers from 0 through n-1."
  [bindings & body]
  (let [i (first bindings)
        n (second bindings)]
    `(let [n# (long ~n)]
       (loop [~i 0]
         (when (< ~i n#)
           ~@body
           (recur (unchecked-inc ~i)))))))

;; and/or

(defmacro and
  [& args]
  (if (nil? (seq args))
    true
    (let [a (first args)
          more (rest args)]
      (if (seq more)
        `(let [and__val ~a]
           (if and__val (and ~@more) and__val))
        a))))

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
  (with-meta
    (reduce (fn [acc k]
              (let [v (get m k)]
                (if (not (nil? v))
                  (assoc acc k v)
                  acc)))
            {}
            keyseq)
    (meta m)))

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

(defn partition
  ([n coll]
   (partition n n coll))
  ([n step coll]
   (loop [s (seq coll) acc (list)]
     (let [chunk (take n s)]
       (if (= (count chunk) n)
         (recur (drop step s) (cons chunk acc))
         (reverse acc)))))
  ([n step pad coll]
   (loop [s (seq coll) acc (list)]
     (let [chunk (take n s)]
       (if (= (count chunk) n)
         (recur (drop step s) (cons chunk acc))
         (if (seq chunk)
           (reverse (cons (take n (concat chunk pad)) acc))
           (reverse acc)))))))

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

(defn interleave
  ([] (list))
  ([c1] (lazy-seq c1))
  ([c1 c2]
   (lazy-seq
    (let [s1 (seq c1) s2 (seq c2)]
      (when (and s1 s2)
        (cons (first s1) (cons (first s2)
                               (interleave (rest s1) (rest s2))))))))
  ([c1 c2 & colls]
   (lazy-seq
    (let [ss (map seq (cons c1 (cons c2 colls)))]
      (when (every? identity ss)
        (concat (map first ss) (apply interleave (map rest ss))))))))

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

;; CLJW: Simplified assert-args — upstream uses &form and IllegalArgumentException
;; Note: uses (next (next ...)) and (first (next ...)) because nnext/second
;; are not yet defined at this point in core.clj bootstrap
(defmacro ^{:private true} assert-args
  [& pairs]
  (let [checks (loop [ps pairs acc []]
                 (if (seq ps)
                   (recur (next (next ps))
                          (conj acc (list 'when-not (first ps)
                                          (list 'throw (list 'str "Requires " (first (next ps)))))))
                   acc))]
    (cons 'do checks)))

(defmacro if-let
  "bindings => binding-form test

  If test is true, evaluates then with binding-form bound to the value of
  test, if not, yields else"
  ([bindings then]
   `(if-let ~bindings ~then nil))
  ([bindings then else & oldform]
   (assert-args
    (vector? bindings) "a vector for its binding"
    (nil? oldform) "1 or 2 forms after binding vector"
    (= 2 (count bindings)) "exactly 2 forms in binding vector")
   (let [form (first bindings) tst (first (next bindings))]
     `(let [temp# ~tst]
        (if temp#
          (let [~form temp#]
            ~then)
          ~else)))))

(defmacro when-let
  "bindings => binding-form test

  When test is true, evaluates body with binding-form bound to the value of test"
  [bindings & body]
  (assert-args
   (vector? bindings) "a vector for its binding"
   (= 2 (count bindings)) "exactly 2 forms in binding vector")
  (let [form (first bindings) tst (first (next bindings))]
    `(let [temp# ~tst]
       (when temp#
         (let [~form temp#]
           ~@body)))))

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

;; Shadow eager concat builtin with lazy version
(defn concat
  ([] nil)
  ([x] (lazy-seq x))
  ([x y]
   (lazy-seq
    (let [s (seq x)]
      (if s
        (cons (first s) (concat (rest s) y))
        y))))
  ([x y & zs]
   (let [cat (fn cat [xy zs]
               (lazy-seq
                (let [s (seq xy)]
                  (if s
                    (cons (first s) (cat (rest s) zs))
                    (when zs
                      (cat (first zs) (next zs)))))))]
     (cat (concat x y) zs))))

(defn iterate [f x]
  (lazy-seq (cons x (iterate f (f x)))))

;; Lazy range — shadows eager builtin for lazy seq support
(defn range
  ([] (iterate inc 0))
  ([end] (range 0 end 1))
  ([start end] (range start end 1))
  ([start end step]
   (lazy-seq
    (cond
      (and (pos? step) (< start end))
      (cons start (range (+ start step) end step))
      (and (neg? step) (> start end))
      (cons start (range (+ start step) end step))))))

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
  (lazy-seq
   (when-let [s (seq coll)]
     (if (chunked-seq? s)
       (let [c (chunk-first s)
             size (count c)
             b (chunk-buffer size)]
         (loop [i 0]
           (when (< i size)
             (let [x (f (nth c i))]
               (when-not (nil? x)
                 (chunk-append b x)))
             (recur (inc i))))
         (chunk-cons (chunk b) (keep f (chunk-rest s))))
       (let [x (f (first s))]
         (if (nil? x)
           (keep f (rest s))
           (cons x (keep f (rest s)))))))))

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
  (lazy-seq
   (let [s (seq coll)]
     (when s
       (when (pred (first s))
         (cons (first s) (take-while pred (rest s))))))))

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

;; Convenience accessors (last/butlast defined early for defn macro)

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

;; UPSTREAM-DIFF: cond-based, no case* optimization, no multi-value test (F27), no symbol match (F28)
(defmacro case [expr & clauses]
  (let [pairs (partition 2 clauses)
        default (if (= (* 2 (count pairs)) (count clauses))
                  nil
                  (last clauses))
        gexpr '__case_val__
        quote-const (fn [c]
                      (if (symbol? c)
                        (list 'quote c)
                        c))
        test-expr (fn [test]
                    (if (seq? test)
                      (cons 'or (map (fn [t] (list '= gexpr (quote-const t))) test))
                      (list '= gexpr (quote-const test))))]
    `(let [~gexpr ~expr]
       (cond
         ~@(mapcat (fn [pair]
                     (list (test-expr (first pair))
                           (second pair)))
                   pairs)
         ~@(if default
             (list true default)
             (list true `(throw (str "No matching clause: " ~gexpr))))))))

(defmacro condp
  "Takes a binary predicate, an expression, and a set of clauses.
  Each clause can take the form of either:

  test-expr result-expr

  test-expr :>> result-fn

  Note :>> is an ordinary keyword.

  For each clause, (pred test-expr expr) is evaluated. If it returns
  logical true, the clause is a match. If a binary clause matches, the
  result-expr is returned, if a ternary clause matches, its result-fn,
  which must be a unary function, is called with the result of the
  predicate as its argument, the result of that call being the return
  value of condp. A single default expression can follow the clauses,
  and its value will be returned if no clause matches. If no default
  expression is provided and no clause matches, an exception is thrown."
  [pred expr & clauses]
  (let [gpred (gensym "pred__")
        gexpr (gensym "expr__")
        emit (fn emit [pred expr args]
               (let [cnt (count args)]
                 (cond
                   (= 0 cnt)
                   `(throw (ex-info (str "No matching clause: " ~expr) {}))
                   (= 1 cnt)
                   (first args)
                   (= :>> (second args))
                   (let [a (first args)
                         c (first (rest (rest args)))
                         more (rest (rest (rest args)))]
                     `(if-let [p# (~pred ~a ~expr)]
                        (~c p#)
                        ~(emit pred expr more)))
                   :else
                   (let [a (first args)
                         b (second args)
                         more (rest (rest args))]
                     `(if (~pred ~a ~expr)
                        ~b
                        ~(emit pred expr more))))))]
    `(let [~gpred ~pred
           ~gexpr ~expr]
       ~(emit gpred gexpr clauses))))

(defmacro declare [& names]
  (cons 'do (map (fn [n] (list 'def n)) names)))

;; Imperative iteration

(defmacro while [test & body]
  `(loop []
     (when ~test
       ~@body
       (recur))))

(defmacro doseq [seq-exprs & body]
  (let [step (fn step [recform exprs]
               (if (nil? (seq exprs))
                 [true (cons 'do body)]
                 (let [k (first exprs)
                       v (second exprs)]
                   (if (keyword? k)
                     (let [steppair (step recform (rest (rest exprs)))
                           needrec (first steppair)
                           subform (second steppair)]
                       (cond
                         (= k :let) [needrec (list 'let v subform)]
                         (= k :while) [false (if needrec
                                               (list 'when v subform recform)
                                               (list 'when v subform))]
                         (= k :when) [false (if needrec
                                              (list 'if v (list 'do subform recform) recform)
                                              (list 'if v subform recform))]))
                     (let [s '__doseq_s__
                           recform2 (list 'recur (list 'next s))
                           steppair (step recform2 (rest (rest exprs)))
                           needrec (first steppair)
                           subform (second steppair)
                           ;; Chunked path: inner loop over chunk elements
                           chunk-body (list 'let ['__doseq_c__ (list 'chunk-first s)
                                                  '__doseq_size__ (list 'count '__doseq_c__)]
                                            (list 'loop ['__doseq_i__ 0]
                                                  (list 'when (list '< '__doseq_i__ '__doseq_size__)
                                                        (list 'let [k (list 'nth '__doseq_c__ '__doseq_i__)]
                                                              subform)
                                                        (list 'recur (list 'inc '__doseq_i__))))
                                            (list 'recur (list 'chunk-rest s)))
                           ;; Non-chunked path: first/next
                           plain-body (if needrec
                                        (list 'let [k (list 'first s)]
                                              subform
                                              recform2)
                                        (list 'let [k (list 'first s)]
                                              subform))]
                       [true
                        (list 'loop [s (list 'seq v)]
                              (list 'when s
                                    (list 'if (list 'chunked-seq? s)
                                          chunk-body
                                          plain-body)))])))))]
    (second (step nil (seq seq-exprs)))))

(defn dorun [coll]
  (loop [s (seq coll)]
    (when s
      (recur (next s)))))

(defn doall [coll]
  (dorun coll)
  coll)

;; Delayed evaluation

(defmacro delay [& body]
  (list '__delay-create (cons 'fn (cons [] body))))

(defn force [x]
  (if (delay? x)
    (deref x)
    x))

(defn realized? [x]
  (cond
    (delay? x) (__delay-realized? x)
    (= (type x) :lazy-seq) (__lazy-seq-realized? x)
    :else false))

(defn delay? [x]
  (__delay? x))

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

;; Simple stub; redefined with hierarchy support after global-hierarchy
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

(defmacro refer-clojure
  [& filters]
  (cons 'clojure.core/refer (cons (list 'quote 'clojure.core) filters)))

;; Metadata utilities

(defn vary-meta
  [obj f & args]
  (with-meta obj (apply f (meta obj) args)))

;; Nil-safe conditionals

(defmacro if-some
  "bindings => binding-form test

   If test is not nil, evaluates then with binding-form bound to the
   value of test, if not, yields else"
  ([bindings then]
   `(if-some ~bindings ~then nil))
  ([bindings then else & oldform]
   (assert-args
    (vector? bindings) "a vector for its binding"
    (nil? oldform) "1 or 2 forms after binding vector"
    (= 2 (count bindings)) "exactly 2 forms in binding vector")
   (let [form (first bindings) tst (first (next bindings))]
     `(let [temp# ~tst]
        (if (nil? temp#)
          ~else
          (let [~form temp#]
            ~then))))))

(defmacro when-some
  "bindings => binding-form test

   When test is not nil, evaluates body with binding-form bound to the
   value of test"
  [bindings & body]
  (assert-args
   (vector? bindings) "a vector for its binding"
   (= 2 (count bindings)) "exactly 2 forms in binding vector")
  (let [form (first bindings) tst (first (next bindings))]
    `(let [temp# ~tst]
       (if (nil? temp#)
         nil
         (let [~form temp#]
           ~@body)))))

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

(defn update-vals
  [m f]
  (with-meta
    (persistent!
     (reduce-kv (fn [acc k v] (assoc! acc k (f v)))
                (transient {})
                m))
    (meta m)))

(defn update-keys
  [m f]
  (let [ret (persistent!
             (reduce-kv (fn [acc k v] (assoc! acc (f k) v))
                        (transient {})
                        m))]
    (with-meta ret (meta m))))

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

;; Spec predicates (1.9)

(defn pos-int? [x] (and (int? x) (pos? x)))

(defn neg-int? [x] (and (int? x) (neg? x)))

(defn nat-int? [x] (and (int? x) (not (neg? x))))

(defn ident? [x] (or (keyword? x) (symbol? x)))

(defn simple-ident? [x] (and (ident? x) (nil? (namespace x))))

(defn qualified-ident? [x] (boolean (and (ident? x) (namespace x) true)))

(defn simple-symbol? [x] (and (symbol? x) (nil? (namespace x))))

(defn qualified-symbol? [x] (boolean (and (symbol? x) (namespace x) true)))

(defn simple-keyword? [x] (and (keyword? x) (nil? (namespace x))))

(defn qualified-keyword? [x] (boolean (and (keyword? x) (namespace x) true)))

;; UPSTREAM-DIFF: equivalent to float? (ClojureWasm uses f64 for all floats)
(defn double? [x] (float? x))

;; UPSTREAM-DIFF: pure Clojure, upstream uses Double/isNaN
(defn NaN? [num] (not (= num num)))

;; UPSTREAM-DIFF: pure Clojure, upstream uses Double/isInfinite
(defn infinite? [num] (or (= num ##Inf) (= num ##-Inf)))

;; UPSTREAM-DIFF: returns nil for non-string instead of throwing
(defn parse-boolean [s]
  (when (string? s)
    (case s
      "true" true
      "false" false
      nil)))

;; Seq utilities

(defn rand-nth [coll] (nth coll (rand-int (count coll))))

(defn run! [proc coll]
  (reduce (fn [_ x] (proc x)) nil coll)
  nil)

;; UPSTREAM-DIFF: no IDrop interface, uses loop instead
(defn nthnext [coll n]
  (loop [n n xs (seq coll)]
    (if (and xs (pos? n))
      (recur (dec n) (next xs))
      xs)))

;; UPSTREAM-DIFF: no IDrop interface, uses loop instead
(defn nthrest [coll n]
  (loop [n n xs coll]
    (if (pos? n)
      (recur (dec n) (rest xs))
      xs)))

(defn take-last [n coll]
  (loop [s (seq coll) lead (seq (drop n coll))]
    (if lead
      (recur (next s) (next lead))
      s)))

;; UPSTREAM-DIFF: avoids [x & etc :as xs] loop destructuring
(defn distinct?
  ([x] true)
  ([x y] (not (= x y)))
  ([x y & more]
   (if (not= x y)
     (loop [s #{x y} xs (seq more)]
       (if xs
         (if (contains? s (first xs))
           false
           (recur (conj s (first xs)) (next xs)))
         true))
     false)))

(defn tree-seq
  "Returns a lazy sequence of the nodes in a tree, via a depth-first walk."
  [branch? children root]
  (let [walk (fn walk [node]
               (lazy-seq
                (cons node
                      (when (branch? node)
                        (mapcat walk (children node))))))]
    (walk root)))

(defn completing
  "Takes a reducing function f of 2 args and returns a fn suitable for
  transduce by adding an arity-1 signature that calls cf (default -
  identity) on the result argument."
  ([f] (completing f identity))
  ([f cf]
   (fn
     ([] (f))
     ([x] (cf x))
     ([x y] (f x y)))))

(defn reductions
  "Returns a lazy seq of the intermediate values of the reduction (as
  per reduce) of coll by f, starting with init."
  ([f coll]
   (lazy-seq
    (if-let [s (seq coll)]
      (reductions f (first s) (rest s))
      (list (f)))))
  ([f init coll]
   (if (reduced? init)
     (list @init)
     (cons init
           (lazy-seq
            (when-let [s (seq coll)]
              (reductions f (f init (first s)) (rest s))))))))

(defn take-nth
  "Returns a lazy seq of every nth item in coll."
  [n coll]
  (lazy-seq
   (when-let [s (seq coll)]
     (cons (first s) (take-nth n (drop n s))))))

(defn replace
  "Given a map of replacement pairs and a vector/collection, returns a
  vector/seq with any elements = a key in smap replaced with the
  corresponding val in smap."
  [smap coll]
  (if (vector? coll)
    (reduce (fn [v i]
              (if-let [e (find smap (nth v i))]
                (assoc v i (val e))
                v))
            coll (range (count coll)))
    (map (fn [x] (if-let [e (find smap x)] (val e) x)) coll)))

;; Unchecked arithmetic (no auto-promotion in ClojureWasm, so identical to checked)
(defn unchecked-inc [x] (+ x 1))
(defn unchecked-dec [x] (- x 1))
(defn unchecked-inc-int [x] (+ x 1))
(defn unchecked-dec-int [x] (- x 1))
(defn unchecked-negate [x] (- x))
(defn unchecked-negate-int [x] (- x))
(defn unchecked-add [x y] (+ x y))
(defn unchecked-add-int [x y] (+ x y))
(defn unchecked-subtract [x y] (- x y))
(defn unchecked-subtract-int [x y] (- x y))
(defn unchecked-multiply [x y] (* x y))
(defn unchecked-multiply-int [x y] (* x y))
(defn unchecked-divide-int [x y] (quot x y))
(defn unchecked-remainder-int [x y] (rem x y))

;; Unchecked type coercion
(defn unchecked-byte [x]
  (let [v (bit-and (long x) 0xFF)]
    (if (> v 127) (- v 256) v)))
(defn unchecked-short [x]
  (let [v (bit-and (long x) 0xFFFF)]
    (if (> v 32767) (- v 65536) v)))
(defn unchecked-char [x]
  (char (bit-and (long x) 0xFFFF)))
(defn unchecked-int [x]
  (let [v (bit-and (long x) 0xFFFFFFFF)]
    (if (> v 2147483647) (- v 4294967296) v)))
(defn unchecked-long [x] (long x))
(defn unchecked-float [x] (double x))
(defn unchecked-double [x] (double x))

;; Auto-promoting arithmetic (no BigInt, so identical to checked)
(def inc' inc)
(def dec' dec)
(defn +' ([] 0) ([x] x) ([x y] (+ x y)) ([x y & more] (apply + x y more)))
(defn -' ([x] (- x)) ([x y] (- x y)) ([x y & more] (apply - x y more)))
(defn *' ([] 1) ([x] x) ([x y] (* x y)) ([x y & more] (apply * x y more)))

;; === IO macros ===

(defmacro with-out-str
  "Evaluates exprs in a context in which *out* is bound to a fresh
  buffer. Returns the string created by any nested printing calls."
  [& body]
  `(let [_# (push-output-capture)
         _# (try (do ~@body) (catch Exception e# (pop-output-capture) (throw e#)))]
     (pop-output-capture)))

;; === Transducer basics ===

(defn transduce
  "reduce with a transformation of f (xf). If init is not
  supplied, (f) will be called to produce it."
  ([xform f coll] (transduce xform f (f) coll))
  ([xform f init coll]
   (let [xf (xform f)
         ret (reduce xf init coll)]
     (xf ret))))

;; UPSTREAM-DIFF: simplified from clojure.core.protocols/coll-reduce to plain reduce

;; Override builtin into to support 3-arity (transducer)
(defn into
  "Returns a new coll consisting of to with all of the items of
  from conjoined. A transducer may be supplied."
  ([] [])
  ([to] to)
  ([to from] (reduce conj to from))
  ([to xform from]
   (transduce xform conj to from)))

(defn- preserving-reduced
  [rf]
  (fn [a b]
    (let [ret (rf a b)]
      (if (reduced? ret)
        (reduced ret)
        ret))))

(defn cat
  "A transducer which concatenates the contents of each input, which must be a
  collection, into the reduction."
  [rf]
  (let [rrf (preserving-reduced rf)]
    (fn
      ([] (rf))
      ([result] (rf result))
      ([result input]
       (reduce rrf result input)))))

(defn halt-when
  "Returns a transducer that ends transduction when pred returns true
  for an input. When retf is supplied it must be a fn of 2 arguments -
  it will be passed the (completed) result so far and the input that
  triggered the predicate, and its return value (if it does not throw
  an exception) will be the return value of the transducer. If retf
  is not supplied, the input that triggered the predicate will be
  returned. If the predicate never returns true the transduction is
  unaffected."
  ([pred] (halt-when pred nil))
  ([pred retf]
   (fn [rf]
     (fn
       ([] (rf))
       ([result]
        (if (and (map? result) (contains? result ::halt))
          (::halt result)
          (rf result)))
       ([result input]
        (if (pred input)
          (reduced {::halt (if retf (retf (rf result) input) input)})
          (rf result input)))))))

(defn dedupe
  "Returns a lazy sequence removing consecutive duplicates in coll.
  Returns a transducer when no collection is provided."
  ([]
   (fn [rf]
     (let [pv (volatile! ::none)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [prior @pv]
            (vreset! pv input)
            (if (= prior input)
              result
              (rf result input))))))))
  ([coll] (sequence (dedupe) coll)))

(defn sequence
  "Coerces coll to a (possibly empty) sequence, if it is not already
  one. Will not force a lazy seq. (sequence nil) yields (). When a
  transducer is supplied, returns a lazy sequence of applications of
  the transform to the items in coll(s)."
  ([coll]
   (if (seq? coll) coll
       (or (seq coll) ())))
  ;; CLJW: upstream uses TransformerIterator; we eagerly transduce via into then seq
  ([xform coll]
   (or (seq (into [] xform coll)) ()))
  ([xform coll & colls]
   (or (seq (into [] xform (apply map vector (cons coll colls)))) ())))

;; === Pure Clojure additions ===

(defn random-sample
  "Returns items from coll with random probability of prob (0.0 -
  1.0).  Returns a transducer when no collection is provided."
  ([prob]
   (filter (fn [_] (< (rand) prob))))
  ([prob coll]
   (filter (fn [_] (< (rand) prob)) coll)))

(defn replicate
  "DEPRECATED: Use 'repeat' instead.
   Returns a lazy seq of n xs."
  [n x] (take n (repeat x)))

(defn comparator
  "Returns an implementation of a comparator based upon pred."
  [pred]
  (fn [x y]
    (cond (pred x y) -1 (pred y x) 1 :else 0)))

(defn xml-seq
  "A tree seq on the xml elements as per xml/parse"
  [root]
  (tree-seq
   (complement string?)
   (comp seq :content)
   root))

(defn printf
  "Prints formatted output, as per format"
  [fmt & args]
  (print (apply format fmt args)))

(defn test
  "test [v] finds fn at key :test in var metadata and calls it,
  presuming failure will throw exception"
  [v]
  (let [f (:test (meta v))]
    (if f
      (do (f) :ok)
      :no-test)))

(defn mapv
  "Returns a vector consisting of the result of applying f to the
  set of first items of each coll, followed by applying f to the set
  of second items in each coll, until any one of the colls is
  exhausted."
  ([f coll]
   (-> (reduce (fn [v o] (conj! v (f o))) (transient []) coll)
       persistent!)))

(defmacro time
  "Evaluates expr and prints the time it took. Returns the value of expr."
  [expr]
  (list 'let ['start__ (list '__nano-time)
              'ret__ expr]
        (list 'prn (list 'str "Elapsed time: "
                         (list '/ (list 'double (list '- (list '__nano-time) 'start__)) 1000000.0)
                         " msecs"))
        'ret__))

(defmacro lazy-cat
  "Expands to code which yields a lazy sequence of the concatenation
  of the supplied colls. Each coll expr is not evaluated until it is
  needed."
  [& colls]
  (cons 'concat (map (fn [c] (list 'lazy-seq c)) colls)))

(defmacro when-first
  "bindings => x xs

  Roughly the same as (when (seq xs) (let [x (first xs)] body))
  but xs is evaluated only once"
  [bindings & body]
  (let [x (first bindings)
        xs (second bindings)]
    (list 'when-let ['xs__ (list 'seq xs)]
          (concat (list 'let [x (list 'first 'xs__)])
                  body))))

(def *assert* true)

(defmacro assert
  "Evaluates expr and throws an AssertionError if it does not evaluate to
  logical true."
  ([x]
   (when *assert*
     `(when-not ~x
        (throw (str "Assert failed: " (pr-str '~x))))))
  ([x message]
   (when *assert*
     `(when-not ~x
        (throw (str "Assert failed: " ~message "\n" (pr-str '~x)))))))

;; Hierarchy

(defn not-empty
  "If coll is empty, returns nil, else coll"
  [coll] (when (seq coll) coll))

(defn make-hierarchy
  "Creates a hierarchy object for use with derive, isa? etc."
  []
  {:parents {} :descendants {} :ancestors {}})

(def ^:private global-hierarchy (make-hierarchy))

(defn isa?
  "Returns true if (= child parent), or child is directly or indirectly
  derived from parent, either via a relationship established via derive.
  h must be a hierarchy obtained from make-hierarchy, if not supplied
  defaults to the global hierarchy"
  ([child parent] (isa? global-hierarchy child parent))
  ([h child parent]
   (or (= child parent)
       (contains? ((:ancestors h) child) parent)
       (and (vector? parent) (vector? child)
            (= (count parent) (count child))
            (loop [ret true i 0]
              (if (or (not ret) (= i (count parent)))
                ret
                (recur (isa? h (nth child i) (nth parent i)) (inc i))))))))

(defn parents
  "Returns the immediate parents of tag, either via a relationship
  established via derive. h must be a hierarchy obtained from
  make-hierarchy, if not supplied defaults to the global hierarchy"
  ([tag] (parents global-hierarchy tag))
  ([h tag] (not-empty (get (:parents h) tag))))

(defn ancestors
  "Returns the immediate and indirect parents of tag, either via a
  relationship established via derive. h must be a hierarchy obtained
  from make-hierarchy, if not supplied defaults to the global hierarchy"
  ([tag] (ancestors global-hierarchy tag))
  ([h tag] (not-empty (get (:ancestors h) tag))))

(defn descendants
  "Returns the immediate and indirect children of tag, through a
  relationship established via derive. h must be a hierarchy obtained
  from make-hierarchy, if not supplied defaults to the global hierarchy."
  ([tag] (descendants global-hierarchy tag))
  ([h tag] (not-empty (get (:descendants h) tag))))

(defn derive
  "Establishes a parent/child relationship between parent and
  tag. Parent must be a namespace-qualified symbol or keyword and
  child can be either a namespace-qualified symbol or keyword.
  h must be a hierarchy obtained from make-hierarchy, if not
  supplied defaults to, and modifies, the global hierarchy."
  ([tag parent]
   (alter-var-root #'global-hierarchy derive tag parent) nil)
  ([h tag parent]
   (assert (not= tag parent))
   (let [tp (:parents h)
         td (:descendants h)
         ta (:ancestors h)
         tf (fn [m source sources target targets]
              (reduce (fn [ret k]
                        (assoc ret k
                               (reduce conj (get targets k #{}) (cons target (targets target)))))
                      m (cons source (sources source))))]
     (or
      (when-not (contains? (tp tag) parent)
        (when (contains? (ta tag) parent)
          (throw (str tag " already has " parent " as ancestor")))
        (when (contains? (ta parent) tag)
          (throw (str "Cyclic derivation: " parent " has " tag " as ancestor")))
        {:parents (assoc (:parents h) tag (conj (get tp tag #{}) parent))
         :ancestors (tf (:ancestors h) tag td parent ta)
         :descendants (tf (:descendants h) parent ta tag td)})
      h))))

(defn underive
  "Removes a parent/child relationship between parent and
  tag. h must be a hierarchy obtained from make-hierarchy, if not
  supplied defaults to, and modifies, the global hierarchy."
  ([tag parent] (alter-var-root #'global-hierarchy underive tag parent) nil)
  ([h tag parent]
   (let [parentMap (:parents h)
         childsParents (if (parentMap tag)
                         (disj (parentMap tag) parent) #{})
         newParents (if (not-empty childsParents)
                      (assoc parentMap tag childsParents)
                      (dissoc parentMap tag))
         deriv-seq (flatten (map #(cons (key %) (interpose (key %) (val %)))
                                 (seq newParents)))]
     (if (contains? (parentMap tag) parent)
       (reduce #(apply derive %1 %2) (make-hierarchy)
               (partition 2 deriv-seq))
       h))))

;; Version
(def *clojure-version*
  {:major 1 :minor 12 :incremental 0 :qualifier nil})

(defn clojure-version
  "Returns clojure version as a printable string."
  []
  (let [v *clojure-version*]
    (str (:major v) "." (:minor v)
         (when-let [i (:incremental v)] (str "." i))
         (when-let [q (:qualifier v)] (str "-" q)))))

;; Type cast (identity in ClojureWasm - no JVM type system)
(defn cast
  "Throws a ClassCastException if val is not an instance of c, else returns val."
  [c x] x)

;; Dynamic binding
(defmacro binding [bindings & body]
  (let [pairs (partition 2 bindings)
        bind-forms (mapcat (fn [p] (list (list 'var (first p)) (second p)))
                           pairs)]
    `(do
       (push-thread-bindings (hash-map ~@bind-forms))
       (try
         ~@body
         (finally
           (pop-thread-bindings))))))

(defn with-bindings*
  "Takes a map of Var/value pairs. Sets the vars to the corresponding
  values during the execution of f."
  [binding-map f & args]
  (push-thread-bindings binding-map)
  (try
    (apply f args)
    (finally
      (pop-thread-bindings))))

(defmacro with-bindings
  "Takes a map of Var/value pairs. Installs the given bindings for the
  execution of body."
  [binding-map & body]
  `(with-bindings* ~binding-map (fn [] ~@body)))

(defn with-redefs-fn
  "Temporarily redefines vars during the execution of func."
  [binding-map func]
  (let [root-bind (fn [m]
                    (doseq [[a-var a-val] m]
                      (var-set a-var a-val)))
        old-vals (zipmap (keys binding-map)
                         (map var-raw-root (keys binding-map)))]
    (try
      (root-bind binding-map)
      (func)
      (finally
        (root-bind old-vals)))))

(defmacro with-redefs
  "Temporarily redefines vars while body executes."
  [bindings & body]
  (let [names (take-nth 2 bindings)
        vals  (take-nth 2 (next bindings))
        tempvar-map (zipmap (map (fn [n] (list 'var n)) names) vals)]
    `(with-redefs-fn ~tempvar-map (fn [] ~@body))))

;; Dynamic vars (stubs for JVM compat)
(def ^:dynamic *warn-on-reflection* false)

;; Char tables (from core_print.clj)
(def char-escape-string
  {\newline "\\n"
   \tab     "\\t"
   \return  "\\r"
   \"       "\\\""
   \\       "\\\\"
   \formfeed "\\f"
   \backspace "\\b"})

(def char-name-string
  {\newline  "newline"
   \tab      "tab"
   \space    "space"
   \backspace "backspace"
   \formfeed "formfeed"
   \return   "return"})

;; Munge (Compiler.CHAR_MAP equivalent)
(def ^:private munge-char-map
  {\- "_", \: "_COLON_", \+ "_PLUS_", \> "_GT_", \< "_LT_",
   \= "_EQ_", \~ "_TILDE_", \. "_DOT_",
   \! "_BANG_", \@ "_CIRCA_", \# "_SHARP_",
   \' "_SINGLEQUOTE_", \" "_DOUBLEQUOTE_",
   \% "_PERCENT_", \^ "_CARET_", \& "_AMPERSAND_",
   \* "_STAR_", \| "_BAR_", \{ "_LBRACE_", \} "_RBRACE_",
   \[ "_LBRACK_", \] "_RBRACK_", \/ "_SLASH_",
   \\ "_BSLASH_", \? "_QMARK_"})

(defn munge
  "Munge a name string into an idenitifier-safe string."
  [s]
  ((if (symbol? s) symbol str)
   (apply str (map (fn [c] (or (get munge-char-map c) (str c)))
                   (seq (str s))))))

(defn namespace-munge
  "Convert a Clojure namespace name to a legal identifier."
  [ns]
  (apply str (map (fn [c] (if (= c \-) \_ c)) (seq (str ns)))))

;; === D15 easy wins ===

;; locking (single-threaded, no-op synchronization)
(defmacro locking
  "Executes body in an (effectively) atomic way. In ClojureWasm
  (single-threaded), this simply evaluates body."
  [x & body]
  `(do ~x ~@body))

;; requiring-resolve
(defn requiring-resolve
  "Resolves namespace-qualified sym. Requires ns if not yet loaded."
  [sym]
  (or (resolve sym)
      (do (require (symbol (namespace sym)))
          (resolve sym))))

;; splitv-at — vector version of split-at
(defn splitv-at
  "Returns a vector of [taken-vec rest-seq]."
  [n coll]
  [(vec (take n coll)) (drop n coll)])

;; partitionv — like partition but returns vectors
(defn partitionv
  "Returns a lazy sequence of vectors of n items each."
  ([n coll] (partitionv n n coll))
  ([n step coll]
   (lazy-seq
    (let [s (seq coll)
          p (vec (take n s))]
      (when (= n (count p))
        (cons p (partitionv n step (nthrest s step)))))))
  ([n step pad coll]
   (lazy-seq
    (let [s (seq coll)
          p (vec (take n s))]
      (if (= n (count p))
        (cons p (partitionv n step pad (nthrest s step)))
        (when (seq p)
          (list (vec (take n (concat p pad))))))))))

;; partitionv-all — like partition-all but returns vectors
(defn partitionv-all
  "Returns a lazy sequence of vectors like partition-all."
  ([n coll] (partitionv-all n n coll))
  ([n step coll]
   (lazy-seq
    (let [s (seq coll)]
      (when s
        (let [p (vec (take n s))]
          (cons p (partitionv-all n step (nthrest s step)))))))))

;; Tap system (stub — no async queue, synchronous dispatch)
(def ^:private tap-fns (atom #{}))

(defn add-tap
  "Adds f to the tap set."
  [f]
  (swap! tap-fns conj f)
  nil)

(defn remove-tap
  "Removes f from the tap set."
  [f]
  (swap! tap-fns disj f)
  nil)

(defn tap>
  "Sends val to each tap fn. Returns true if there are taps."
  [val]
  (let [fns @tap-fns]
    (doseq [f fns] (try (f val) (catch Exception _ nil)))
    (boolean (seq fns))))

;; promise / deliver (simplified, no blocking deref)
(defn promise
  "Returns a promise object. Deliver a value with deliver."
  []
  (atom {:val nil :delivered false}))

(defn deliver
  "Delivers val to promise p. Returns p."
  [p val]
  (when-not (:delivered @p)
    (reset! p {:val val :delivered true}))
  p)

;; Data reader constants
(def default-data-readers {})

;; REPL result vars
(def *1 nil)
(def *2 nil)
(def *3 nil)
