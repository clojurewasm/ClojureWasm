;; test/e2e/phase14_threading_macros.sh
;;
;; D-134 missing-core batch — threading-conditional family:
;; as-> / cond-> / cond->> / some-> / some->>. All expand to a let*
;; cascade reusing the -> / ->> threadStep (macro_transforms.zig).
;; (Keyword thread-steps `(-> m :k)` stay unsupported pending
;; keyword-as-IFn — see D-085; not exercised here.)

;; Migrated from test/e2e/phase14_threading_macros.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.threading-macros-test
  (:require [clojure.test :refer [deftest is]]))

(deftest threading-macros-cases
  (is (= "12" (pr-str (as-> 5 x (+ x 1) (* x 2)))) "as_arith")
  (is (= "2" (pr-str (as-> {:a 1} m (assoc m :b 2) (get m :b)))) "as_map")
  (is (= "4" (pr-str (as-> [1 2 3] v (conj v 4) (count v)))) "as_mixed")
  (is (= "3" (pr-str (cond-> 1 true inc false inc (= 2 2) inc))) "cond_inc")
  (is (= "[1 3]" (pr-str (cond-> [] true (conj 1) false (conj 2) true (conj 3)))) "cond_conj")
  (is (= "10" (pr-str (cond-> 10 false inc false dec))) "cond_none")
  (is (= "9" (pr-str (cond->> [1 2 3] true (map inc) true (reduce +)))) "condl_red")
  (is (= "3" (pr-str (some-> 1 inc inc))) "some_chain")
  (is (= "nil" (pr-str (some-> nil inc))) "some_nil0")
  (is (= "nil" (pr-str (some-> {:a 1} (get :b) inc))) "some_mid")
  (is (= "9" (pr-str (some->> [1 2 3] (map inc) (reduce +)))) "somel_red")
  (is (= "nil" (pr-str (some->> nil (map inc)))) "somel_nil"))
