;; cljw.wasm — require a Wasm component as a namespace (W1, D-404 / ADR-0135).
;; A component's exports become callable Vars in a target ns, indistinguishable
;; from normal Clojure fns. A THIN Clojure layer over the wasm/ primitives
;; (load-component / component-exports / component-call live in
;; runtime/cljw/wasm/, F-009 — this never forks them). Require-on-demand AND
;; wasm-gated: only resolvable in a `-Dwasm` build (the wasm/ ns it rides does
;; not exist otherwise).
(ns cljw.wasm)

(defn- strip-export-name
  "Clean a raw WIT export name to a Clojure symbol-name string:
   `pkg:iface/greet` -> `greet`; `…#[constructor]counter` -> `counter`;
   `…#[method]counter.get` -> `get`; a bare `greet` -> `greet`."
  [raw]
  (let [after-bracket (if-let [i (clojure.string/last-index-of raw "]")]
                        (subs raw (inc i))
                        raw)
        after-slash (if-let [i (clojure.string/last-index-of after-bracket "/")]
                      (subs after-bracket (inc i))
                      after-bracket)
        after-dot (if-let [i (clojure.string/last-index-of after-slash ".")]
                    (subs after-slash (inc i))
                    after-slash)]
    after-dot))

(defn- component-var?
  "True for a Var `require-component*` interned (and a user has not since
   re-`def`ined: `def` replaces the metadata, and with it the tag)."
  [v]
  (true? (:cljw.wasm/component-export (meta v))))

(defn- retire-var!
  "Unmap the component-interned Var `sym` from `ns-obj`, first rebinding its root
   to a fn that throws. A caller that captured the Var before the swap then gets
   a catchable error naming the export, instead of a call into the previous
   instance, and the old handle is no longer reachable through the Var."
  [ns-obj sym path]
  (when-let [v (get (ns-interns ns-obj) sym)]
    (let [msg (str "component " path " no longer exports `" sym "`")]
      (alter-var-root v (constantly (fn [& _] (throw (ex-info msg {:cljw.wasm/component-path path
                                                                   :cljw.wasm/export (name sym)})))))
      (ns-unmap ns-obj sym))))

(defn require-component*
  "Runtime worker for `require-component`. Loads `path` as a cached component
   handle, then per `opts`: `:as <sym>` interns ALL exports as Vars in the named
   namespace; `:refer [<sym> …]` interns the named exports into the CURRENT ns.
   Each Var is a fn calling its export through the shared handle. Returns the
   target Namespace (`:as`) or the current ns.

   Re-requiring is a swap. The export table is the source of truth for which
   Vars a component owns: every interned Var is tagged
   `:cljw.wasm/component-export`, and on a re-require the tagged Vars the new
   table no longer has are retired (see `retire-var!`). In the `:as` namespace
   that is every tagged Var; in the current namespace (`:refer`) only the ones
   interned from the same `path`, since several components may be referred
   there. Kept exports keep their Var identity (`intern` rebinds the root), and
   a Var the user defined, or re-`def`ined over an export name, is never touched."
  [path opts]
  (let [handle (wasm/load-component path)
        exports (wasm/component-exports path)
        var-fn (fn [raw] (fn [& args] (apply wasm/component-call handle raw args)))
        ;; ADR-0135 A4 — leverage the component's self-describing WIT signature:
        ;; attach `:arglists` (one arity, param names from `(:params e)`) to each
        ;; interned Var, so `(doc …)` + editor arglist hints work like a normal fn.
        ;; (`:doc` is intentionally NOT attached — cljw Vars carry no :doc per AD-041.)
        intern! (fn [ns-obj sym e]
                  (let [v (intern ns-obj sym (var-fn (:name e)))]
                    (alter-meta! v assoc
                                 :arglists (list (mapv (comp symbol first) (:params e)))
                                 :cljw.wasm/component-export true
                                 :cljw.wasm/component-path path)
                    v))
        by-clean (reduce (fn [m e] (assoc m (strip-export-name (:name e)) e)) {} exports)
        as-sym (:as opts)
        refer-syms (:refer opts)]
    (when as-sym
      (let [target (create-ns as-sym)]
        (doseq [[sym v] (ns-interns target)
                :when (and (component-var? v) (not (contains? by-clean (name sym))))]
          (retire-var! target sym path))
        (doseq [e exports]
          (intern! target (symbol (strip-export-name (:name e))) e))))
    (when (seq refer-syms)
      (let [cur (the-ns *ns*)]
        (doseq [[sym v] (ns-interns cur)
                :when (and (component-var? v)
                           (= path (:cljw.wasm/component-path (meta v)))
                           (not (contains? by-clean (name sym))))]
          (retire-var! cur sym path))
        (doseq [s refer-syms]
          (when-let [e (get by-clean (name s))]
            (intern! cur (symbol (name s)) e)))))
    (if as-sym (the-ns as-sym) (the-ns *ns*))))

(defmacro require-component
  "Require a Wasm component's exports as Vars, e.g.
   `(require-component \"greet.wasm\" :as greeter)` then `(greeter/greet \"world\")`,
   or `(require-component \"greet.wasm\" :refer [greet])` then `(greet \"world\")`.
   `:as` is an unquoted symbol; `:refer` a vector of unquoted symbols (like `require`)."
  [path & opts]
  (let [o (apply hash-map opts)]
    `(require-component* ~path {:as '~(:as o) :refer '~(:refer o)})))

(defmacro with-resource
  "bindings => [name init ...]. Evaluates body in a try with names bound to the
   inits, and a finally that `(wasm/resource-drop)`s each name in reverse order —
   deterministic release of a component `own` resource (ADR-0159), the wasm
   analogue of `clojure.core/with-open`. Prefer this over a bare `resource-drop`
   so a resource is released even if the body throws."
  [bindings & body]
  (cond
    (= (count bindings) 0) `(do ~@body)
    (symbol? (bindings 0)) `(let ~(subvec bindings 0 2)
                              (try
                                (with-resource ~(subvec bindings 2) ~@body)
                                (finally
                                  (wasm/resource-drop ~(bindings 0)))))
    :else (throw (ex-info "with-resource only allows Symbols in bindings" {}))))

(defn require-component-libspec
  "Static `ns`-directive worker (ADR-0135 Amendment 1). The `ns` special form
   desugars a string libspec `(:require [\"x.wasm\" :as g :refer [a b]])` into a
   call to this fn with string args (`alias-str` = the :as name or nil;
   `refer-strs` = the :refer name vector). Symbol-izes the opts and routes to
   `require-component*` — the same worker the dynamic `require-component` macro uses."
  [path alias-str refer-strs]
  (require-component* path {:as (when alias-str (symbol alias-str))
                            :refer (mapv symbol refer-strs)}))
