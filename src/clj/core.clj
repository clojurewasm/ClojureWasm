;; clojure.core bootstrap — macros defined in Clojure, loaded at startup.
;;
;; These macros are evaluated by bootstrap.evalString during Env initialization.
;; Builtins (def, defmacro, fn, if, do, let, +, -, etc.) are already registered
;; in the Env by registry.registerBuiltins before this file is loaded.

(defmacro defn [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

(defmacro when [test & body]
  `(if ~test (do ~@body)))
