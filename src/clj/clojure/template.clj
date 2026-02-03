;; clojure.template — macros that expand to repeated copies of a template expression
;;
;; Based on upstream clojure.template by Stuart Sierra.
;; Uses clojure.walk/postwalk-replace for symbol substitution.

(ns clojure.template)

(defn apply-template
  "For use in macros. argv is an argument list, as in defn. expr is
  a quoted expression using the symbols in argv. values is a sequence
  of values to be used for the arguments.

  apply-template will recursively replace argument symbols in expr
  with their corresponding values, returning a modified expr."
  [argv expr values]
  (postwalk-replace (zipmap argv values) expr))

(defmacro do-template
  "Repeatedly copies expr (in a do block) for each group of arguments
  in values. values are automatically partitioned by the number of
  arguments in argv, an argument vector as in defn."
  [argv expr & values]
  (let [c (count argv)
        groups (partition c values)]
    `(do ~@(map (fn [g] (apply-template argv expr g)) groups))))
