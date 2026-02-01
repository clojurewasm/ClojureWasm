;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.

(defmacro defn [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

(defmacro when [test & body]
  `(if ~test (do ~@body)))

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

;; and/or (2-arity for now; multi-arity requires recursive macros)

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
