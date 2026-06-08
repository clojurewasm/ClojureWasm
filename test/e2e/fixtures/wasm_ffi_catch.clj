;; FIX-4 wasm-error taxonomy: every wasm-surface error is a CATCHABLE cljw
;; exception (not an internal_error / exit 70). Each case evaluates a failing
;; wasm/load or wasm/call inside a (catch …); the body returns "NOT-CAUGHT" when
;; no throw happened, so the e2e asserts every line says CAUGHT and the process
;; stays exit-0. A couple of cases pin the SPECIFIC host class so the Kind
;; mapping (value_error→IllegalArgumentException, type_error→ClassCastException,
;; arity_error→ArityException) is locked, not just "some Throwable".
(def m (wasm/load "examples/wasm/add.wasm"))

(println "out-of-range:"
  (try (wasm/call m "add" 5000000000 0) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "out-of-range-iae:"
  (try (wasm/call m "add" 5000000000 0) "NOT-CAUGHT"
    (catch IllegalArgumentException _ "CAUGHT")))
(println "not-a-number:"
  (try (wasm/call m "add" "x" 0) "NOT-CAUGHT"
    (catch ClassCastException _ "CAUGHT")))
(println "unknown-export:"
  (try (wasm/call m "nope" 1 2) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "wrong-arity:"
  (try (wasm/call m "add" 1) "NOT-CAUGHT"
    (catch ArityException _ "CAUGHT")))
(println "bad-opts:"
  (try (wasm/load "examples/wasm/add.wasm" {:fuel "x"}) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "bad-path:"
  (try (wasm/load 42) "NOT-CAUGHT"
    (catch ClassCastException _ "CAUGHT")))

(def t (wasm/load "examples/wasm/trap.wasm"))
(println "trap:"
  (try (wasm/call t "boom") "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")
