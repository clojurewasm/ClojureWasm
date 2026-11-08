;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.repl API (originally Chris Houser,
;; Christophe Grand, Stephen Gilardi, Michel Salim; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.
;;
;; doc / find-doc rely on the :doc/:arglists var metadata that D-305's
;; generated core_meta.clj fills for clojure.core; defn-defined vars carry
;; their own. `source`/`source-fn` are NOT implementable: cljw does not
;; retain per-var source text (AOT bytecode bootstrap) — they throw with
;; that explanation rather than silently returning nil.

(ns clojure.repl)

(defn demunge
  "Given a string representation of a fn class,
  as in a stack trace element, returns a readable version."
  [fn-name]
  (-> fn-name
      (clojure.string/replace "_QMARK_" "?")
      (clojure.string/replace "_BANG_" "!")
      (clojure.string/replace "_STAR_" "*")
      (clojure.string/replace "_GT_" ">")
      (clojure.string/replace "_LT_" "<")
      (clojure.string/replace "_EQ_" "=")
      (clojure.string/replace "_PLUS_" "+")
      (clojure.string/replace "_SLASH_" "/")
      (clojure.string/replace "$" "/")
      (clojure.string/replace "_" "-")))

;; `stack-element-str` renders one cljw stack frame map {:ns :fn :file :line}
;; as `<ns>/<fn> (<file>:<line>)`. clj takes a JVM StackTraceElement and yields
;; `class.method (file:line)` for a Java frame or a demunged `ns/fn` for a
;; Clojure frame; cljw has no StackTraceElement and only Clojure frames
;; (ADR-0059 / ADR-0120), so it takes the cljw-native frame map and produces
;; exactly clj's Clojure-frame form. Same render string as
;; clojure.stacktrace/print-trace-element (both fixed by ADR-0140).
(defn stack-element-str
  "Returns a string representation of one cljw stack frame map
  {:ns :fn :file :line}, as `<ns>/<fn> (<file>:<line>)`."
  [{:keys [ns fn file line]}]
  (str (when ns (str ns "/")) fn " (" (or file "") ":" line ")"))

(defn dir-fn
  "Returns a sorted seq of symbols naming public vars in
  a namespace or namespace alias."
  [ns]
  (sort (keys (ns-publics (the-ns ns)))))

(defmacro dir
  "Prints a sorted directory of public vars in a namespace."
  [nsname]
  `(doseq [v# (dir-fn '~nsname)]
     (println v#)))

(defn- print-doc [m]
  (println "-------------------------")
  (println (str (when-let [ns (:ns m)] (str (ns-name ns) "/")) (:name m)))
  (when (:arglists m) (println (:arglists m)))
  (when (:macro m) (println "Macro"))
  (when (:doc m) (println " " (:doc m))))

(defn- resolve-doc-map
  "The doc map for a symbol: a var's meta, or a namespace's meta + name."
  [sym]
  (if-let [v (resolve sym)]
    (meta v)
    (when-let [ns (find-ns sym)]
      (assoc (meta ns) :name (ns-name ns)))))

(defmacro doc
  "Prints documentation for a var or namespace given its name."
  [name]
  `(when-let [m# (#'clojure.repl/resolve-doc-map '~name)]
     (#'clojure.repl/print-doc m#)))

(defn find-doc
  "Prints documentation for any var whose documentation or name
  contains a match for re-string-or-pattern."
  [re-string-or-pattern]
  (let [re (re-pattern re-string-or-pattern)
        ms (concat (mapcat (fn [ns]
                             (map #(meta %) (vals (ns-publics ns))))
                           (all-ns)))]
    (doseq [m ms
            :when (and (:doc m)
                       (or (re-find re (:doc m))
                           (re-find re (str (:name m)))))]
      (print-doc m))))

(defn apropos
  "Given a regular expression or stringable thing, return a seq of all
  public definitions in all currently-loaded namespaces that match the
  str-or-pattern."
  [str-or-pattern]
  (let [matches? (if (instance? java.util.regex.Pattern str-or-pattern)
                   #(re-find str-or-pattern (str %))
                   #(clojure.string/includes? (str %) (str str-or-pattern)))]
    (sort
     (mapcat (fn [ns]
               (let [ns-name-str (str (ns-name ns))]
                 (map #(symbol ns-name-str (str %))
                      (filter matches? (keys (ns-publics ns))))))
             (all-ns)))))

(defn source-fn
  "Not available in ClojureWasm: per-var source text is not retained
  (the runtime bootstraps from AOT bytecode, not source)."
  [x]
  (throw (ex-info "source is not available in ClojureWasm: per-var source text is not retained (AOT bytecode bootstrap)" {:sym x})))

(defmacro source
  "Not available in ClojureWasm — see source-fn."
  [n]
  `(source-fn '~n))

(defn root-cause
  "Returns the initial cause of an exception or error by peeling off all of
  its wrappers."
  [t]
  (loop [cause t]
    (if-let [c (ex-cause cause)]
      (recur c)
      cause)))
