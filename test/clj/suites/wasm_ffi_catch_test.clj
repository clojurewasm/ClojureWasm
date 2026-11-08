;; FIX-4 wasm-error taxonomy: every wasm/load and wasm/call failure is a
;; CATCHABLE cljw exception, never an internal_error / exit 70. Several cases
;; pin the SPECIFIC host class so the Kind mapping (value_error ->
;; IllegalArgumentException, type_error -> ClassCastException, arity_error ->
;; ArityException) is locked, not just "some Throwable". Needs the -Dwasm binary.
;;
;; Migrated from test/e2e/fixtures/wasm_ffi_catch.clj (driven by
;; phase16_wasm_ffi.sh); the probe's line labels are the assertion messages.
(ns suites.wasm-ffi-catch-test
  (:require [clojure.test :refer [deftest is]]))

(def ^:private add-wasm "docs/examples/wasm/add.wasm")

(deftest wasm-call-errors-are-catchable
  (let [m (wasm/load add-wasm)]
    (is (= 42 (wasm/call m "add" 2 40)) "control: add(2,40)")
    (is (thrown? Throwable (wasm/call m "add" 5000000000 0)) "out-of-range")
    (is (thrown? IllegalArgumentException (wasm/call m "add" 5000000000 0)) "out-of-range-iae")
    (is (thrown? ClassCastException (wasm/call m "add" "x" 0)) "not-a-number")
    (is (thrown? Throwable (wasm/call m "nope" 1 2)) "unknown-export")
    (is (thrown? ArityException (wasm/call m "add" 1)) "wrong-arity")))

(deftest wasm-load-errors-are-catchable
  (is (thrown? Throwable (wasm/load add-wasm {:fuel "x"})) "bad-opts")
  (is (thrown? IllegalArgumentException (wasm/load add-wasm {:wasi {}}))
      "wasi-load-split: :wasi belongs to wasm/run, not to a module handle")
  (is (thrown? IllegalArgumentException (wasm/load add-wasm {:wasi nil}))
      "wasi-load-nil-split: a present nil :wasi is not treated as absent")
  (is (thrown? ClassCastException (wasm/load 42)) "bad-path"))

(deftest wasm-trap-is-catchable
  (is (thrown? Throwable (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom")) "trap"))
