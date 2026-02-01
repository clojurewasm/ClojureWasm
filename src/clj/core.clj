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
