;; clojure.test — minimum surface. cw v1 §9.13 row 11.2.
;;
;; `is` is the only var landed in cycle 1 (interned by
;; `src/lang/primitive/test_assert.zig`). `deftest` + `run-tests`
;; defer to **D-099** — they require user-defined `defmacro`
;; support which cw v1 does not yet land. Users write
;; `(defn test-foo [] (clojure.test/is (= 1 1)))` + `(test-foo)`
;; to run a test manually.
;;
;; `run-tests` is provided as a thin variadic helper that takes
;; explicit fn arguments + reports pass/fail count (no auto-discovery
;; until defmacro lands).
(ns clojure.test
  (:refer-clojure))

;; Variadic-via-reduce test runner. Each arg is a 0-arity fn that
;; either returns truthy (pass) or returns falsy / raises (fail).
;; Returns `[pass-count fail-count]` so the caller can decide what
;; to do with the gate.
(def run-tests
  (fn* [& tests]
    (let* [results (map (fn* [t] (if (t) true false)) tests)
           passes (count (filter (fn* [r] r) results))
           fails (count (filter (fn* [r] (if r false true)) results))]
      [passes fails])))
