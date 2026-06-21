;; ADR-0159 (D-404 Impl E) — Wasm Component resource lifecycle. A `resource`
;; constructor returns a typed `own`-handle wrapper (not a bare int); methods
;; round-trip through it; `wasm/resource-drop` deterministically releases it and
;; a subsequent method on the dropped handle TRAPS (the only drop-observable
;; signal — the fixture has no drop-side-effect export); double-drop is idempotent.
(require 'cljw.wasm)
(cljw.wasm/require-component "test/e2e/fixtures/wasm/resource_counter.wasm" :as ctr)

(let [h (ctr/counter 5)]
  ;; The own-handle wrapper round-trips through the borrow-taking methods.
  (ctr/increment h)
  (assert (= 6 (ctr/get h)) "resource round-trip via the own-handle wrapper")
  (println "PASS resource-roundtrip")

  ;; Deterministic release (ADR-0159) — runs the guest destructor via dropResource.
  (wasm/resource-drop h)
  (println "PASS resource-drop")

  ;; Use-after-drop is a catchable trap — proves the handle was actually released.
  (let [r (try (ctr/get h) "NOT-CAUGHT" (catch Throwable _ "CAUGHT"))]
    (assert (= "CAUGHT" r) (str "use-after-drop must trap, got " r))
    (println "PASS resource-use-after-drop-traps"))

  ;; Double-drop is idempotent at the cljw layer (NOT a zwasm stale-handle trap).
  (wasm/resource-drop h)
  (println "PASS resource-double-drop-idempotent"))

;; with-resource (ADR-0159 cycle 2): the body sees a live resource, and the
;; resource is released deterministically at scope exit (the with-open analogue).
(assert (= 11 (cljw.wasm/with-resource [c (ctr/counter 10)]
                (ctr/increment c)
                (ctr/get c)))
        "with-resource body must see a live resource")
(println "PASS with-resource-body-live")

;; A handle that escapes the with-resource scope is already dropped → traps.
(let [escaped (cljw.wasm/with-resource [c (ctr/counter 0)] c)
      r (try (ctr/get escaped) "NOT-CAUGHT" (catch Throwable _ "CAUGHT"))]
  (assert (= "CAUGHT" r) (str "with-resource must drop at scope exit, got " r))
  (println "PASS with-resource-drops-at-scope-exit"))

(println "DONE")
