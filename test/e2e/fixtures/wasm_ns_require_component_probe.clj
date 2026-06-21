;; ADR-0135 Amendment 1 — the STATIC `ns` `:require` form for a Wasm component
;; (CLJS/CLJD string-libspec lineage). `["x.wasm" :as g]` desugars (in the `ns`
;; special form) to `(cljw.wasm/require-component-libspec …)` — the same worker the
;; dynamic `cljw.wasm/require-component` macro uses. A component's exports become
;; callable Vars, indistinguishable from normal Clojure fns. Run under `-Dwasm`.
(ns wasm.ns-require-probe
  (:require ["test/e2e/fixtures/wasm/greet_component.wasm" :as greeter]
            ["test/e2e/fixtures/wasm/resource_counter.wasm" :as ctr]
            ["test/e2e/fixtures/wasm/greet_component.wasm" :refer [greet]]))

;; :as form — exports interned in the `greeter` ns.
(assert (= "Hello, world!" (greeter/greet "world")) (pr-str (greeter/greet "world")))
(println "PASS ns-require-greet")

;; ADR-0135 A4 — the component's WIT signature surfaces as `:arglists` metadata
;; (param names), so the generated Var reads like a normal Clojure fn.
(assert (= '([name]) (:arglists (meta (var greeter/greet))))
        (pr-str (:arglists (meta (var greeter/greet)))))
(println "PASS ns-require-arglists")

;; resource component — ctor + methods as Vars in the `ctr` ns.
(let [h (ctr/counter 5)]
  (ctr/increment h)
  (assert (= 6 (ctr/get h)) (str "expected 6, got " (ctr/get h))))
(println "PASS ns-require-resource")

;; :refer form — `greet` interned into THIS ns (wasm.ns-require-probe).
(assert (= "Hello, again!" (greet "again")) (pr-str (greet "again")))
(println "PASS ns-require-refer")

(println "DONE")
