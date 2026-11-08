;; Caller-controlled component budgets (:fuel, :max-memory-pages), and the fuel
;; diagnostic on both call paths: a budget kill must NAME the budget, since
;; "trapped" would read as a guest bug. Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/phase16_wasm_component_budget.sh; its check labels
;; are the assertion messages.
(ns suites.wasm-component-budget-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private spin-component "test/e2e/fixtures/wasm/spin_component.wasm")
(def ^:private spin-core "test/e2e/fixtures/wasm/spin.wasm")
(def ^:private limits {:fuel 1000 :max-memory-pages 2})

(defn- fuel-error? [f]
  (try (f) false
       (catch Throwable t (boolean (re-find #"fuel budget" (ex-message t))))))

(defn- rejected? [opts]
  (try (wasm/load-component spin-component opts) false (catch Throwable _ true)))

(deftest component-fuel-budget
  (is (= 42 (wasm/component-call (wasm/load-component spin-component) "ok"))
      "default-compatible")
  (let [h (wasm/load-component spin-component limits)]
    (is (= 42 (wasm/component-call h "ok")) "limited-control")
    (is (fuel-error? #(wasm/component-call h "spin")) "fuel-terminates-spin-and-says-so")
    (is (fuel-error? #(wasm/component-call h "ok")) "exhausted-instance-stays-exhausted"))
  (let [h (wasm/load-component spin-component limits)]
    (is (= 10 (wasm/component-call h "burn" 10)) "fresh-instance-control")
    (is (loop [remaining 200]
          (cond (zero? remaining) false
                (fuel-error? #(wasm/component-call h "burn" 10)) true
                :else (recur (dec remaining))))
        "fuel-cumulative-across-calls")
    (is (fuel-error? #(wasm/component-call h "ok")) "cumulative-exhaustion-persists"))
  (is (= 42 (wasm/component-call (wasm/load-component spin-component {:fuel 0 :max-memory-pages 2}) "ok"))
      "explicit-unmetered"))

(deftest component-memory-budget
  (let [h (wasm/load-component spin-component limits)]
    (is (= 1 (wasm/component-call h "grow" 1)) "grow-within-cap")
    (is (= -1 (wasm/component-call h "grow" 1)) "grow-refused-at-cap")))

(deftest component-budget-options-validated
  (is (rejected? 1) "invalid-options")
  (is (rejected? {:fuel "1000"}) "invalid-fuel")
  (is (rejected? {:max-memory-pages "2"}) "invalid-memory")
  (is (rejected? {:engine :jit}) "unsupported-engine")
  (is (rejected? {:timeout-ms 1}) "unsupported-deadline"))

(deftest core-module-shares-the-fuel-diagnostic
  (let [m (wasm/load spin-core {:fuel 1000})]
    (is (= 42 (wasm/call m "ok")) "module-control")
    (is (try (wasm/call m "spin") false
             (catch Throwable t
               (boolean (re-find #"'spin' exhausted the module's fuel budget" (ex-message t)))))
        "module-fuel-names-export"))
  (testing "module-genuine-trap-is-still-a-trap"
    (is (try (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom") false
             (catch Throwable t (and (not (re-find #"fuel" (ex-message t)))
                                     (boolean (re-find #"trapped" (ex-message t)))))))))
