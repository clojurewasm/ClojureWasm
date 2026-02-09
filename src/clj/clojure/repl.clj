;; Upstream: clojure/src/clj/clojure/repl.clj
;; Upstream lines: 270
;; CLJW markers: 6
;; CLJW: Extracted from core.clj (Phase 33.2, D82).
;; UPSTREAM-DIFF: No spec support, no Java interop (LineNumberReader, Reflector).

(ns clojure.repl
  (:require [clojure.string]))

(def ^:private special-doc-map
  '{def {:forms [(def symbol doc-string? init?)]
         :doc "Creates and interns a global var with the name
  of symbol in the current namespace (*ns*) or locates such a var if
  it already exists.  If init is supplied, it is evaluated, and the
  root binding of the var is set to the resulting value.  If init is
  not supplied, the root binding of the var is unaffected."}
    do {:forms [(do exprs*)]
        :doc "Evaluates the expressions in order and returns the value of
  the last. If no expressions are supplied, returns nil."}
    if {:forms [(if test then else?)]
        :doc "Evaluates test. If not the singular values nil or false,
  evaluates and yields then, otherwise, evaluates and yields else. If
  else is not supplied it defaults to nil."}
    quote {:forms [(quote form)]
           :doc "Yields the unevaluated form."}
    recur {:forms [(recur exprs*)]
           :doc "Evaluates the exprs in order, then, in parallel, rebinds
  the bindings of the recursion point to the values of the exprs.
  Execution then jumps back to the recursion point, a loop or fn method."}
    set! {:forms [(set! var-symbol expr)]
          :doc "Sets the thread-local binding of a dynamic var."}
    throw {:forms [(throw expr)]
           :doc "The expr is evaluated and thrown."}
    try {:forms [(try expr* catch-clause* finally-clause?)]
         :doc "catch-clause => (catch classname name expr*)
  finally-clause => (finally expr*)
  Catches and handles exceptions."}
    var {:forms [(var symbol)]
         :doc "The symbol must resolve to a var, and the Var object
  itself (not its value) is returned. The reader macro #'x expands to (var x)."}
    fn {:forms [(fn name? [params*] exprs*) (fn name? ([params*] exprs*) +)]
        :doc "params => positional-params*, or positional-params* & rest-param
  Defines a function (fn)."}
    let {:forms [(let [bindings*] exprs*)]
         :doc "binding => binding-form init-expr
  Evaluates the exprs in a lexical context in which the symbols in
  the binding-forms are bound to their respective init-exprs or parts
  therein."}
    loop {:forms [(loop [bindings*] exprs*)]
          :doc "Evaluates the exprs in a lexical context in which the symbols in
  the binding-forms are bound to their respective init-exprs or parts
  therein. Acts as a recur target."}
    letfn {:forms [(letfn [fnspecs*] exprs*)]
           :doc "fnspec ==> (fname [params*] exprs) or (fname ([params*] exprs)+)
  Takes a vector of function specs and a body, and generates a set of
  bindings of each name to its fn. All of the fns are available in all
  of the definitions of the fns, as well as the body."}})

(defn- special-doc [name-symbol]
  (assoc (or (special-doc-map name-symbol) (meta (resolve name-symbol)))
         :name name-symbol
         :special-form true))

(defn- namespace-doc [nspace]
  (assoc (meta nspace) :name (ns-name nspace)))

;; CLJW: Simplified print-doc — no spec support
(defn- print-doc [{n :ns nm :name
                   :keys [forms arglists special-form doc macro]}]
  (println "-------------------------")
  (println (str (when n (str (ns-name n) "/")) nm))
  (when forms
    (doseq [f forms]
      (print "  ")
      (prn f)))
  (when arglists
    (println arglists))
  (cond
    special-form (println "Special Form")
    macro        (println "Macro"))
  (when doc (println " " doc)))

;; CLJW: Always emit runtime code to handle recently-defined vars.
;; JVM doc uses compile-time resolve, but our macro_eval_env may lag.
(defmacro doc
  "Prints documentation for a var or special form given its name,
  as found by (resolve). Prints its name, arglists and added information."
  {:added "1.0"}
  [name]
  (if-let [special-name ('{& fn catch try finally try} name)]
    `(print-doc (special-doc '~special-name))
    (if (special-doc-map name)
      `(print-doc (special-doc '~name))
      `(if-let [ns# (find-ns '~name)]
         (print-doc (namespace-doc ns#))
         (when-let [v# (ns-resolve *ns* '~name)]
           (print-doc (meta v#)))))))

(defn dir-fn
  "Returns a sorted seq of symbols naming public vars in
  a namespace or namespace alias. Looks for aliases in *ns*"
  {:added "1.6"}
  [ns]
  (sort (map first (ns-publics (the-ns (get (ns-aliases *ns*) ns ns))))))

(defmacro dir
  "Prints a sorted directory of public vars in a namespace"
  {:added "1.6"}
  [nsname]
  `(doseq [v# (dir-fn '~nsname)]
     (println v#)))

;; CLJW: (= :regex (type x)) instead of (instance? java.util.regex.Pattern x)
(defn apropos
  "Given a regular expression or stringable thing, return a seq of all
  public definitions in all currently-loaded namespaces that match the
  str-or-pattern."
  {:added "1.0"}
  [str-or-pattern]
  (let [matches? (if (= :regex (type str-or-pattern))
                   #(re-find str-or-pattern (str %))
                   #(clojure.string/includes? (str %) (str str-or-pattern)))]
    (sort (mapcat (fn [ns]
                    (let [ns-name (str ns)]
                      (map #(symbol ns-name (str %))
                           (filter matches? (keys (ns-publics ns))))))
                  (all-ns)))))

;; CLJW: vec around vals for sort-by compatibility
(defn find-doc
  "Prints documentation for any var whose documentation or name
  contains a match for re-string-or-pattern"
  {:added "1.0"}
  [re-string-or-pattern]
  (let [re (re-pattern re-string-or-pattern)
        ms (concat (mapcat #(sort-by :name (vec (map meta (vec (vals (ns-interns %))))))
                           (all-ns))
                   (map namespace-doc (all-ns))
                   (map special-doc (keys special-doc-map)))]
    (doseq [m ms
            :when (and (:doc m)
                       (or (re-find re (:doc m))
                           (re-find re (str (:name m)))))]
      (print-doc m))))

;; CLJW: source-fn reads file from filesystem (no classloader)
(defn source-fn
  "Returns a string of the source code for the given symbol, if it can
  find it. Returns nil if it can't find the source."
  {:added "1.0"}
  [x]
  (when-let [v (resolve x)]
    (let [filepath (:file (meta v))]
      (when (and filepath
                 (not= filepath "NO_SOURCE_FILE")
                 (pos? (or (:line (meta v)) 0)))
        (let [content (slurp filepath)
              lines (clojure.string/split content #"\n")
              start (dec (:line (meta v)))]
          (when (< start (count lines))
            ;; Read from start line, find matching parens to delimit form
            (loop [i start
                   depth 0
                   seen-open false
                   result []]
              (if (>= i (count lines))
                (clojure.string/join "\n" result)
                (let [line (nth lines i)
                      has-open (some #(= % \() line)
                      new-depth (reduce (fn [d c]
                                          (cond (= c \() (inc d)
                                                (= c \)) (dec d)
                                                :else d))
                                        depth line)
                      new-seen (or seen-open has-open)]
                  (if (and new-seen (<= new-depth 0))
                    (clojure.string/join "\n" (conj result line))
                    (recur (inc i) new-depth new-seen (conj result line))))))))))))

(defmacro source
  "Prints the source code for the given symbol, if it can find it."
  {:added "1.0"}
  [n]
  `(println (or (source-fn '~n) (str "Source not found"))))

;; CLJW: identity fn — CW doesn't munge names like JVM Clojure
(defn demunge
  "Given a string representation of a fn class,
  as in a stack trace element, returns a readable version."
  {:added "1.3"}
  [fn-name]
  (str fn-name))

;; CLJW: simplified root-cause — walks ex-cause chain
(defn root-cause
  "Returns the initial cause of an exception or error by peeling off all of
  its wrappers"
  {:added "1.3"}
  [t]
  (if-let [cause (ex-cause t)]
    (recur cause)
    t))

;; CLJW: uses Throwable->map trace format instead of StackTraceElement
(defn stack-element-str
  "Returns a string representation of a stack trace element"
  {:added "1.3"}
  [el]
  (if (map? el)
    (str (:fn el) " (" (:file el) ":" (:line el) ")")
    (str el)))

;; CLJW: pst using Zig error stack, number? check instead of (instance? Throwable)
(defn pst
  "Prints a stack trace of the most recent exception (*e)."
  {:added "1.3"}
  ([] (pst 12))
  ([e-or-depth]
   (if (number? e-or-depth)
     (when-let [e *e]
       (pst e e-or-depth))
     (pst e-or-depth 12)))
  ([e depth]
   (println (str (type e) ": " (ex-message e)))
   (when-let [data (ex-data e)]
     (when-let [trace (:trace data)]
       (let [frames (vec (take depth trace))]
         (doseq [frame frames]
           (println (str "  " (:fn frame)
                         " (" (:file frame) ":" (:line frame) ")"))))))))
