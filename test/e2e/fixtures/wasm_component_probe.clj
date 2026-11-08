;; cljw↔wasm COMPONENT boundary probe (D-404 / ADR-0135). The wasm engine itself
;; is zwasm's concern; this verifies the CLOJURE→wasm-component usage path: value
;; marshalling, the cached-handle lifetime (REQ-7 instance caching), resource
;; chains, every happy path, and that every error stays a CATCHABLE cljw exception
;; (no exit-70 crash). Fixtures are copied from zwasm's component test corpus.
(def greet "test/e2e/fixtures/wasm/greet_component.wasm")
(def counter "test/e2e/fixtures/wasm/resource_counter.wasm")

;; --- happy: one-shot typed invoke (string → string marshalling) ---
(let [r (wasm/component-invoke greet "greet" "zwasm")]
  (assert (= "Hello, zwasm!" r) (pr-str r))
  (println "PASS component-invoke-greet"))

;; --- happy: exports listing returns {:name :params :result} maps ---
(let [ex (wasm/component-exports greet)]
  (assert (some #(= "greet" (:name %)) ex) (pr-str ex))
  (assert (= "string" (:result (first (filter #(= "greet" (:name %)) ex)))) (pr-str ex))
  (println "PASS component-exports"))

;; --- happy: cached handle, reuse across multiple calls (REQ-7 instance caching —
;;     the opened component outlives its load buffer + survives across calls) ---
(let [c (wasm/load-component greet)
      a (wasm/component-call c "greet" "zwasm")
      b (wasm/component-call c "greet" "again")]
  (assert (= "Hello, zwasm!" a) (pr-str a))
  (assert (= "Hello, again!" b) (pr-str b))
  (println "PASS load-component-handle-reuse"))

;; --- happy: resource chain (ctor own-handle → method borrow), counter 5 → 6.
;;     Export strings are DISCOVERED via component-exports (not hard-coded). ---
(let [ex   (wasm/component-exports counter)
      find (fn [needle] (some #(when (clojure.string/includes? (:name %) needle) (:name %)) ex))
      ctor (find "[constructor]counter")
      incr (find "[method]counter.increment")
      getf (find "[method]counter.get")
      c    (wasm/load-component counter)
      h    (wasm/component-call c ctor 5)
      _    (wasm/component-call c incr h)
      g    (wasm/component-call c getf h)]
  (assert (= 6 g) (str "counter ctor(5)→increment→get expected 6, got " (pr-str g)))
  (println "PASS resource-chain"))

;; --- one-shot `component-invoke` returning a resource: the component outlives
;;     the call, because the handle names something inside it (ADR-0159 am1).
;;     This USED to return a bare integer into a table torn down one line later. ---
(let [ex   (wasm/component-exports counter)
      find (fn [needle] (some #(when (clojure.string/includes? (:name %) needle) (:name %)) ex))
      ctor (find "[constructor]counter")
      incr (find "[method]counter.increment")
      getf (find "[method]counter.get")
      h    (wasm/component-invoke counter ctor 5)]
  (assert (not (number? h)) (str "one-shot ctor returned a raw handle number: " (pr-str h)))
  ;; A resource names its own component, so methods are reachable without any
  ;; other handle to that instance — the instance has no other name.
  (assert (= 5 (wasm/component-call h getf h)))
  (wasm/component-call h incr h)
  ;; Survives a collection: the wrapper roots its component (GC-ROOT §H).
  (System/gc)
  (assert (= 6 (wasm/component-call h getf h)) "one-shot resource did not survive a GC")
  (wasm/resource-drop h)
  (assert (= "CAUGHT" (try (wasm/component-call h getf h) "NOT-CAUGHT"
                        (catch Throwable _ "CAUGHT"))))
  (println "PASS one-shot-resource-outlives-call"))

;; --- a resource handle is bound to the component that minted it. Handle numbers
;;     are dense per-instance table indices starting at 1, so a foreign handle
;;     does not fail on its own — it names a DIFFERENT live resource. ---
(let [ex   (wasm/component-exports counter)
      find (fn [needle] (some #(when (clojure.string/includes? (:name %) needle) (:name %)) ex))
      ctor (find "[constructor]counter")
      getf (find "[method]counter.get")
      a    (wasm/component-invoke counter ctor 5)
      c    (wasm/load-component counter)
      b    (wasm/component-call c ctor 9)]
  (assert (= 5 (wasm/component-call a getf a)))
  (assert (= 9 (wasm/component-call c getf b)))
  ;; Without the owner check this returned 9 (c's resource 1) for a's handle.
  (assert (= "CAUGHT" (try (wasm/component-call c getf a) "NOT-CAUGHT"
                        (catch Throwable _ "CAUGHT"))))
  (assert (= "CAUGHT" (try (wasm/component-call a getf b) "NOT-CAUGHT"
                        (catch Throwable _ "CAUGHT"))))
  ;; A raw handle number is not a resource. It used to be @intCast'd straight
  ;; into the table — unchecked, and a negative one was a ReleaseSafe panic.
  (assert (= "CAUGHT" (try (wasm/component-call c getf 1) "NOT-CAUGHT"
                        (catch Throwable _ "CAUGHT"))))
  (assert (= "CAUGHT" (try (wasm/component-call c getf -1) "NOT-CAUGHT"
                        (catch Throwable _ "CAUGHT"))))
  (println "PASS resource-handle-is-bound-to-its-component"))

;; --- problematic boundary cases: every error stays a CATCHABLE cljw exception ---
(println "bad-path:"
  (try (wasm/component-invoke "/no/such/file.wasm" "greet" "x") "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "missing-export:"
  (try (wasm/component-invoke greet "no-such-export" "x") "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "component-call-on-non-handle:"
  (try (wasm/component-call "not-a-handle" "greet" "x") "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))
(println "bad-arg-type-to-load:"
  (try (wasm/load-component 42) "NOT-CAUGHT"
    (catch Throwable _ "CAUGHT")))

(println "DONE")

;; --- happy: component-invoke also takes a load-component handle (it used to
;;     refuse it as "the module path must be a string") and reuses it ---
(let [c (wasm/load-component greet)
      r (wasm/component-invoke c "greet" "handle")]
  (assert (= "Hello, handle!" r) (pr-str r))
  (println "PASS component-invoke-accepts-handle"))
