;; CLJW-WASM-INTERP-THREAD-TRAP: a handle warmed on the runtime thread must
;; still run when the next call comes from another thread (future / agent).
;; zwasm's interp cached the FIRST caller thread's native-stack low limit on
;; the instance's Runtime, so a later call from a thread whose stack sits below
;; that limit trapped CallStackExhausted. Needs the -Dwasm binary (the gate
;; configuration).
(ns suites.wasm-thread-hop-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private add-wasm "bench/wasm/ffi/add.wasm")

(defn- call [h]
  (try (wasm/call h "add" 2 3)
       (catch Throwable e (str "TRAPPED " (ex-message e)))))

(deftest warmed-handle-runs-from-a-future
  (doseq [engine [:interp :jit :auto]
          warm [1 5000]]
    (testing (str engine " warmed " warm "x on the runtime thread")
      (let [h (wasm/load add-wasm {:engine engine :fuel 0})]
        (dotimes [_ warm] (call h))
        (is (= 5 @(future (call h))) "the call from a future")
        (is (= 5 (call h)) "and back on the runtime thread")))))

(deftest worker-first-handle-runs-on-the-runtime-thread
  (let [h (wasm/load add-wasm {:engine :interp :fuel 0})]
    (is (= 5 @(future (call h))))
    (is (= 5 (call h)))))
