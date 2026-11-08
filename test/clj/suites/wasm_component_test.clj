;; cljw <-> wasm COMPONENT boundary (D-404 / ADR-0135): value marshalling, the
;; cached-handle lifetime (REQ-7 instance caching), resource chains, and every
;; error staying a catchable cljw exception (no exit-70 crash). The engine is
;; zwasm's concern; this is the Clojure usage path. Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/phase16_wasm_component.sh and its probe fixture;
;; the probe's PASS markers are kept as assertion messages.
(ns suites.wasm-component-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(def ^:private greet "test/e2e/fixtures/wasm/greet_component.wasm")
(def ^:private counter "test/e2e/fixtures/wasm/resource_counter.wasm")

(defn- caught? [f] (try (f) false (catch Throwable _ true)))

(defn- counter-exports
  "The counter's ctor / increment / get export strings, DISCOVERED via
  component-exports rather than hard-coded."
  []
  (let [ex (wasm/component-exports counter)
        find (fn [needle] (some #(when (str/includes? (:name %) needle) (:name %)) ex))]
    {:ctor (find "[constructor]counter")
     :incr (find "[method]counter.increment")
     :getf (find "[method]counter.get")}))

(deftest component-invoke-and-exports
  (is (= "Hello, zwasm!" (wasm/component-invoke greet "greet" "zwasm"))
      "component-invoke-greet: string -> string marshalling")
  (let [ex (wasm/component-exports greet)]
    (is (some #(= "greet" (:name %)) ex) "component-exports")
    (is (= "string" (:result (first (filter #(= "greet" (:name %)) ex)))) "component-exports")))

(deftest load-component-handle-reuse
  (let [c (wasm/load-component greet)]
    (is (= "Hello, zwasm!" (wasm/component-call c "greet" "zwasm")))
    (is (= "Hello, again!" (wasm/component-call c "greet" "again"))
        "the opened component outlives its load buffer and survives across calls"))
  (is (= "Hello, handle!" (wasm/component-invoke (wasm/load-component greet) "greet" "handle"))
      "component-invoke-accepts-handle: it used to refuse a handle as 'the module path must be a string'"))

(deftest resource-chain
  (let [{:keys [ctor incr getf]} (counter-exports)
        c (wasm/load-component counter)
        h (wasm/component-call c ctor 5)]
    (wasm/component-call c incr h)
    (is (= 6 (wasm/component-call c getf h)) "counter ctor(5) -> increment -> get")))

(deftest one-shot-resource-outlives-call
  ;; A one-shot invoke returning a resource keeps its component alive, because
  ;; the handle names something inside it (ADR-0159 am1). This USED to return a
  ;; bare integer into a table torn down one line later.
  (let [{:keys [ctor incr getf]} (counter-exports)
        h (wasm/component-invoke counter ctor 5)]
    (is (not (number? h)) "one-shot ctor returned a raw handle number")
    (is (= 5 (wasm/component-call h getf h))
        "a resource names its own component, so its methods are reachable through it")
    (wasm/component-call h incr h)
    (System/gc)
    (is (= 6 (wasm/component-call h getf h)) "the resource survives a collection (GC-ROOT §H)")
    (wasm/resource-drop h)
    (is (caught? #(wasm/component-call h getf h)) "use after drop is catchable")))

(deftest resource-handle-is-bound-to-its-component
  ;; Handle numbers are dense per-instance table indices starting at 1, so a
  ;; foreign handle does not fail on its own: it names a DIFFERENT live resource.
  (let [{:keys [ctor getf]} (counter-exports)
        a (wasm/component-invoke counter ctor 5)
        c (wasm/load-component counter)
        b (wasm/component-call c ctor 9)]
    (is (= 5 (wasm/component-call a getf a)))
    (is (= 9 (wasm/component-call c getf b)))
    (is (caught? #(wasm/component-call c getf a))
        "without the owner check this returned 9, c's resource 1, for a's handle")
    (is (caught? #(wasm/component-call a getf b)))
    (testing "a raw handle number is not a resource (a negative one was a ReleaseSafe panic)"
      (is (caught? #(wasm/component-call c getf 1)))
      (is (caught? #(wasm/component-call c getf -1))))))

(deftest component-errors-are-catchable
  (is (caught? #(wasm/component-invoke "/no/such/file.wasm" "greet" "x")) "bad-path")
  (is (caught? #(wasm/component-invoke greet "no-such-export" "x")) "missing-export")
  (is (caught? #(wasm/component-call "not-a-handle" "greet" "x")) "component-call-on-non-handle")
  (is (caught? #(wasm/load-component 42)) "bad-arg-type-to-load"))
