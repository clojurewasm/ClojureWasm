;; `(wasm/exports h)` lists a core module's exports in export order with
;; runtime-probed signatures (ADR-0203 decision 1). A function answers
;; {:name :kind :func :params [...] :results [...]}, any other export
;; {:name :kind :memory|:global|:table}. The signature comes from the probe
;; `wasm/call` marshals through, so a listed function is callable at exactly
;; the listed arity. Needs the -Dwasm binary (the gate configuration).
(ns suites.wasm-exports-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private add-wasm "docs/examples/wasm/add.wasm")
(def ^:private kernel-wasm "docs/examples/polyglot/c/kernel.wasm")

(deftest single-function-module
  (is (= [{:name "add" :kind :func :params [:i32 :i32] :results [:i32]}]
         (wasm/exports (wasm/load add-wasm)))))

(deftest c-kernel-exports
  (let [es (wasm/exports (wasm/load kernel-wasm))]
    (testing "the linear memory and four functions, in export order"
      (is (= [["memory" :memory] ["buf_addr" :func] ["buf_cap" :func]
              ["sum_f64" :func] ["scale_f64" :func]]
             (mapv (juxt :name :kind) es))))
    (testing "function signatures"
      (is (= [["buf_addr" [] [:i32]]
              ["buf_cap" [] [:i32]]
              ["sum_f64" [:i32 :i32] [:f64]]
              ["scale_f64" [:i32 :i32 :f64] [:i32]]]
             (vec (for [e es :when (= :func (:kind e))]
                    [(:name e) (:params e) (:results e)])))))
    (testing "a non-function export carries no :params / :results"
      (is (= {:name "memory" :kind :memory}
             (first (filter #(= :memory (:kind %)) es)))))))

(deftest exports-drive-call
  (let [h (wasm/load add-wasm)
        e (first (wasm/exports h))]
    (is (= 42 (apply wasm/call h (:name e) (take (count (:params e)) [40 2 99]))))))

(deftest bad-handle-is-catalogued
  (is (= "wasm/exports: the first argument must be a loaded wasm module"
         (try (wasm/exports 42) nil
              (catch Exception e (ex-message e))))))
