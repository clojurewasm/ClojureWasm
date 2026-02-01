#!/usr/bin/env clj
;; Usage: clj scripts/generate_vars_yaml.clj > .dev/status/vars.yaml
;;
;; Generates a YAML file listing all public Vars from target Clojure namespaces.
;; Output uses default status: todo, impl: none for manual update.

(def target-namespaces
  '[clojure.core
    clojure.core.protocols
    clojure.core.reducers
    clojure.core.server
    clojure.core.specs.alpha
    clojure.data
    clojure.datafy
    clojure.edn
    clojure.inspector
    clojure.instant
    clojure.java.browse
    clojure.java.io
    clojure.java.javadoc
    clojure.java.shell
    clojure.main
    clojure.math
    clojure.pprint
    clojure.reflect
    clojure.repl
    clojure.set
    clojure.spec.alpha
    clojure.spec.gen.alpha
    clojure.stacktrace
    clojure.string
    clojure.template
    clojure.test
    clojure.uuid
    clojure.walk
    clojure.zip])

(defn ns->yaml-key [ns-sym]
  (-> (str ns-sym)
      (.replace "." "_")
      (.replace "-" "_")))

(defn classify-var [v]
  (let [m (meta v)]
    (cond
      (:special-form m) "special-form"
      (:macro m)        "macro"
      (and (:dynamic m)
           (not (fn? (deref v)))) "dynamic-var"
      (fn? (deref v))   "function"
      :else             "var")))

(defn yaml-escape-key [s]
  (let [needs-quote (or (.contains s ".")
                        (.contains s "/")
                        (.contains s "'")
                        (.contains s "\"")
                        (.contains s ":")
                        (.contains s "{")
                        (.contains s "}")
                        (.contains s "[")
                        (.contains s "]")
                        (.contains s ",")
                        (.contains s "#")
                        (.contains s "&")
                        (.contains s "*")
                        (.contains s "?")
                        (.contains s "|")
                        (.contains s "-")
                        (.contains s "<")
                        (.contains s ">")
                        (.contains s "=")
                        (.contains s "!")
                        (.contains s "%")
                        (.contains s "@")
                        (.contains s "`")
                        (.startsWith s "+")
                        (.startsWith s "/")
                        (= s "true")
                        (= s "false")
                        (= s "null"))]
    (if needs-quote
      (str "\"" (.replace s "\"" "\\\"") "\"")
      s)))

(defn emit-var-entry [var-name var-type]
  (let [key (yaml-escape-key (str var-name))]
    (str "    " key ": {type: " var-type ", status: todo, impl: none}")))

;; Load all namespaces
(doseq [ns-sym target-namespaces]
  (try
    (require ns-sym)
    (catch Exception e
      (binding [*out* *err*]
        (println (str "Warning: could not load " ns-sym ": " (.getMessage e)))))))

;; Also add special forms that aren't in ns-publics
(def special-form-names
  '#{if do let* fn* def quote var loop* recur throw try catch finally
     new set! . monitor-enter monitor-exit deftype* reify* case*
     import* letfn*})

;; Emit YAML
(println "# ClojureWasm Var Implementation Status")
(println "# Generated from Clojure JVM reference implementation")
(println "#")
(println "# Field definitions:")
(println "#   type: Classification in upstream Clojure")
(println "#     special-form | function | macro | dynamic-var | var")
(println "#   status: Implementation state")
(println "#     todo | wip | partial | done | skip")
(println "#   impl: Implementation method in this project")
(println "#     special_form  - Analyzer direct dispatch")
(println "#     intrinsic     - VM opcode fast path (+, -, *, / etc.)")
(println "#     host          - Zig BuiltinFn, Zig required (Value internals, IO)")
(println "#     bridge        - Zig BuiltinFn, .clj migration candidate")
(println "#     clj           - Defined in Clojure source (.clj files)")
(println "#     none          - Not yet implemented")
(println "#")
(println "# Cross-reference patterns:")
(println "#   type: function + impl: special_form  -> provisional special form")
(println "#   type: macro    + impl: special_form  -> provisional special form")
(println "#   type: function + impl: intrinsic     -> VM fast-path intrinsic")
(println "#   type: function + impl: bridge        -> .clj migration candidate")
(println "")
(println "vars:")

;; Emit clojure.core with special forms first
(println "  clojure_core:")

;; Special forms first
(doseq [sf (sort special-form-names)]
  (let [key (yaml-escape-key (str sf))]
    (println (str "    " key ": {type: special-form, status: todo, impl: none}"))))

;; Then regular vars from clojure.core
(let [ns-obj (find-ns 'clojure.core)
      publics (sort-by key (ns-publics ns-obj))]
  (doseq [[sym v] publics]
    (when-not (contains? special-form-names sym)
      (let [var-type (try (classify-var v) (catch Exception _ "var"))
            key (yaml-escape-key (str sym))]
        (println (str "    " key ": {type: " var-type ", status: todo, impl: none}"))))))

;; Other namespaces
(doseq [ns-sym (rest target-namespaces)]
  (when-let [ns-obj (find-ns ns-sym)]
    (let [yaml-key (ns->yaml-key ns-sym)
          publics (sort-by key (ns-publics ns-obj))]
      (println (str "  " yaml-key ":"))
      (doseq [[sym v] publics]
        (let [var-type (try (classify-var v) (catch Exception _ "var"))
              key (yaml-escape-key (str sym))]
          (println (str "    " key ": {type: " var-type ", status: todo, impl: none}")))))))
