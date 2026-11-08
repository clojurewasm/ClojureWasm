;; Dot-interop on a core wasm module handle (ADR-0203 decision 2).
;; `(.add h 40 2)`, `(. h add 40 2)` and `(. h (add 40 2))` are
;; `(wasm/call h "add" 40 2)`: the method symbol's name is the export name
;; verbatim, and the call takes the same path as wasm/call, so a missing
;; export, an arity mismatch and a trap raise the same catalogued errors.
;; Both backends carry the case (VM op_method_call, TreeWalk
;; evalInstanceMember). Needs the -Dwasm binary (the gate configuration).
(ns suites.wasm-dot-interop-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private add-wasm "docs/examples/wasm/add.wasm")
(def ^:private kernel-wasm "docs/examples/polyglot/c/kernel.wasm")
(def ^:private trap-wasm "docs/examples/wasm/trap.wasm")

(defn- msg [f]
  (try (f) :not-raised (catch Throwable e (.getMessage e))))

(deftest three-spellings
  (let [h (wasm/load add-wasm)]
    (is (= 42 (.add h 40 2)))
    (is (= 42 (. h add 40 2)))
    (is (= 42 (. h (add 40 2))))
    (is (= (wasm/call h "add" 40 2) (.add h 40 2)))))

(deftest c-export-names-verbatim
  (let [m (wasm/load kernel-wasm)
        buf (.buf_addr m)]
    (wasm/mem-write! m :f64 buf [1.0 2.0 3.0 4.0])
    (is (= 10.0 (.sum_f64 m buf 4)))
    (is (= 4 (.scale_f64 m buf 4 2.0)))
    (is (= 20.0 (.sum_f64 m buf 4)))))

(deftest errors-are-wasm-call-errors
  (let [h (wasm/load add-wasm)
        t (wasm/load trap-wasm)]
    (testing "missing export"
      (is (= (msg #(wasm/call h "nope" 1)) (msg #(.nope h 1))))
      (is (= "wasm/call: no exported function named 'nope'" (msg #(.nope h 1)))))
    (testing "arity"
      (is (= "wasm/call: 'add' expects 2 argument(s), got 1" (msg #(.add h 1)))))
    (testing "trap"
      (is (= (msg #(wasm/call t "boom")) (msg #(.boom t))))
      (is (re-find #"^wasm/call: 'boom' \(\) -> \(i32\) trapped" (msg #(.boom t)))))))

(deftest non-wasm-receivers-unchanged
  (is (= "ABC" (.toUpperCase "abc")))
  (is (re-find #"No implementation of method 'add' on protocol '<\.member>'"
               (str (msg #(.add 42 1))))))
