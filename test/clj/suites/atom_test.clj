;; test/e2e/phase14_atom.sh — atoms (basic single-threaded box, Phase-15
;; pull-forward): atom / deref / @ / swap! / reset! / compare-and-set!.
;; Watches / validators / real CAS-atomicity stay Phase 15 (D-157).

;; Migrated from test/e2e/phase14_atom.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.atom-test
  (:require [clojure.test :refer [deftest is]]))

(deftest atom-cases
  (is (= "10" (pr-str (deref (atom 10)))) "deref_fn")
  (is (= "7" (pr-str @(atom 7))) "deref_at")
  (is (= "1" (pr-str (let [a (atom 1)] @a))) "deref_let")
  (is (= "5" (pr-str (let [a (atom 0)] (reset! a 5) @a))) "reset")
  (is (= "9" (pr-str (reset! (atom 0) 9))) "reset_ret")
  (is (= "1" (pr-str (let [a (atom 0)] (swap! a inc) @a))) "swap_inc")
  (is (= "6" (pr-str (swap! (atom 0) + 1 2 3))) "swap_ret")
  (is (= "111" (pr-str (let [a (atom 1)] (swap! a + 10 100) @a))) "swap_args")
  (is (= "1" (pr-str (let [a (atom {:n 0})] (swap! a update :n inc) (:n @a)))) "swap_map")
  (is (= "5" (pr-str (let [a (atom 0)] (dotimes [_ 5] (swap! a inc)) @a))) "swap_many")
  (is (= "[true 6]" (pr-str (let [a (atom 5)] [(compare-and-set! a 5 6) @a]))) "cas_ok")
  (is (= "[false 5]" (pr-str (let [a (atom 5)] [(compare-and-set! a 99 6) @a]))) "cas_no")
  (is (= "true" (pr-str (let [a (atom 0)] (swap! a inc) (identical? a a)))) "identity")
  (is (= "[1 2]" (pr-str (let [a (atom 1)] (swap-vals! a inc)))) "swap_vals")
  (is (= "[1 31]" (pr-str (let [a (atom 1)] (swap-vals! a + 10 20)))) "swap_vals_args")
  (is (= "[5 9]" (pr-str (let [a (atom 5)] (reset-vals! a 9)))) "reset_vals")
  (is (= "400" (pr-str (let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (swap! a inc)))) (range 4))) @a))) "swap_concurrent")
  (is (= "400" (pr-str (let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (loop [] (let [o @a] (when-not (compare-and-set! a o (inc o)) (recur))))))) (range 4))) @a))) "cas_concurrent")
  (is (= "5" (pr-str (let [a (atom 5)] (try (swap! a (fn [_] (throw (ex-info "x" {})))) (catch Throwable e :caught)) @a))) "swap_throw_unchanged")
  (is (= "{:a 1}" (pr-str (meta (atom 1 :meta {:a 1})))) "ctor_meta")
  (is (= "5" (pr-str @(atom 5 :validator pos?))) "ctor_validator_ok")
  (is (= "[{:a 1} 5]" (pr-str [(meta (atom 5 :meta {:a 1} :validator pos?)) @(atom 5 :meta {:a 1} :validator pos?)])) "ctor_both")
  (is (= "nil" (pr-str (meta (atom 1 :validator pos?)))) "ctor_validator_no_meta")
  (is (= ":threw" (pr-str (try (atom -1 :validator pos?) (catch Throwable e :threw)))) "ctor_validator_reject")
  (is (= ":rejected" (pr-str (let [a (atom 2 :validator even?)] (try (swap! a inc) (catch Throwable e :rejected))))) "ctor_validator_swap_reject")
  (is (= "{:x 1}" (pr-str (meta (atom 1 :meta {:x 1})))) "ctor_meta_map")
  (is (= ":threw" (pr-str (try (atom 1 :meta 5) (catch Throwable e :threw)))) "ctor_meta_nonmap")
  (is (= ":threw" (pr-str (try (atom 1 :meta #{}) (catch Throwable e :threw)))) "ctor_meta_set")
  (is (= ":threw" (pr-str (try (ref 1 :meta 5) (catch Throwable e :threw)))) "ctor_meta_ref")
  (is (= ":threw" (pr-str (try (agent 1 :meta 5) (catch Throwable e :threw)))) "ctor_meta_agent"))
