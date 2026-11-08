;; D-568 (ADR-0159 amendment 1, verification item (a)): a resource minted by a
;; single-module component cannot be dropped by the host, because zwasm's
;; `.single` variant has no resource table. The error must name that condition,
;; not report a guest trap.
(require 'cljw.wasm)
(let [c (wasm/load-component "test/e2e/fixtures/wasm/single_resource.wasm")
      h (wasm/component-call c "make-counter")
      msg (try (wasm/resource-drop h) "NOT-THROWN" (catch Throwable e (ex-message e)))]
  (assert (re-find #"no resource table" msg) (str "drop on a .single component must name the missing resource table, got: " msg))
  (assert (not (re-find #"trapped" msg)) (str "must not be reported as a trap, got: " msg))
  (println "PASS resource-drop-no-table"))
(println "DONE")
