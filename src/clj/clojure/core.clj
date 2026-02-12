;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.

;; Bootstrap defn — will be redefined below with docstring/metadata support
(defmacro defn [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

(defmacro when
  "Evaluates test. If logical true, evaluates body in an implicit do."
  {:added "1.0"}
  [test & body]
  (list 'if test (cons 'do body)))

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

;; Full defn: propagates docstring via with-meta on name
;; UPSTREAM-DIFF: No :inline or :arglists metadata support
(defmacro defn [name & fdecl]
  (let [doc (when (string? (first fdecl)) (first fdecl))
        fdecl (if doc (next fdecl) fdecl)
        attr-map (when (map? (first fdecl)) (first fdecl))
        fdecl (if attr-map (next fdecl) fdecl)
        fdecl (if (vector? (first fdecl))
                (list fdecl)
                fdecl)
        fdecl (if (map? (last fdecl))
                (butlast fdecl)
                fdecl)
        ;; Process :pre/:post conditions in each arity.
        ;; Uses loop/recur (not map — map is defined after defn).
        make-asserts
        (fn [conds]
          (loop [cs (seq conds) acc (list)]
            (if cs
              (recur (next cs) (cons (list 'assert (first cs)) acc))
              (reverse acc))))
        process-arity
        (fn [sig]
          (let [params (first sig)
                body (next sig)
                conds (if (next body)
                        (if (map? (first body)) (first body) nil)
                        nil)
                body (if conds (next body) body)
                pre (:pre conds)
                post (:post conds)
                body (if post
                       (let [result-expr (if (next body)
                                           (cons 'do body)
                                           (first body))]
                         (list (concat (list 'let ['% result-expr])
                                       (make-asserts post)
                                       (list '%))))
                       body)
                body (if pre
                       (concat (make-asserts pre) body)
                       body)]
            (cons params body)))
        fdecl (loop [sigs (seq fdecl) acc (list)]
                (if sigs
                  (recur (next sigs) (cons (process-arity (first sigs)) acc))
                  (reverse acc)))
        m (merge (meta name) attr-map (when doc {:doc doc}))
        def-name (if (seq m)
                   (list 'with-meta name m)
                   name)]
    `(def ~def-name (fn ~name ~@fdecl))))

(defn map
  ([f]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (rf result (f input))))))
  ([f coll]
   (__zig-lazy-map f coll)))

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
   (__zig-lazy-filter pred coll)))

(defn reduce
  ([f coll]
   (let [s (seq coll)]
     (if s
       (__zig-reduce f (first s) (next s))
       (f))))
  ([f init coll]
   (__zig-reduce f init coll)))

;; vswap! must be defined before transducer forms that use it
(defmacro vswap! [vol f & args]
  `(vreset! ~vol (~f (deref ~vol) ~@args)))

(defn take
  ([n]
   (fn [rf]
     (let [nv (volatile! n)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [cur @nv
                nxt (vswap! nv dec)
                res (if (pos? cur)
                      (rf result input)
                      result)]
            (if (not (pos? nxt))
              (ensure-reduced res)
              res)))))))
  ([n coll]
   (__zig-lazy-take n coll)))

(defn drop
  ([n]
   (fn [rf]
     (let [nv (volatile! n)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [cur @nv]
            (vswap! nv dec)
            (if (pos? cur)
              result
              (rf result input))))))))
  ([n coll]
   (lazy-seq
    (loop [i n s (seq coll)]
      (if (if (> i 0) s nil)
        (recur (- i 1) (next s))
        s)))))

(defn mapcat
  ([f] (comp (map f) cat))
  ([f coll]
   ((fn step [cur remaining]
      (lazy-seq
       (if (seq cur)
         (cons (first cur) (step (rest cur) remaining))
         (let [s (seq remaining)]
           (when s
             (step (f (first s)) (rest s)))))))
    nil coll)))

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

(defmacro when-not
  "Evaluates test. If logical false, evaluates body in an implicit do."
  {:added "1.0"}
  [test & body]
  (list 'if test nil (cons 'do body)))

;; Utility functions

(defn identity [x] x)

(defn constantly [x]
  (fn [& args] x))

(defn complement [f]
  (fn [& args]
    (not (apply f args))))

(defmacro defn-
  "same as defn, yielding non-public def"
  [name & fdecl]
  (let [doc (when (string? (first fdecl)) (first fdecl))
        fdecl (if doc (next fdecl) fdecl)
        attr-map (when (map? (first fdecl)) (first fdecl))
        fdecl (if attr-map (next fdecl) fdecl)
        fdecl (if (vector? (first fdecl))
                (list fdecl)
                fdecl)
        fdecl (if (map? (last fdecl))
                (butlast fdecl)
                fdecl)
        m (merge {:private true} attr-map (when doc {:doc doc}))]
    `(def ~(list 'with-meta name m) (fn ~name ~@fdecl))))

;; Namespace declaration
;; UPSTREAM-DIFF: no :gen-class (JVM only)

(defmacro ns
  "Sets *ns* to the namespace named by name (unevaluated), creating it
  if needed. references can include :require, :use, :import,
  :refer-clojure."
  [name & references]
  (let [docstring (when (string? (first references)) (first references))
        references (if docstring (rest references) references)
        attr-map (when (map? (first references)) (first references))
        references (if attr-map (rest references) references)
        doc (if docstring docstring (when attr-map (get attr-map :doc)))
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

                          ;; UPSTREAM-DIFF: import registers class short names as symbol vars
                          (= kw :import)
                          (mapcat (fn [spec]
                                    (if (sequential? spec)
                                      ;; (:import (package Class1 Class2))
                                      (map (fn [c] `(def ~c '~c)) (rest spec))
                                      ;; (:import full.Class) — extract short name
                                      (let [s (str spec)
                                            idx (clojure.string/last-index-of s ".")]
                                        (if idx
                                          (let [short (symbol (subs s (inc idx)))]
                                            (list `(def ~short '~short)))
                                          (list `(def ~spec '~spec))))))
                                  args)

                          :else nil)))
        ref-forms (apply concat (map process-ref references))
        doc-form (when doc `(set-ns-doc '~name ~doc))]
    `(do (in-ns '~name) ~@(when doc-form (list doc-form)) ~@ref-forms)))

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
  (when-not (vector? bindings)
    (throw (str "dotimes requires a vector for its binding")))
  (when-not (= 2 (count bindings))
    (throw (str "dotimes requires exactly 2 forms in binding vector")))
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

(defn partition-by
  ([f]
   (fn [rf]
     (let [a (volatile! [])
           pv (volatile! ::none)]
       (fn
         ([] (rf))
         ([result]
          (let [result (if (zero? (count @a))
                         result
                         (let [v @a]
                           (vreset! a [])
                           (unreduced (rf result v))))]
            (rf result)))
         ([result input]
          (let [pval @pv
                val (f input)]
            (vreset! pv val)
            (if (or (identical? pval ::none)
                    (= val pval))
              (do (vswap! a conj input)
                  result)
              (let [v @a]
                (vreset! a [])
                (let [ret (rf result v)]
                  (when-not (reduced? ret)
                    (vswap! a conj input))
                  ret)))))))))
  ([f coll]
   (loop [s (seq coll) acc (list) cur (list) prev nil started false]
     (if s
       (let [v (first s)
             fv (f v)]
         (if (if started (= fv prev) true)
           (recur (next s) acc (cons v cur) fv true)
           (recur (next s) (cons (reverse cur) acc) (list v) fv true)))
       (if (seq cur)
         (reverse (cons (reverse cur) acc))
         (reverse acc))))))

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

(defn interpose
  ([sep]
   (fn [rf]
     (let [started (volatile! false)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (if @started
            (let [sepr (rf result sep)]
              (if (reduced? sepr)
                sepr
                (rf sepr input)))
            (do
              (vreset! started true)
              (rf result input))))))))
  ([sep coll]
   (drop 1 (interleave (repeat sep) coll))))

(defn distinct
  ([]
   (fn [rf]
     (let [seen (volatile! #{})]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (if (contains? @seen input)
            result
            (do (vswap! seen conj input)
                (rf result input))))))))
  ([coll]
   (loop [s (seq coll) seen #{} acc (list)]
     (if s
       (let [x (first s)]
         (if (contains? seen x)
           (recur (next s) seen acc)
           (recur (next s) (conj seen x) (cons x acc))))
       (reverse acc)))))

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
  ([] (lazy-seq nil))
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
  (__zig-lazy-iterate f x))

;; Lazy range — uses Zig meta-annotated lazy-seq for fused reduce optimization.
;; Falls back to iterate for 0-arity (infinite range).
;; Non-integer args fall back to lazy-seq (rare case).
(defn range
  ([] (iterate inc 0))
  ([end] (range 0 end 1))
  ([start end] (range start end 1))
  ([start end step]
   (if (and (integer? start) (integer? end) (integer? step))
     (__zig-lazy-range start end step)
     (lazy-seq
      (cond
        (and (pos? step) (< start end))
        (cons start (range (+ start step) end step))
        (and (neg? step) (> start end))
        (cons start (range (+ start step) end step)))))))

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

(defn remove
  ([pred] (filter (complement pred)))
  ([pred coll]
   (filter (complement pred) coll)))

(defn map-indexed
  ([f]
   (fn [rf]
     (let [i (volatile! -1)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (rf result (f (vswap! i inc) input)))))))
  ([f coll]
   (loop [s (seq coll) i 0 acc (list)]
     (if s
       (recur (next s) (+ i 1) (cons (f i (first s)) acc))
       (reverse acc)))))

(defn keep
  ([f]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (let [v (f input)]
          (if (nil? v)
            result
            (rf result v)))))))
  ([f coll]
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
            (cons x (keep f (rest s))))))))))

(defn keep-indexed
  ([f]
   (fn [rf]
     (let [iv (volatile! -1)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [i (vswap! iv inc)
                v (f i input)]
            (if (nil? v)
              result
              (rf result v))))))))
  ([f coll]
   (loop [s (seq coll) i 0 acc (list)]
     (if s
       (let [v (f i (first s))]
         (if (nil? v)
           (recur (next s) (+ i 1) acc)
           (recur (next s) (+ i 1) (cons v acc))))
       (reverse acc)))))

;; Vector-returning variants

(defn mapv [f coll]
  (vec (map f coll)))

(defn filterv [pred coll]
  (vec (filter pred coll)))

(defn partition-all
  ([n]
   (fn [rf]
     (let [a (volatile! [])]
       (fn
         ([] (rf))
         ([result]
          (let [result (if (zero? (count @a))
                         result
                         (let [v @a]
                           (vreset! a [])
                           (unreduced (rf result v))))]
            (rf result)))
         ([result input]
          (vswap! a conj input)
          (if (= n (count @a))
            (let [v @a]
              (vreset! a [])
              (rf result v))
            result))))))
  ([n coll]
   (loop [s (seq coll) acc (list)]
     (let [chunk (take n s)]
       (if (seq chunk)
         (recur (drop n s) (cons chunk acc))
         (reverse acc))))))

(defn take-while
  ([pred]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (if (pred input)
          (rf result input)
          (reduced result))))))
  ([pred coll]
   (lazy-seq
    (let [s (seq coll)]
      (when s
        (when (pred (first s))
          (cons (first s) (take-while pred (rest s)))))))))

(defn drop-while
  ([pred]
   (fn [rf]
     (let [dv (volatile! true)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [drop? @dv]
            (if (and drop? (pred input))
              result
              (do
                (vreset! dv nil)
                (rf result input)))))))))
  ([pred coll]
   (loop [s (seq coll)]
     (if s
       (if (pred (first s))
         (recur (next s))
         s)
       (list)))))

(defn reduce-kv [f init m]
  (if (nil? m)
    init
    (if (vector? m)
      (let [cnt (count m)]
        (loop [i 0 acc init]
          (if (< i cnt)
            (let [ret (f acc i (nth m i))]
              (if (reduced? ret)
                @ret
                (recur (inc i) ret)))
            acc)))
      (if (map? m)
        (let [ks (keys m)]
          (loop [s (seq ks) acc init]
            (if s
              (let [k (first s)
                    ret (f acc k (get m k))]
                (if (reduced? ret)
                  @ret
                  (recur (next s) ret)))
              acc)))
        ;; UPSTREAM-DIFF: fallback for seqs of map entries (JVM uses seqkvreduce)
        (loop [s (seq m) acc init]
          (if s
            (let [entry (first s)
                  ret (f acc (key entry) (val entry))]
              (if (reduced? ret)
                @ret
                (recur (next s) ret)))
            acc))))))

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

;;; case — constant-time dispatch via case* special form

(defn- shift-mask [shift mask x]
  (-> x (bit-shift-right shift) (bit-and mask)))

(def ^:private max-mask-bits 13)
(def ^:private max-switch-table-size (bit-shift-left 1 max-mask-bits))

(defn- maybe-min-hash
  [hashes]
  (first
   (filter (fn [[s m]]
             (apply distinct? (map #(shift-mask s m %) hashes)))
           (for [mask (map #(dec (bit-shift-left 1 %)) (range 1 (inc max-mask-bits)))
                 shift (range 0 31)]
             [shift mask]))))

(defn- case-map
  [case-f test-f tests thens]
  (into (sorted-map)
        (zipmap (map case-f tests)
                (map vector
                     (map test-f tests)
                     thens))))

(defn- fits-table?
  [ints]
  (< (- (apply max (seq ints)) (apply min (seq ints))) max-switch-table-size))

(defn- prep-ints
  [tests thens]
  (if (fits-table? tests)
    [0 0 (case-map int int tests thens) :compact]
    (let [[shift mask] (or (maybe-min-hash (map int tests)) [0 0])]
      (if (zero? mask)
        [0 0 (case-map int int tests thens) :sparse]
        [shift mask (case-map #(shift-mask shift mask (int %)) int tests thens) :compact]))))

(defn- merge-hash-collisions
  [expr-sym default tests thens]
  (let [buckets (loop [m {} ks tests vs thens]
                  (if (and ks vs)
                    (recur
                     (update m (hash (first ks)) (fnil conj []) [(first ks) (first vs)])
                     (next ks) (next vs))
                    m))
        assoc-multi (fn [m h bucket]
                      (let [testexprs (mapcat (fn [kv] [(list 'quote (first kv)) (second kv)]) bucket)
                            expr `(condp = ~expr-sym ~@testexprs ~default)]
                        (assoc m h expr)))
        hmap (reduce
              (fn [m [h bucket]]
                (if (== 1 (count bucket))
                  (assoc m (ffirst bucket) (second (first bucket)))
                  (assoc-multi m h bucket)))
              {} buckets)
        skip-check (->> buckets
                        (filter #(< 1 (count (second %))))
                        (map first)
                        (into #{}))]
    [(keys hmap) (vals hmap) skip-check]))

(defn- prep-hashes
  [expr-sym default tests thens]
  (let [hashes (into #{} (map hash tests))]
    (if (== (count tests) (count hashes))
      (if (fits-table? hashes)
        [0 0 (case-map hash identity tests thens) :compact]
        (let [[shift mask] (or (maybe-min-hash hashes) [0 0])]
          (if (zero? mask)
            [0 0 (case-map hash identity tests thens) :sparse]
            [shift mask (case-map #(shift-mask shift mask (hash %)) identity tests thens) :compact])))
      (let [[tests thens skip-check] (merge-hash-collisions expr-sym default tests thens)
            [shift mask case-map switch-type] (prep-hashes expr-sym default tests thens)
            skip-check (if (zero? mask)
                         skip-check
                         (into #{} (map #(shift-mask shift mask %) skip-check)))]
        [shift mask case-map switch-type skip-check]))))

(defmacro case
  [e & clauses]
  (let [ge (gensym "case__")
        default (if (odd? (count clauses))
                  (last clauses)
                  `(throw (ex-info (str "No matching clause: " ~ge) {})))]
    (if (> 2 (count clauses))
      `(let [~ge ~e] ~default)
      (let [pairs (partition 2 clauses)
            assoc-test (fn assoc-test [m test expr]
                         (if (contains? m test)
                           (throw (ex-info (str "Duplicate case test constant: " test) {}))
                           (assoc m test expr)))
            pairs (reduce
                   (fn [m [test expr]]
                     (if (seq? test)
                       (reduce #(assoc-test %1 %2 expr) m test)
                       (assoc-test m test expr)))
                   {} pairs)
            tests (keys pairs)
            thens (vals pairs)
            mode (cond
                   (every? #(and (integer? %) (<= -2147483648 % 2147483647)) tests)
                   :ints
                   (every? keyword? tests)
                   :identity
                   :else :hashes)]
        (cond ;; CLJW: use cond instead of condp (condp defined after case)
          (= mode :ints)
          (let [[shift mask imap switch-type] (prep-ints tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :int)))
          (= mode :hashes)
          (let [[shift mask imap switch-type skip-check] (prep-hashes ge default tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :hash-equiv ~skip-check)))
          (= mode :identity)
          (let [[shift mask imap switch-type skip-check] (prep-hashes ge default tests thens)]
            `(let [~ge ~e] (case* ~ge ~shift ~mask ~default ~imap ~switch-type :hash-identity ~skip-check))))))))

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

(defmacro letfn
  "fnspec ==> (fname [params*] exprs) or (fname ([params*] exprs)+)

  Takes a vector of function specs and a body, and generates a set of
  bindings of functions to their names. All of the names are available
  in all of the definitions of the functions, as well as the body."
  {:added "1.0"}
  [fnspecs & body]
  `(letfn* ~(vec (interleave (map first fnspecs)
                             (map #(cons 'fn %) fnspecs)))
           ~@body))

;; Imperative iteration

(defmacro while [test & body]
  `(loop []
     (when ~test
       ~@body
       (recur))))

(defmacro doseq
  "Repeatedly executes body (presumably for side-effects) with
  bindings and filtering as provided by \"for\".  Does not retain
  the head of the sequence. Returns nil."
  [seq-exprs & body]
  (when-not (vector? seq-exprs)
    (throw (str "doseq requires a vector for its binding")))
  (when-not (even? (count seq-exprs))
    (throw (str "doseq requires an even number of forms in binding vector")))
  (let [step (fn step [recform exprs]
               (if-not exprs
                 [true `(do ~@body)]
                 (let [k (first exprs)
                       v (second exprs)]
                   (if (keyword? k)
                     (let [steppair (step recform (next (next exprs)))
                           needrec (steppair 0)
                           subform (steppair 1)]
                       (cond
                         (= k :let) [needrec `(let ~v ~subform)]
                         (= k :while) [false `(when ~v
                                                ~subform
                                                ~@(when needrec [recform]))]
                         (= k :when) [false `(if ~v
                                               (do
                                                 ~subform
                                                 ~@(when needrec [recform]))
                                               ~recform)]))
                     (let [seq- (gensym "seq_")
                           chunk- (gensym "chunk_")
                           count- (gensym "count_")
                           i- (gensym "i_")
                           recform `(recur (next ~seq-) nil 0 0)
                           steppair (step recform (next (next exprs)))
                           needrec (steppair 0)
                           subform (steppair 1)
                           recform-chunk
                           `(recur ~seq- ~chunk- ~count- (unchecked-inc ~i-))
                           steppair-chunk (step recform-chunk (next (next exprs)))
                           subform-chunk (steppair-chunk 1)]
                       [true
                        `(loop [~seq- (seq ~v), ~chunk- nil,
                                ~count- 0, ~i- 0]
                           (if (< ~i- ~count-)
                             (let [~k (nth ~chunk- ~i-)]
                               ~subform-chunk
                               ~@(when needrec [recform-chunk]))
                             (when-let [~seq- (seq ~seq-)]
                               (if (chunked-seq? ~seq-)
                                 (let [c# (chunk-first ~seq-)]
                                   (recur (chunk-rest ~seq-) c#
                                          (count c#) 0))
                                 (let [~k (first ~seq-)]
                                   ~subform
                                   ~@(when needrec [recform]))))))])))))]
    (nth (step nil (seq seq-exprs)) 1)))

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
    (future? x) (future-done? x)
    (= (type x) :promise) (__promise-realized? x)
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

;; instance? is a compiler special form → __instance? builtin

;; UPSTREAM-DIFF: java.lang classes are auto-imported in JVM; CW defines as symbols
(def String 'String)
(def Character 'Character)
(def Number 'Number)
(def Integer 'Integer)
(def Long 'Long)
(def Double 'Double)
(def Float 'Float)
(def Boolean 'Boolean)
(def Object 'Object)
(def Throwable 'Throwable)
(def Exception 'Exception)
(def RuntimeException 'RuntimeException)
(def Comparable 'Comparable)
;; Supports both Java class names and CW keyword types

;; Simple stub; redefined with hierarchy support after global-hierarchy
(defn isa? [child parent]
  (= child parent))

;; Exception helpers

(defn ex-info
  ([msg data] {:__ex_info true :message msg :data (or data {}) :cause nil})
  ([msg data cause] {:__ex_info true :message msg :data (or data {}) :cause cause}))

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

;; vswap! macro moved to before take — see line ~124

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

(defn drop-last
  ([coll] (drop-last 1 coll))
  ([n coll] (map (fn [x _] x) coll (drop n coll))))

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

;; UPSTREAM-DIFF: explicit type check (upstream uses ^String type hint)
(defn parse-boolean [s]
  (when-not (string? s)
    (throw (ex-info (str "parse-boolean expects a string argument, got: " (type s)) {})))
  (get {"true" true "false" false} s))

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

(defn distinct?
  ([x] true)
  ([x y] (not (= x y)))
  ([x y & more]
   (if (not= x y)
     (loop [s #{x y} [x & etc :as xs] more]
       (if xs
         (if (contains? s x)
           false
           (recur (conj s x) etc))
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
  "Returns a lazy seq of every nth item in coll.  Returns a stateful
  transducer when no collection is provided."
  ([n]
   (fn [rf]
     (let [iv (volatile! -1)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (let [i (vswap! iv inc)]
            (if (zero? (rem i n))
              (rf result input)
              result)))))))
  ([n coll]
   (lazy-seq
    (when-let [s (seq coll)]
      (cons (first s) (take-nth n (drop n s)))))))

(defn replace
  "Given a map of replacement pairs and a vector/collection, returns a
  vector/seq with any elements = a key in smap replaced with the
  corresponding val in smap.  Returns a transducer when no collection
  is provided."
  ([smap]
   (map (fn [x] (if-let [e (find smap x)] (val e) x))))
  ([smap coll]
   (if (vector? coll)
     (reduce (fn [v i]
               (if-let [e (find smap (nth v i))]
                 (assoc v i (val e))
                 v))
             coll (range (count coll)))
     (map (fn [x] (if-let [e (find smap x)] (val e) x)) coll))))

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

;; Auto-promoting arithmetic — +', -', *' are builtins (overflow → BigInt)
(defn inc' [x] (+' x 1))
(defn dec' [x] (-' x 1))

;; === IO macros ===

(defmacro with-out-str
  "Evaluates exprs in a context in which *out* is bound to a fresh
  buffer. Returns the string created by any nested printing calls."
  [& body]
  `(let [_# (push-output-capture)
         _# (try (do ~@body) (catch Exception e# (pop-output-capture) (throw e#)))]
     (pop-output-capture)))

;; CLJW: uses push/pop-input-source builtins (upstream uses Java StringReader)
(defmacro with-in-str
  "Evaluates body in a context in which *in* is bound to a fresh
  StringReader initialized with the string s."
  {:added "1.0"}
  [s & body]
  `(let [_# (push-input-source ~s)
         result# (try (do ~@body) (catch Exception e# (pop-input-source) (throw e#)))
         _# (pop-input-source)]
     result#))

;; CLJW: *math-context* stub — no BigDecimal, but macro signature compatibility
(def ^:dynamic *math-context* nil)

(defmacro with-precision
  "Sets the precision and rounding mode to be used for BigDecimal operations.
  Note: ClojureWasm does not currently support BigDecimal. This macro binds
  *math-context* for compatibility but has no effect on arithmetic."
  {:added "1.0"}
  [precision & exprs]
  (let [body (if (= (first exprs) :rounding) (nnext exprs) exprs)]
    `(binding [*math-context* ~precision]
       ~@body)))

;; CLJW: .close Java interop replaced with (close x) function call.
;; No-op for now; will dispatch on type when file IO types are added.
(defn close
  "Closes a resource. No-op for types without close semantics."
  {:added "1.0"}
  [x] nil)

(defmacro with-open
  "bindings => [name init ...]

  Evaluates body in a try expression with names bound to the values
  of the inits, and a finally clause that calls (close name) on each
  name in reverse order."
  {:added "1.0"}
  [bindings & body]
  (assert-args
   (vector? bindings) "a vector for its binding"
   (even? (count bindings)) "an even number of forms in binding vector")
  (cond
    (= (count bindings) 0) `(do ~@body)
    (symbol? (bindings 0)) `(let ~(subvec bindings 0 2)
                              (try
                                (with-open ~(subvec bindings 2) ~@body)
                                (finally
                                  (close ~(bindings 0)))))
    :else (throw (str "with-open only allows Symbols in bindings"))))

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

;; Override builtin into to support 3-arity (transducer) and transient optimization (F101)
(defn into
  "Returns a new coll consisting of to with all of the items of
  from conjoined. A transducer may be supplied."
  ([] [])
  ([to] to)
  ([to from]
   (if (and (or (vector? to) (map? to) (set? to)) (not (sorted? to)))
     (with-meta (persistent! (reduce conj! (transient to) from)) (meta to))
     (if (or (map? to) (set? to))
       (with-meta (reduce conj to from) (meta to))
       (reduce conj to from))))
  ([to xform from]
   (if (and (or (vector? to) (map? to) (set? to)) (not (sorted? to)))
     (let [tm (meta to)
           rf (fn
                ([coll] (-> (persistent! coll) (with-meta tm)))
                ([coll v] (conj! coll v)))]
       (transduce xform rf (transient to) from))
     (if (or (map? to) (set? to))
       (with-meta (transduce xform conj to from) (meta to))
       (transduce xform conj to from)))))

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

;; UPSTREAM-DIFF: eduction returns eager sequence (upstream uses deftype Eduction + IReduceInit)
(defn eduction
  "Returns a reducible/iterable application of the transducers
  to the items in coll. Transducers are applied in order as if
  combined with comp."
  [& xforms]
  (sequence (apply comp (butlast xforms)) (last xforms)))

;; UPSTREAM-DIFF: iteration returns lazy-seq (upstream uses reify Seqable + IReduceInit)
(defn iteration
  "Creates a seqable/reducible via repeated calls to step,
  a function of some (continuation token) 'k'. The first call to step
  will be passed initk, returning 'ret'. Iff (somef ret) is true,
  (vf ret) will be included in the iteration, else iteration will
  terminate and vf/kf will not be called. If (kf ret) is non-nil it
  will be passed to the next step call, else iteration will terminate."
  [step & {:keys [somef vf kf initk]
           :or {vf identity
                kf identity
                somef some?
                initk nil}}]
  ((fn next [ret]
     (when (somef ret)
       (cons (vf ret)
             (when-some [k (kf ret)]
               (lazy-seq (next (step k)))))))
   (step initk)))

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

;; Redefine map with multi-collection arities (needs and, every?, identity)
(defn map
  "Returns a lazy sequence consisting of the result of applying f to
  the set of first items of each coll, followed by applying f to the
  set of second items in each coll, until any one of the colls is
  exhausted. Returns a transducer when no collection is provided."
  ([f]
   (fn [rf]
     (fn
       ([] (rf))
       ([result] (rf result))
       ([result input]
        (rf result (f input))))))
  ([f coll]
   ;; CLJW: use __zig-lazy-map for fused reduce optimization (meta-annotated lazy-seq)
   (__zig-lazy-map f coll))
  ([f c1 c2]
   (lazy-seq
    (let [s1 (seq c1) s2 (seq c2)]
      (when (and s1 s2)
        (cons (f (first s1) (first s2))
              (map f (rest s1) (rest s2)))))))
  ([f c1 c2 c3]
   (lazy-seq
    (let [s1 (seq c1) s2 (seq c2) s3 (seq c3)]
      (when (and s1 s2 s3)
        (cons (f (first s1) (first s2) (first s3))
              (map f (rest s1) (rest s2) (rest s3)))))))
  ([f c1 c2 c3 & colls]
   (let [step (fn step [cs]
                (lazy-seq
                 (let [ss (map seq cs)]
                   (when (every? identity ss)
                     (cons (map first ss) (step (map rest ss)))))))]
     (map #(apply f %) (step (conj colls c3 c2 c1))))))

(defn mapv
  "Returns a vector consisting of the result of applying f to the
  set of first items of each coll, followed by applying f to the set
  of second items in each coll, until any one of the colls is
  exhausted."
  ([f coll]
   (-> (reduce (fn [v o] (conj! v (f o))) (transient []) coll)
       persistent!))
  ([f c1 c2]
   (into [] (map f c1 c2)))
  ([f c1 c2 c3]
   (into [] (map f c1 c2 c3)))
  ([f c1 c2 c3 & colls]
   (into [] (apply map f c1 c2 c3 colls))))

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

(defn bound-fn*
  "Returns a function, which will install the same bindings in effect as in
  the thread at the time bound-fn* was called and then call f with any given
  arguments."
  {:added "1.1"}
  [f]
  (let [bindings (get-thread-bindings)]
    (fn [& args]
      (apply with-bindings* bindings f args))))

(defmacro bound-fn
  "Returns a function defined by the given fntail, which will install the
  same bindings in effect as in the thread at the time bound-fn was called."
  {:added "1.1"}
  [& fntail]
  `(bound-fn* (fn ~@fntail)))

;; CLJW: Var.create/setDynamic -> create-local-var builtin
(defmacro with-local-vars
  "varbinding=> symbol init-expr

  Executes the exprs in a context in which the symbols are bound to
  vars with per-thread bindings to the init-exprs. The symbols refer
  to the var objects themselves, and must be accessed with var-get and
  var-set."
  {:added "1.0"}
  [name-vals-vec & body]
  (assert-args
   (vector? name-vals-vec) "a vector for its binding"
   (even? (count name-vals-vec)) "an even number of forms in binding vector")
  `(let [~@(interleave (take-nth 2 name-vals-vec)
                       (repeat '(create-local-var)))]
     (push-thread-bindings (hash-map ~@name-vals-vec))
     (try
       ~@body
       (finally (pop-thread-bindings)))))

;; CLJW: .bindRoot -> __var-bind-root builtin (no Java interop)
(defn with-redefs-fn
  "Temporarily redefines vars during the execution of func."
  [binding-map func]
  (let [root-bind (fn [m]
                    (doseq [[a-var a-val] m]
                      (__var-bind-root a-var a-val)))
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
(def ^:dynamic *agent* nil)
(def ^:dynamic *allow-unresolved-vars* false)
(def ^:dynamic *reader-resolver* nil)
(def ^:dynamic *suppress-read* false)
(def ^:dynamic *compile-path* nil)
(def ^:dynamic *fn-loader* nil)
(def ^:dynamic *use-context-classloader* true)

;; UPSTREAM-DIFF: always returns false (no Java class system)
(defn class?
  "Returns true if x is an instance of Class"
  {:added "1.0"}
  [x] false)

;; UPSTREAM-DIFF: simplified — creates function without :inline metadata support
(defmacro definline
  "Experimental - like defmacro, except defines a named function whose
  body is the expansion, calls to which may be expanded inline as if
  it were a macro. Cannot be used with variadic (&) args."
  {:added "1.0"}
  [name & decl]
  (let [[pre-args [args expr]] (split-with (comp not vector?) decl)]
    `(defn ~name ~@pre-args ~args ~expr)))

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

;; CLJW: no STM, so io! is just an implicit do (upstream checks LockingTransaction/isRunning)
(defmacro io!
  "If an io! block occurs in a transaction, throws an
  IllegalStateException, else runs body in an implicit do. If the
  first expression in body is a literal string, will use that as the
  exception message."
  [& body]
  (let [body (if (string? (first body)) (next body) body)]
    `(do ~@body)))

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
;; Uses :__promise tag so deref returns :val instead of the whole map.
;; swap! receives the raw atom value (the map), bypassing promise-aware deref.
;; promise and deliver are now builtins (native PromiseObj with mutex/condvar)

;; Protocol helpers
;; UPSTREAM-DIFF: extend-type is a special form, not a macro
(defn- parse-impls [specs]
  (loop [ret {} s specs]
    (if (seq s)
      (recur (assoc ret (first s) (take-while seq? (next s)))
             (drop-while seq? (next s)))
      ret)))

(defmacro extend-protocol
  [p & specs]
  (let [impls (parse-impls specs)]
    `(do ~@(map (fn [entry] `(extend-type ~(key entry) ~p ~@(val entry))) impls))))

;; Data reader constants
;; CLJW: def doesn't support docstring form (def name "doc" val)
(def default-data-readers
  {'inst identity   ; CLJW: returns string (no Date type)
   'uuid identity}) ; CLJW: returns string (no UUID type)

(defn tagged-literal
  "Constructs a data representation of a tagged literal from a
  tag symbol and a form."
  {:added "1.7"}
  [tag form]
  {:tag tag :form form})

(defn tagged-literal?
  "Return true if the value is the data representation
  of a tagged literal"
  {:added "1.7"}
  [value]
  (and (map? value) (contains? value :tag) (contains? value :form)
       (symbol? (:tag value))))

(defn reader-conditional
  "Constructs a data representation of a reader conditional."
  {:added "1.7"}
  [form splicing?]
  {:form form :splicing? splicing?})

(defn reader-conditional?
  "Return true if the value is the data representation of a reader conditional"
  {:added "1.7"}
  [value]
  (and (map? value) (contains? value :form) (contains? value :splicing?)))

;; UPSTREAM-DIFF: reduce1→reduce, Java interop→CW equivalents, type hints removed
(defn destructure [bindings]
  (let [bents (partition 2 bindings)
        pb (fn pb [bvec b v]
             (let [pvec
                   (fn [bvec b val]
                     (let [gvec (gensym "vec__")
                           gseq (gensym "seq__")
                           gfirst (gensym "first__")
                           has-rest (some #{'&} b)]
                       (loop [ret (let [ret (conj bvec gvec val)]
                                    (if has-rest
                                      (conj ret gseq (list `seq gvec))
                                      ret))
                              n 0
                              bs b
                              seen-rest? false]
                         (if (seq bs)
                           (let [firstb (first bs)]
                             (cond
                               (= firstb '&) (recur (pb ret (second bs) gseq)
                                                    n
                                                    (nnext bs)
                                                    true)
                               (= firstb :as) (pb ret (second bs) gvec)
                               :else (if seen-rest?
                                       (throw (ex-info "Unsupported binding form, only :as can follow & parameter" {}))
                                       (recur (pb (if has-rest
                                                    (conj ret
                                                          gfirst `(first ~gseq)
                                                          gseq `(next ~gseq))
                                                    ret)
                                                  firstb
                                                  (if has-rest
                                                    gfirst
                                                    (list `nth gvec n nil)))
                                              (inc n)
                                              (next bs)
                                              seen-rest?))))
                           ret))))
                   pmap
                   (fn [bvec b v]
                     (let [gmap (gensym "map__")
                           defaults (:or b)]
                       (loop [ret (-> bvec (conj gmap) (conj v)
                                      (conj gmap) (conj `(if (seq? ~gmap)
                                                           (seq-to-map-for-destructuring ~gmap)
                                                           ~gmap))
                                      ((fn [ret]
                                         (if (:as b)
                                           (conj ret (:as b) gmap)
                                           ret))))
                              bes (let [transforms
                                        (reduce
                                         (fn [transforms mk]
                                           (if (keyword? mk)
                                             (let [mkns (namespace mk)
                                                   mkn (name mk)]
                                               (cond (= mkn "keys") (assoc transforms mk #(keyword (or mkns (namespace %)) (name %)))
                                                     (= mkn "syms") (assoc transforms mk #(list `quote (symbol (or mkns (namespace %)) (name %))))
                                                     (= mkn "strs") (assoc transforms mk str)
                                                     :else transforms))
                                             transforms))
                                         {}
                                         (keys b))]
                                    (reduce
                                     (fn [bes entry]
                                       (reduce #(assoc %1 %2 ((val entry) %2))
                                               (dissoc bes (key entry))
                                               ((key entry) bes)))
                                     (dissoc b :as :or)
                                     transforms))]
                         (if (seq bes)
                           (let [bb (key (first bes))
                                 bk (val (first bes))
                                 local (if (ident? bb) (with-meta (symbol nil (name bb)) (meta bb)) bb)
                                 bv (if (contains? defaults local)
                                      (list `get gmap bk (defaults local))
                                      (list `get gmap bk))]
                             (recur (if (ident? bb)
                                      (-> ret (conj local bv))
                                      (pb ret bb bv))
                                    (next bes)))
                           ret))))]
               (cond
                 (symbol? b) (-> bvec (conj b) (conj v))
                 (vector? b) (pvec bvec b v)
                 (map? b) (pmap bvec b v)
                 :else (throw (ex-info (str "Unsupported binding form: " b) {})))))
        process-entry (fn [bvec b] (pb bvec (first b) (second b)))]
    (if (every? symbol? (map first bents))
      bindings
      (reduce process-entry [] bents))))

;; Array macros
(defmacro amap
  "Maps an expression across an array a, using an index named idx, and
  return value named ret, initialized to a clone of a, then setting
  each element of ret to the evaluation of expr, returning the new
  array ret."
  [a idx ret expr]
  `(let [a# ~a l# (alength a#)
         ~ret (aclone a#)]
     (loop [~idx 0]
       (if (< ~idx l#)
         (do
           (aset ~ret ~idx ~expr)
           (recur (inc ~idx)))
         ~ret))))

(defmacro areduce
  "Reduces an expression across an array a, using an index named idx,
  and return value named ret, initialized to init, setting ret to the
  evaluation of expr at each step, returning ret."
  [a idx ret init expr]
  `(let [a# ~a l# (alength a#)]
     (loop [~idx 0 ~ret ~init]
       (if (< ~idx l#)
         (recur (inc ~idx) ~expr)
         ~ret))))

;; future macro
(defmacro future
  [& body] `(future-call (fn [] ~@body)))

;; pmap — parallel map using futures
(defn pmap
  ([f coll]
   (let [n (+ 2 (__available-processors))
         rets (map (fn [x] (future (f x))) coll)
         step (fn step [[x & xs :as vs] fs]
                (lazy-seq
                 (if-let [s (seq fs)]
                   (cons (deref x) (step xs (rest s)))
                   (map deref vs))))]
     (step rets (drop n rets))))
  ([f coll & colls]
   (let [step (fn step [cs]
                (lazy-seq
                 (let [ss (map seq cs)]
                   (when (every? identity ss)
                     (cons (map first ss) (step (map rest ss)))))))]
     (pmap (fn [args] (apply f args)) (step (cons coll colls))))))

;; pcalls — parallel function calls
(defn pcalls
  [& fns] (pmap (fn [f] (f)) fns))

;; pvalues — parallel value computation
(defmacro pvalues
  [& exprs]
  `(pcalls ~@(map (fn [e] (list 'fn [] e)) exprs)))

;; REPL result vars
(def *1 nil)
(def *2 nil)
(def *3 nil)
